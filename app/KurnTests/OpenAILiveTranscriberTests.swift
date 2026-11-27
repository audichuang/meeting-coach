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
}
