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
//  A Realtime session expires about an hour after it opens. Shortly before
//  that (`rotateAfter`, or 5 minutes before the session's own `expires_at`)
//  the transcriber opens a second session at the next commit boundary and
//  sends all further audio there, while the old socket stays open only until
//  its already-committed windows come back. Connections overlap, audio does
//  not, so nothing is transcribed twice and nothing falls into a gap.
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
    /// Async because the Worker path first fetches a short-lived client secret.
    typealias SocketFactory = @Sendable () async throws -> any RealtimeSocket

    static let model = CoachPricing.liveTranscribeModel
    static let sampleRate = 24_000.0
    /// Generic on purpose: the spike's prompt also listed the fixture's own terms.
    static let prompt = "台灣華語的產品會議，夾雜英文術語。請用繁體中文輸出。"
    /// 100 ms of 24 kHz mono PCM16.
    private static let chunkSamples = 2_400
    /// About 30 s of audio queued for the socket before it counts as stalled.
    private static let outboxLimit = 300
    /// Lead before the session's own `expires_at` at which a fresh session takes over.
    private static let expiryLead: TimeInterval = 5 * 60
    /// How long a replaced session may take to return its committed windows.
    private static let drainTimeout: Duration = .seconds(30)

    nonisolated var displayName: String { Self.model }

    private let makeSocket: SocketFactory
    private let onEvent: @Sendable (LiveTranscriptEvent) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private let clock: @Sendable () -> TimeInterval
    private let rotateAfter: TimeInterval
    private var partialCallback: (@Sendable (String) -> Void)?

    private var tracker = RealtimeCommitTracker(sampleRate: sampleRate, window: 20)
    private var pending: [Int16] = []
    private var connection: Connection?
    /// The replaced session while its committed windows are still outstanding.
    private var draining: Draining?
    /// Clock time at which the live session is replaced.
    private var rotateAt: TimeInterval = .infinity
    private var generation = 0
    private var gapStart: TimeInterval?
    private var deltas: [(id: String, text: String)] = []
    private var finals: [String] = []
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var finished = false

    private struct Connection {
        let id: Int
        /// Still opening while the outbox already queues audio, so a planned hand-over never drops any.
        let socket: Task<any RealtimeSocket, Error>
        let outbox: AsyncStream<String>.Continuation
        let tasks: [Task<Void, Never>]
        /// Recording offset at which audio began queuing into this connection's outbox.
        let acceptedFrom: TimeInterval
        /// Flipped once `session.created` arrives; a connection that dies before
        /// then never transcribed anything and folds into the ongoing outage gap.
        var isLive = false

        func close() {
            outbox.finish()
            tasks.forEach { $0.cancel() }
            socket.cancel()
            let socket = socket
            Task { try? await socket.value.close() }
        }
    }

    private struct Draining {
        let connection: Connection
        /// Holds only the windows committed on `connection`.
        var tracker: RealtimeCommitTracker
        let timeout: Task<Void, Never>
    }

    init(
        makeSocket: @escaping SocketFactory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        rotateAfter: TimeInterval = 55 * 60,
        onEvent: @escaping @Sendable (LiveTranscriptEvent) -> Void
    ) {
        self.makeSocket = makeSocket
        self.sleep = sleep
        self.clock = clock
        self.rotateAfter = rotateAfter
        self.onEvent = onEvent
    }

    /// Direct: the OpenAI key opens the socket. Worker: every (re)connect first asks
    /// `POST /v1/realtime/session` for a 60-second client secret, which only gates opening.
    static func socketFactory(backend: CoachBackend, session: URLSession = .shared) -> SocketFactory {
        {
            guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
                throw AppError.invalidProviderURL
            }
            try Task.checkCancellation()
            let key = backend.viaWorker ? try await mintClientSecret(backend: backend, session: session) : backend.token
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return URLSessionRealtimeSocket(request: request)
        }
    }

    static func mintClientSecret(backend: CoachBackend, session: URLSession) async throws -> String {
        var request = URLRequest(url: backend.baseURL.appending(path: "realtime/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        backend.authorize(&request)
        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = root?["value"] as? String, !value.isEmpty else {
            throw AppError.apiError(statusCode: 0, message: "invalid realtime session")
        }
        return value
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
        if let connection, connection.isLive, tracker.commit() {
            connection.outbox.yield(#"{"type":"input_audio_buffer.commit"}"#)
        }
        // Bounded wait for the last window's final.
        for _ in 0..<80 where (connection?.isLive == true && tracker.hasOutstanding) || draining != nil {
            try? await sleep(.milliseconds(100))
        }
        closeDraining(reportGaps: true)
        closeConnection(reportGaps: true)
        if let start = gapStart, tracker.now > start {
            onEvent(.gap(LiveTranscriptGap(start: start, end: tracker.now)))
            gapStart = nil
        }
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
        closeDraining(reportGaps: false)
        closeConnection(reportGaps: false)
        gapStart = nil
        pending.removeAll()
        partialCallback = nil
    }

    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {
        partialCallback = callback
    }

    func getPartialTranscript() -> String { deltas.map(\.text).joined() }

    // MARK: Connection

    /// - Parameter rotating: a planned hand-over from a live session, which the UI does not see.
    private func connect(rotating: Bool = false) {
        guard !finished else { return }
        generation += 1
        let id = generation
        if !rotating { onEvent(.connection(reconnectAttempt == 0 ? .connecting : .reconnecting)) }
        let opening = Task { [makeSocket] in try await makeSocket() }
        let (stream, outbox) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(Self.outboxLimit))
        outbox.yield(Self.sessionUpdate)
        let sender = Task { [weak self] in
            let socket: any RealtimeSocket
            do {
                socket = try await opening.value
            } catch is CancellationError {
                await self?.connectionCancelled(id)
                return
            } catch {
                if Task.isCancelled {
                    await self?.connectionCancelled(id)
                    return
                }
                AppLog.transcription.atError.error("OpenAILiveTranscriber: socket creation failed code=\(error.publicLogCode, privacy: .public)")
                await self?.connectionLost(id, code: error.publicLogCode)
                return
            }
            for await message in stream {
                do { try await socket.send(message) } catch {
                    await self?.connectionLost(id, code: error.publicLogCode)
                    return
                }
            }
        }
        let receiver = Task { [weak self] in
            guard let socket = try? await opening.value else { return }
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
        connection = Connection(id: id, socket: opening, outbox: outbox, tasks: [sender, receiver], acceptedFrom: tracker.now)
        rotateAt = clock() + rotateAfter
    }

    /// Moves the live session to `draining` and opens its successor. Called right
    /// after a commit, so the old session owns no partially sent window.
    private func rotate() {
        guard let old = connection, draining == nil else { return }
        AppLog.transcription.atNotice.notice("OpenAILiveTranscriber: rotating session before expiry")
        let oldTracker = tracker
        _ = tracker.abandonPending()   // those windows now belong to the draining session
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.drainTimeout)
            guard !Task.isCancelled else { return }
            await self?.closeDraining(reportGaps: true)
        }
        draining = Draining(connection: old, tracker: oldTracker, timeout: timeout)
        connection = nil
        connect(rotating: true)
    }

    private func handleDraining(_ event: RealtimeServerEvent) {
        guard var state = draining else { return }
        switch event {
        case .committed(let itemID):
            state.tracker.acknowledge(itemID: itemID)
        case .completed(let itemID, let transcript, let seconds):
            deltas.removeAll { $0.id == itemID }
            partialCallback?(getPartialTranscript())
            if let seconds { onEvent(.billedSeconds(seconds)) }
            if let segment = state.tracker.complete(itemID: itemID, text: transcript) {
                finals.append(transcript)
                if !transcript.isEmpty {
                    onEvent(.final(LiveTranscriptSegment(start: segment.start, end: segment.end,
                                                         text: transcript, arrivedAt: tracker.now)))
                }
            }
        case .error(let code, let message):
            if code == "input_audio_buffer_commit_empty" { state.tracker.rejectOldest() }
            AppLog.transcription.atError.error("OpenAILiveTranscriber: server error (draining) code=\(code ?? "unknown", privacy: .public) detail=\(message, privacy: .private)")
        case .sessionCreated, .delta, .other:
            break
        }
        draining = state
        if !state.tracker.hasOutstanding { closeDraining(reportGaps: false) }
    }

    private func closeDraining(reportGaps: Bool) {
        guard var state = draining else { return }
        draining = nil
        state.timeout.cancel()
        state.connection.close()
        let gaps = state.tracker.abandonPending()
        if reportGaps { gaps.forEach { onEvent(.gap($0)) } }
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
            // Mark the connection lost before advancing `tracker.dropped` so `gapStart`
            // includes this chunk even when `sentInWindow == 0`.
            connectionLost(connection.id, code: "outbox_full")
            tracker.dropped(samples.count)
            return
        }
        if tracker.sent(samples.count), tracker.commit() {
            connection.outbox.yield(#"{"type":"input_audio_buffer.commit"}"#)
            if clock() >= rotateAt { rotate() }
        }
    }

    private func handle(_ text: String, from id: Int) {
        guard let event = RealtimeServerEvent.parse(Data(text.utf8)) else { return }
        if id == draining?.connection.id { handleDraining(event); return }
        guard id == connection?.id else { return }
        switch event {
        case .sessionCreated(let expiresAt):
            sessionStarted(expiresAt: expiresAt)
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

    private func sessionStarted(expiresAt: TimeInterval?) {
        reconnectAttempt = 0
        connection?.isLive = true
        if let start = gapStart {
            let end = connection?.acceptedFrom ?? tracker.now
            if end > start {
                onEvent(.gap(LiveTranscriptGap(start: start, end: end)))
            }
            gapStart = nil
        }
        // Honour a shorter server-side expiry; a stale or missing value keeps the default.
        if let expiresAt, expiresAt - Self.expiryLead > clock() {
            rotateAt = min(rotateAt, expiresAt - Self.expiryLead)
        }
        onEvent(.connection(.live))
    }

    private func connectionCancelled(_ id: Int) {
        if id == draining?.connection.id {
            closeDraining(reportGaps: false)
            return
        }
        guard id == connection?.id else { return }
        closeConnection(reportGaps: false)
    }

    private func connectionLost(_ id: Int, code: String) {
        if id == draining?.connection.id {
            AppLog.transcription.atNotice.notice("OpenAILiveTranscriber: replaced session lost code=\(code, privacy: .public)")
            closeDraining(reportGaps: true)
            return
        }
        guard id == connection?.id else { return }
        AppLog.transcription.atNotice.notice("OpenAILiveTranscriber: connection lost code=\(code, privacy: .public)")
        closeConnection(reportGaps: true)
        if gapStart == nil { gapStart = tracker.now }
        scheduleReconnect()
    }

    private func closeConnection(reportGaps: Bool) {
        guard let connection else { return }
        self.connection = nil
        connection.close()
        deltas.removeAll()
        partialCallback?("")
        let gaps = tracker.abandonPending() + [tracker.abandonWindow()].compactMap { $0 }
        if !connection.isLive {
            // Audio queued while this connection was still opening belongs to
            // the ongoing outage rather than a separate fragment.
            if reportGaps, gapStart == nil { gapStart = connection.acceptedFrom }
            return
        }
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
