import AVFoundation
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// Scripted socket: records what the transcriber sends and replays server events.
private final class FakeRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentMessages: [String] = []
    private let incoming: AsyncThrowingStream<String, Error>
    private let feed: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator?

    init() {
        (incoming, feed) = AsyncThrowingStream.makeStream(of: String.self)
        iterator = incoming.makeAsyncIterator()
    }

    var sent: [String] { lock.withLock { sentMessages } }
    func serverSends(_ json: String) { feed.yield(json) }
    func drop() { feed.finish(throwing: URLError(.networkConnectionLost)) }

    func send(_ text: String) async throws { lock.withLock { sentMessages.append(text) } }
    func receive() async throws -> String {
        var it = lock.withLock { iterator! }
        let next = try await it.next()
        lock.withLock { iterator = it }
        guard let next else { throw URLError(.networkConnectionLost) }
        return next
    }
    private var isClosed = false
    var closed: Bool { lock.withLock { isClosed } }
    func close() { lock.withLock { isClosed = true } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LiveTranscriptEvent] = []
    func add(_ event: LiveTranscriptEvent) { lock.withLock { items.append(event) } }
    var all: [LiveTranscriptEvent] { lock.withLock { items } }
    var gaps: [LiveTranscriptGap] {
        all.compactMap { if case .gap(let gap) = $0 { return gap }; return nil }
    }
}

/// Deterministic latch so reconnect tests control exactly when backoff or socket opens resolve.
private actor SignalGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var permits = 0

    func wait() async throws {
        if permits > 0 {
            permits -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }

    private func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

private func buffer(seconds: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    let frames = AVAudioFrameCount(seconds * 24_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    return buffer
}

struct OpenAILiveTranscriberTests {
    @Test func commitsEvery20SecondsAndReportsGapsOnDisconnect() async throws {
        let sockets = [FakeRealtimeSocket(), FakeRealtimeSocket()]
        let counter = NSLock()
        nonisolated(unsafe) var index = 0
        let log = EventLog()
        let engine = OpenAILiveTranscriber(
            makeSocket: { counter.withLock { defer { index += 1 }; return sockets[min(index, 1)] } },
            // Reconnect backoff shortened, but long enough to append "offline" audio first.
            sleep: { _ in try await Task.sleep(for: .milliseconds(500)) },
            onEvent: { log.add($0) }
        )
        try await engine.loadModels()
        let first = sockets[0]
        first.serverSends(#"{"type":"session.created","session":{"expires_at":1}}"#)
        await waitUntil { log.all.contains(.connection(.live)) }
        #expect(first.sent.first?.contains(#""languages":["zh-tw"]"#) == true)
        #expect(first.sent.first?.contains("keywords") == false)

        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { first.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        #expect(first.sent.filter { $0.contains("input_audio_buffer.append") }.count == 200)

        first.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i1"}"#)
        first.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"开会","usage":{"type":"duration","seconds":20}}"#)
        await waitUntil { log.all.contains { if case .final = $0 { return true }; return false } }
        #expect(log.all.contains(.final(LiveTranscriptSegment(start: 0, end: 20, text: "开会", arrivedAt: 20))))
        #expect(log.all.contains(.billedSeconds(20)))

        // 5 s appended to the live socket, then it drops: those 5 s become a gap.
        try await engine.appendAudio(buffer(seconds: 5))
        try await engine.processBufferedAudio()
        first.drop()
        await waitUntil { log.all.contains(.gap(LiveTranscriptGap(start: 20, end: 25))) }
        #expect(log.all.contains(.gap(LiveTranscriptGap(start: 20, end: 25))))
        #expect(log.all.contains(.connection(.reconnecting)))

        // Offline for 3 s: dropped audio is a gap, closed when the new session starts.
        try await engine.appendAudio(buffer(seconds: 3))
        try await engine.processBufferedAudio()
        let second = sockets[1]
        await waitUntil { !second.sent.isEmpty }
        second.serverSends(#"{"type":"session.created","session":{"expires_at":2}}"#)
        await waitUntil { log.all.contains(.gap(LiveTranscriptGap(start: 25, end: 28))) }
        #expect(log.all.contains(.gap(LiveTranscriptGap(start: 25, end: 28))))
        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { second.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        second.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i2"}"#)
        second.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i2","transcript":"恢复"}"#)
        let resumed = LiveTranscriptSegment(start: 28, end: 48, text: "恢复", arrivedAt: 48)
        await waitUntil { log.all.contains(.final(resumed)) }
        #expect(log.all.contains(.final(resumed)))
        await engine.cleanup()
    }

    @Test func audioQueuesWhileTheSocketIsStillOpeningAndAFailedOpenReconnects() async throws {
        let socket = FakeRealtimeSocket()
        let attempts = NSLock()
        nonisolated(unsafe) var count = 0
        let log = EventLog()
        let engine = OpenAILiveTranscriber(
            makeSocket: {
                // First open fails (e.g. the Worker could not mint a key), the second is slow.
                let attempt = attempts.withLock { count += 1; return count }
                if attempt == 1 { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(300))
                return socket
            },
            sleep: { _ in },
            onEvent: { log.add($0) }
        )
        try await engine.loadModels()
        await waitUntil { attempts.withLock { count } == 2 }
        // Appended while the second open is still in flight.
        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { socket.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        #expect(socket.sent.first?.contains("session.update") == true)
        #expect(socket.sent.filter { $0.contains("input_audio_buffer.append") }.count == 200)
        // Nothing was dropped: the only "gap" is the empty one between the failed open and the retry.
        socket.serverSends(#"{"type":"session.created","session":{}}"#)
        await waitUntil { log.all.contains(.connection(.live)) }
        #expect(!log.all.contains { if case .gap(let gap) = $0 { return gap.end > 0 }; return false })
        await engine.cleanup()
    }

    @Test func rotatesToAFreshSessionBeforeExpiryWithoutLosingAudio() async throws {
        let sockets = [FakeRealtimeSocket(), FakeRealtimeSocket()]
        let counter = NSLock()
        nonisolated(unsafe) var index = 0
        let log = EventLog()
        let clock = TestClock()
        let engine = OpenAILiveTranscriber(
            makeSocket: { counter.withLock { defer { index += 1 }; return sockets[min(index, 1)] } },
            clock: { clock.now },
            onEvent: { log.add($0) }
        )
        try await engine.loadModels()
        let old = sockets[0], next = sockets[1]
        old.serverSends(#"{"type":"session.created","session":{"expires_at":1}}"#)
        await waitUntil { log.all.contains(.connection(.live)) }

        // Window 1 commits normally on the first session.
        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        old.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i1"}"#)

        // 55 minutes later: window 2 still goes to the old session, then it hands over.
        clock.now = 55 * 60 + 1
        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { !next.sent.isEmpty }
        #expect(counter.withLock { index } == 2)

        // Window 3 goes only to the new session.
        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { next.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        #expect(old.sent.filter { $0.contains("input_audio_buffer.append") }.count == 400)
        #expect(next.sent.filter { $0.contains("input_audio_buffer.append") }.count == 200)
        #expect(next.sent.first?.contains("session.update") == true)

        // The old session's late finals still arrive and keep their own windows.
        old.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i2"}"#)
        old.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"一"}"#)
        old.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i2","transcript":"二"}"#)
        // The two sockets are read by separate tasks; let the old session's finals land first so the order is fixed.
        await waitUntil { log.all.filter { if case .final = $0 { return true }; return false }.count == 2 }
        next.serverSends(#"{"type":"session.created","session":{}}"#)
        next.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"j1"}"#)
        next.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"j1","transcript":"三"}"#)
        await waitUntil { log.all.filter { if case .final = $0 { return true }; return false }.count == 3 && old.closed }
        let finals = log.all.compactMap { event -> LiveTranscriptSegment? in
            if case .final(let segment) = event { return segment }
            return nil
        }
        #expect(finals.map(\.text) == ["一", "二", "三"])
        #expect(finals.map(\.start) == [0, 20, 40])
        #expect(finals.map(\.end) == [20, 40, 60])
        #expect(old.closed)
        #expect(!next.closed)
        #expect(!log.all.contains { if case .gap = $0 { return true }; return false })
        #expect(!log.all.contains(.connection(.reconnecting)))
        await engine.cleanup()
    }

    @Test func repeatedFailedReconnectsReportOneContinuousGapUntilLiveAgain() async throws {
        let first = FakeRealtimeSocket()
        let recovered = FakeRealtimeSocket()
        let backoffGate = SignalGate()
        let slowFailGate = SignalGate()
        let attempts = NSLock()
        nonisolated(unsafe) var attempt = 0
        let log = EventLog()

        let engine = OpenAILiveTranscriber(
            makeSocket: {
                let current = attempts.withLock { attempt += 1; return attempt }
                switch current {
                case 1:
                    return first
                case 2:
                    // Fails only after some audio has been queued during opening.
                    try await slowFailGate.wait()
                    throw URLError(.notConnectedToInternet)
                case 3:
                    // Fails immediately during reconnect.
                    throw URLError(.timedOut)
                default:
                    return recovered
                }
            },
            sleep: { _ in try await backoffGate.wait() },
            onEvent: { log.add($0) }
        )
        try await engine.loadModels()
        first.serverSends(#"{"type":"session.created","session":{"expires_at":1}}"#)
        await waitUntil { log.all.contains(.connection(.live)) }

        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { first.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        first.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i1"}"#)
        first.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"開場"}"#)
        await waitUntil { log.all.contains { if case .final = $0 { return true }; return false } }

        // 5 s uncommitted on live socket, then it drops.
        try await engine.appendAudio(buffer(seconds: 5))
        try await engine.processBufferedAudio()
        first.drop()
        await waitUntil { log.gaps.contains(LiveTranscriptGap(start: 20, end: 25)) }

        // Outage segment 1: 3 s dropped during backoff #1 (25..28), then reconnect #1 starts opening.
        try await engine.appendAudio(buffer(seconds: 3))
        try await engine.processBufferedAudio()
        await backoffGate.release()
        await waitUntil { attempts.withLock { attempt } == 2 }

        // Outage segment 2: 2 s queued while reconnect #1 is opening (28..30), then open fails.
        try await engine.appendAudio(buffer(seconds: 2))
        try await engine.processBufferedAudio()
        await slowFailGate.release()
        await waitUntil { log.all.filter { $0 == .connection(.reconnecting) }.count >= 3 }

        // Outage segment 3: 4 s dropped during backoff #2 (30..34), reconnect #2 fails immediately.
        try await engine.appendAudio(buffer(seconds: 4))
        try await engine.processBufferedAudio()
        await backoffGate.release()
        await waitUntil { attempts.withLock { attempt } == 3 }
        await waitUntil { log.all.filter { $0 == .connection(.reconnecting) }.count >= 5 }

        // Outage segment 4: 6 s dropped during backoff #3 (34..40), reconnect #3 succeeds.
        try await engine.appendAudio(buffer(seconds: 6))
        try await engine.processBufferedAudio()
        await backoffGate.release()
        await waitUntil { attempts.withLock { attempt } == 4 && !recovered.sent.isEmpty }
        recovered.serverSends(#"{"type":"session.created","session":{"expires_at":2}}"#)
        await waitUntil { log.all.filter { $0 == .connection(.live) }.count == 2 }

        // Expect the dead socket's uncommitted tail [20, 25] plus ONE continuous gap [25, 40].
        #expect(log.gaps == [
            LiveTranscriptGap(start: 20, end: 25),
            LiveTranscriptGap(start: 25, end: 40)
        ])

        // Audio after recovery aligns cleanly at 40..60.
        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { recovered.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        recovered.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i2"}"#)
        recovered.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i2","transcript":"回來"}"#)
        let resumed = LiveTranscriptSegment(start: 40, end: 60, text: "回來", arrivedAt: 60)
        await waitUntil { log.all.contains(.final(resumed)) }
        #expect(log.all.contains(.final(resumed)))
        await engine.cleanup()
    }

    @Test func stoppingWhileDisconnectedReportsGapUntilStop() async throws {
        let first = FakeRealtimeSocket()
        let backoffGate = SignalGate()
        let attempts = NSLock()
        nonisolated(unsafe) var attempt = 0
        let log = EventLog()

        let engine = OpenAILiveTranscriber(
            makeSocket: {
                let current = attempts.withLock { attempt += 1; return attempt }
                if current == 1 { return first }
                throw URLError(.notConnectedToInternet)
            },
            sleep: { _ in try await backoffGate.wait() },
            onEvent: { log.add($0) }
        )
        try await engine.loadModels()
        first.serverSends(#"{"type":"session.created","session":{"expires_at":1}}"#)
        await waitUntil { log.all.contains(.connection(.live)) }

        try await engine.appendAudio(buffer(seconds: 20))
        try await engine.processBufferedAudio()
        await waitUntil { first.sent.contains(#"{"type":"input_audio_buffer.commit"}"#) }
        first.serverSends(#"{"type":"input_audio_buffer.committed","item_id":"i1"}"#)
        first.serverSends(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"前半"}"#)
        await waitUntil { log.all.contains { if case .final = $0 { return true }; return false } }

        // 5 s sent then socket drops -> [20, 25] gap.
        try await engine.appendAudio(buffer(seconds: 5))
        try await engine.processBufferedAudio()
        first.drop()
        await waitUntil { log.gaps.contains(LiveTranscriptGap(start: 20, end: 25)) }

        // 3 s offline, one failed reconnect, then 7 s more offline, then stop while disconnected.
        try await engine.appendAudio(buffer(seconds: 3))
        try await engine.processBufferedAudio()
        await backoffGate.release()
        await waitUntil { attempts.withLock { attempt } == 2 }
        await waitUntil { log.all.filter { $0 == .connection(.reconnecting) }.count >= 3 }

        try await engine.appendAudio(buffer(seconds: 7))
        try await engine.processBufferedAudio()
        _ = try await engine.finish()

        #expect(log.gaps == [
            LiveTranscriptGap(start: 20, end: 25),
            LiveTranscriptGap(start: 25, end: 35)
        ])
        #expect(log.all.last == .connection(.stopped))
    }

    @Test func stoppingWhileNeverConnectedReportsOneContinuousGapFromStart() async throws {
        let backoffGate = SignalGate()
        let log = EventLog()

        let engine = OpenAILiveTranscriber(
            makeSocket: { throw URLError(.notConnectedToInternet) },
            sleep: { _ in try await backoffGate.wait() },
            onEvent: { log.add($0) }
        )
        try await engine.loadModels()
        await waitUntil { log.all.contains(.connection(.reconnecting)) }

        try await engine.appendAudio(buffer(seconds: 12))
        try await engine.processBufferedAudio()
        _ = try await engine.finish()

        #expect(log.gaps == [LiveTranscriptGap(start: 0, end: 12)])
        #expect(log.all.last == .connection(.stopped))
    }
}
