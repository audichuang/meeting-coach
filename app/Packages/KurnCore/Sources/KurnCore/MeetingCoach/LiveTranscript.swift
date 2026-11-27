import Foundation

/// One finalized window of the cloud live transcript. Times are recording-relative
/// seconds derived from the audio samples streamed, never from the model.
public struct LiveTranscriptSegment: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var text: String
    /// Recording offset at which the final text arrived (what a trigger could see).
    public let arrivedAt: TimeInterval

    public init(start: TimeInterval, end: TimeInterval, text: String, arrivedAt: TimeInterval) {
        self.start = start; self.end = end; self.text = text; self.arrivedAt = arrivedAt
    }
}

/// Audio that was recorded but never transcribed live (offline, reconnecting, budget stop).
public struct LiveTranscriptGap: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public var end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
}

public enum LiveConnectionState: String, Codable, Equatable, Sendable {
    case connecting, live, reconnecting, stopped
}

/// What a live transcriber reports beside the plain preview string.
public enum LiveTranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(LiveTranscriptSegment)
    case connection(LiveConnectionState)
    case gap(LiveTranscriptGap)
    /// Billable audio seconds the API reported for one finalized item.
    case billedSeconds(Double)
}

/// The subset of OpenAI Realtime transcription server events the app consumes.
public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated(expiresAt: TimeInterval?)
    case committed(itemID: String)
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String, billedSeconds: Double?)
    case error(code: String?, message: String)
    case other(String)

    public static func parse(_ data: Data) -> RealtimeServerEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        let item = obj["item_id"] as? String ?? ""
        switch type {
        case "session.created":
            let session = obj["session"] as? [String: Any]
            return .sessionCreated(expiresAt: (session?["expires_at"] as? NSNumber)?.doubleValue)
        case "input_audio_buffer.committed":
            return .committed(itemID: item)
        case "conversation.item.input_audio_transcription.delta":
            return .delta(itemID: item, text: obj["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            let usage = obj["usage"] as? [String: Any]
            return .completed(itemID: item, transcript: obj["transcript"] as? String ?? "",
                              billedSeconds: (usage?["seconds"] as? NSNumber)?.doubleValue)
        case "error":
            let err = obj["error"] as? [String: Any]
            return .error(code: err?["code"] as? String, message: err?["message"] as? String ?? "")
        default:
            return .other(type)
        }
    }
}

/// Maps manual commits to recording time. Commits are acknowledged in order, so a
/// FIFO of the windows sent is enough to label each `committed` item.
public struct RealtimeCommitTracker: Sendable {
    public let sampleRate: Double
    public let windowSamples: Int
    /// Samples received so far, including ones discarded while disconnected.
    public private(set) var receivedSamples = 0
    private var windowStart = 0
    private var sentInWindow = 0
    private var pending: [(start: Int, end: Int)] = []
    private var labeled: [String: (start: Int, end: Int)] = [:]

    public init(sampleRate: Double = 24_000, window: TimeInterval = 20) {
        self.sampleRate = sampleRate
        self.windowSamples = Int(sampleRate * window)
    }

    public var now: TimeInterval { Double(receivedSamples) / sampleRate }

    /// Record `count` samples that were sent to the socket. Returns true when a
    /// commit is due (the window is full).
    public mutating func sent(_ count: Int) -> Bool {
        receivedSamples += count
        sentInWindow += count
        return receivedSamples - windowStart >= windowSamples
    }

    /// Record samples that could not be sent; they start a new window afterwards.
    public mutating func dropped(_ count: Int) {
        receivedSamples += count
        if sentInWindow == 0 { windowStart = receivedSamples }
    }

    /// Close the current window. Returns false when there is too little audio
    /// (< 100 ms) to commit, which the API would reject.
    public mutating func commit() -> Bool {
        guard sentInWindow >= Int(sampleRate / 10) else { return false }
        pending.append((windowStart, receivedSamples))
        windowStart = receivedSamples
        sentInWindow = 0
        return true
    }

    /// Discard audio that was appended but will never be committed (socket lost).
    public mutating func abandonWindow() -> LiveTranscriptGap? {
        defer { windowStart = receivedSamples; sentInWindow = 0 }
        guard receivedSamples > windowStart else { return nil }
        return LiveTranscriptGap(start: Double(windowStart) / sampleRate, end: now)
    }

    /// Pending windows whose results will never arrive (socket lost); returned as gaps.
    public mutating func abandonPending() -> [LiveTranscriptGap] {
        defer { pending.removeAll(); labeled.removeAll() }
        return (pending + labeled.values).sorted { $0.start < $1.start }
            .map { LiveTranscriptGap(start: Double($0.start) / sampleRate, end: Double($0.end) / sampleRate) }
    }

    public var hasOutstanding: Bool { !pending.isEmpty || !labeled.isEmpty }

    public mutating func acknowledge(itemID: String) {
        guard !pending.isEmpty else { return }
        labeled[itemID] = pending.removeFirst()
    }

    /// A commit the server rejected (e.g. empty buffer) never gets an item.
    public mutating func rejectOldest() {
        if !pending.isEmpty { pending.removeFirst() }
    }

    public mutating func complete(itemID: String, text: String) -> LiveTranscriptSegment? {
        guard let window = labeled.removeValue(forKey: itemID) else { return nil }
        return LiveTranscriptSegment(start: Double(window.start) / sampleRate, end: Double(window.end) / sampleRate,
                                     text: text, arrivedAt: now)
    }
}
