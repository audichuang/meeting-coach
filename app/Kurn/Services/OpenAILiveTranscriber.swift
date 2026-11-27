//
//  OpenAILiveTranscriber.swift
//  Kurn
//
//  Cloud live transcription for the meeting coach: an OpenAI Realtime
//  transcription session (`gpt-live-transcribe`) behind the same
//  `StreamingAsrManager` seam `LiveTranscriptionService` drives the on-device
//  engines through. Settings follow the meeting-coach spike: languages
//  ["zh-tw"], a Traditional-Chinese prompt, no keywords (they insert terms
//  that were never said), no server VAD and a manual commit every 20 s of
//  audio (more accurate than pause-based commits on the fixture).
//
//  The recording never depends on this: while the socket is down audio is
//  dropped here (and reported as a gap), and reconnection is retried with
//  backoff. Nothing in `appendAudio`/`processBufferedAudio` awaits the
//  network — sends go through a bounded outbox drained by the connection's
//  own task, so a stalled socket cannot back up the live-audio pump.
//

import AVFoundation
import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

/// The WebSocket surface the transcriber needs; a seam for tests.
protocol RealtimeSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// `@unchecked`: the only state is the task, and URLSessionWebSocketTask is safe to call from any thread.
final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(bytes: data, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

actor OpenAILiveTranscriber: StreamingAsrManager {
    typealias SocketFactory = @Sendable () throws -> any RealtimeSocket

    static let model = CoachPricing.liveTranscribeModel
    static let sampleRate = 24_000.0
    /// Generic on purpose: the spike's prompt also listed the fixture's own terms.
    static let prompt = "台灣華語的產品會議，夾雜英文術語。請用繁體中文輸出。"
    /// 100 ms of 24 kHz mono PCM16.
    private static let chunkSamples = 2_400
    /// About 30 s of audio queued for the socket before it counts as stalled.
    private static let outboxLimit = 300

    nonisolated var displayName: String { Self.model }

    private let makeSocket: SocketFactory
    private let onEvent: @Sendable (LiveTranscriptEvent) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var partialCallback: (@Sendable (String) -> Void)?

    private var tracker = RealtimeCommitTracker(sampleRate: sampleRate, window: 20)
    private var pending: [Int16] = []
    private var connection: Connection?
    private var generation = 0
    private var gapStart: TimeInterval?
    private var deltas: [(id: String, text: String)] = []
    private var finals: [String] = []
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var finished = false

    private struct Connection {
        let id: Int
        let socket: any RealtimeSocket
        let outbox: AsyncStream<String>.Continuation
        let tasks: [Task<Void, Never>]
    }

    init(
        makeSocket: @escaping SocketFactory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onEvent: @escaping @Sendable (LiveTranscriptEvent) -> Void
    ) {
        self.makeSocket = makeSocket
        self.sleep = sleep
        self.onEvent = onEvent
    }

    static func socketFactory(apiKey: String) -> SocketFactory {
        {
            guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
                throw AppError.invalidProviderURL
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return URLSessionRealtimeSocket(request: request)
        }
    }

    static var sessionUpdate: String {
        let session: [String: Any] = [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                "transcription": ["model": model, "languages": ["zh-tw"], "prompt": prompt],
                "turn_detection": NSNull()
            ]]
        ]
        let event: [String: Any] = ["type": "session.update", "session": session]
        let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: StreamingAsrManager

    func loadModels() async throws {
        finished = false
        connect()
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) throws {
        // The recording sink hands over its 24 kHz mono Float32 storage format.
        guard buffer.format.sampleRate == Self.sampleRate, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        pending.reserveCapacity(pending.count + count)
        for index in 0..<count {
            pending.append(Int16(max(-1, min(1, samples[index])) * Float(Int16.max)))
        }
    }

    func processBufferedAudio() async throws {
        while pending.count >= Self.chunkSamples {
            let chunk = Array(pending.prefix(Self.chunkSamples))
            pending.removeFirst(Self.chunkSamples)
            send(chunk)
        }
    }

    func finish() async throws -> String {
        if !pending.isEmpty { send(pending); pending.removeAll() }
        finished = true
        reconnectTask?.cancel()
        if let connection, tracker.commit() {
            connection.outbox.yield(#"{"type":"input_audio_buffer.commit"}"#)
        }
        // Bounded wait for the last window's final.
        for _ in 0..<80 where connection != nil && tracker.hasOutstanding {
            try? await sleep(.milliseconds(100))
        }
        closeConnection(reportGaps: true)
        onEvent(.connection(.stopped))
        return finals.joined()
    }

    func reset() async throws {
        pending.removeAll()
        deltas.removeAll()
        finals.removeAll()
    }

    func cleanup() async {
        finished = true
        reconnectTask?.cancel()
        closeConnection(reportGaps: false)
        pending.removeAll()
        partialCallback = nil
    }

    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {
        partialCallback = callback
    }

    func getPartialTranscript() -> String { deltas.map(\.text).joined() }

    // MARK: Connection

    private func connect() {
        guard !finished else { return }
        generation += 1
        let id = generation
        onEvent(.connection(reconnectAttempt == 0 ? .connecting : .reconnecting))
        let socket: any RealtimeSocket
        do {
            socket = try makeSocket()
        } catch {
            AppLog.transcription.atError.error("OpenAILiveTranscriber: socket creation failed code=\(error.publicLogCode, privacy: .public)")
            scheduleReconnect()
            return
        }
        let (stream, outbox) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(Self.outboxLimit))
        outbox.yield(Self.sessionUpdate)
        let sender = Task { [weak self] in
            for await message in stream {
                do { try await socket.send(message) } catch {
                    await self?.connectionLost(id, code: error.publicLogCode)
                    return
                }
            }
        }
        let receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    await self?.handle(text, from: id)
                } catch {
                    await self?.connectionLost(id, code: error.publicLogCode)
                    return
                }
            }
        }
        connection = Connection(id: id, socket: socket, outbox: outbox, tasks: [sender, receiver])
    }

    private func send(_ samples: [Int16]) {
        guard let connection else {
            if gapStart == nil { gapStart = tracker.now }
            tracker.dropped(samples.count)
            return
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let message = #"{"type":"input_audio_buffer.append","audio":""# + data.base64EncodedString() + #""}"#
        if case .dropped = connection.outbox.yield(message) {
            // The socket stopped draining: treat it as lost rather than queue forever.
            tracker.dropped(samples.count)
            connectionLost(connection.id, code: "outbox_full")
            return
        }
        if tracker.sent(samples.count), tracker.commit() {
            connection.outbox.yield(#"{"type":"input_audio_buffer.commit"}"#)
        }
    }

    private func handle(_ text: String, from id: Int) {
        guard id == connection?.id, let event = RealtimeServerEvent.parse(Data(text.utf8)) else { return }
        switch event {
        case .sessionCreated:
            reconnectAttempt = 0
            if let start = gapStart {
                onEvent(.gap(LiveTranscriptGap(start: start, end: tracker.now)))
                gapStart = nil
            }
            onEvent(.connection(.live))
        case .committed(let itemID):
            tracker.acknowledge(itemID: itemID)
        case .delta(let itemID, let delta):
            if let index = deltas.firstIndex(where: { $0.id == itemID }) {
                deltas[index].text += delta
            } else {
                deltas.append((itemID, delta))
            }
            partialCallback?(getPartialTranscript())
        case .completed(let itemID, let transcript, let seconds):
            deltas.removeAll { $0.id == itemID }
            partialCallback?(getPartialTranscript())
            if let seconds { onEvent(.billedSeconds(seconds)) }
            if let segment = tracker.complete(itemID: itemID, text: transcript) {
                finals.append(transcript)
                if !transcript.isEmpty { onEvent(.final(segment)) }
            }
        case .error(let code, let message):
            if code == "input_audio_buffer_commit_empty" { tracker.rejectOldest() }
            AppLog.transcription.atError.error("OpenAILiveTranscriber: server error code=\(code ?? "unknown", privacy: .public) detail=\(message, privacy: .private)")
        case .other:
            break
        }
    }

    private func connectionLost(_ id: Int, code: String) {
        guard id == connection?.id else { return }
        AppLog.transcription.atNotice.notice("OpenAILiveTranscriber: connection lost code=\(code, privacy: .public)")
        closeConnection(reportGaps: true)
        gapStart = tracker.now
        scheduleReconnect()
    }

    private func closeConnection(reportGaps: Bool) {
        guard let connection else { return }
        self.connection = nil
        connection.outbox.finish()
        connection.tasks.forEach { $0.cancel() }
        connection.socket.close()
        deltas.removeAll()
        partialCallback?("")
        let gaps = tracker.abandonPending() + [tracker.abandonWindow()].compactMap { $0 }
        if reportGaps { gaps.forEach { onEvent(.gap($0)) } }
    }

    private func scheduleReconnect() {
        guard !finished else { return }
        onEvent(.connection(.reconnecting))
        reconnectAttempt += 1
        let delay = min(30, 1 << min(reconnectAttempt - 1, 5))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self, sleep] in
            try? await sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }
}

#endif
