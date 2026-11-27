import Foundation

/// Decides, per finalized transcript segment, which events (if any) should wake the
/// judge. Replaceable so a later design (delta-based early commit, VAD pauses,
/// speaker changes) can slot in without touching the coach session.
public protocol SuggestionTriggerStrategy: Sendable {
    /// Event labels for this segment; empty means "no call".
    mutating func events(for segment: LiveTranscriptSegment) -> [String]
}

/// Round-4 spike trigger (textllm/trigger.py): question, user named, and a
/// 3-minute no-event fallback. Pause and long-monologue events need speaker or
/// VAD information the cloud transcript does not carry, so they are not here.
public struct EventSuggestionTrigger: SuggestionTriggerStrategy {
    public static let questionLabel = "問句"
    public static let namedLabel = "點名使用者"
    public static let fallbackLabel = "3 分鐘保底"

    private static let question = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"[？?]|嗎|呢|要不要|是不是|\b(what|how|why|should|can we|do we|is it)\b"#,
        options: [.caseInsensitive]
    )

    private let mentionsUser: @Sendable (String) -> Bool
    private let fallbackAfter: TimeInterval
    private var lastEvent: TimeInterval = 0

    public init(fallbackAfter: TimeInterval = 180, mentionsUser: @escaping @Sendable (String) -> Bool) {
        self.fallbackAfter = fallbackAfter
        self.mentionsUser = mentionsUser
    }

    public static func isQuestion(_ text: String) -> Bool {
        question.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public mutating func events(for segment: LiveTranscriptSegment) -> [String] {
        var labels: [String] = []
        if Self.isQuestion(segment.text) { labels.append(Self.questionLabel) }
        if mentionsUser(segment.text) { labels.append(Self.namedLabel) }
        if labels.isEmpty, segment.arrivedAt - lastEvent >= fallbackAfter { labels.append(Self.fallbackLabel) }
        if !labels.isEmpty { lastEvent = segment.arrivedAt }
        return labels.sorted()
    }
}

/// The user messages the spike sent, rebuilt from app state.
public enum CoachMessages {
    public static func instructions(_ template: String, user: String) -> String {
        template.replacingOccurrences(of: "{USER}", with: user)
    }

    static func seconds(_ value: TimeInterval) -> String { String(format: "%.0f", value) }

    static func line(_ s: LiveTranscriptSegment) -> String { "[\(seconds(s.start))–\(seconds(s.end))] \(s.text)" }

    /// Segments visible at `now` that end within the last `span` seconds.
    public static func recentContext(_ segments: [LiveTranscriptSegment], now: TimeInterval, span: TimeInterval = 180) -> String {
        segments.filter { $0.arrivedAt <= now && $0.end >= now - span }.map(line).joined(separator: "\n")
    }

    static func previousCards(_ cards: [String]) -> String {
        cards.isEmpty ? "（尚無）" : cards.map { "- \($0)" }.joined(separator: "\n")
    }

    public static func trigger(segments: [LiveTranscriptSegment], now: TimeInterval, events: [String], cards: [String]) -> String {
        "## 最近 3 分鐘逐字稿（到第 \(seconds(now)) 秒）\n\(recentContext(segments, now: now))\n\n## 偵測到的事件\n\(events.joined(separator: "、"))\n\n## 已出過的卡\n\(previousCards(cards))"
    }

    public static func ask(segments: [LiveTranscriptSegment], now: TimeInterval, cards: [String]) -> String {
        "## 最近 3 分鐘逐字稿（到第 \(seconds(now)) 秒）\n\(recentContext(segments, now: now))\n\n## 已出過的卡\n\(previousCards(cards))\n\n\(CoachPrompts.ask)"
    }

    public static func wrapUp(segments: [LiveTranscriptSegment]) -> String {
        "## 會議逐字稿（完整）\n\(segments.map(line).joined(separator: "\n"))\n\n\(CoachPrompts.wrap)"
    }
}

/// `emit_suggestion` arguments.
public struct CoachCardArguments: Codable, Equatable, Sendable {
    public let shortText: String
    public let reason: String
    public let evidenceStart: Double?
    public let evidenceEnd: Double?
    public let category: String?

    enum CodingKeys: String, CodingKey {
        case shortText = "short_text", reason, evidenceStart = "evidence_start", evidenceEnd = "evidence_end", category
    }
}

/// `emit_wrapup` arguments.
public struct CoachWrapUpArguments: Codable, Equatable, Sendable {
    public let commonGoal: String
    public let disagreements: String
    public let openQuestions: String
    public let nextSteps: String
    public let spokenText: String

    enum CodingKeys: String, CodingKey {
        case commonGoal = "common_goal", disagreements, openQuestions = "open_questions", nextSteps = "next_steps", spokenText = "spoken_text"
    }
}

/// `judge` arguments.
public struct CoachJudgeArguments: Codable, Equatable, Sendable {
    public let decision: String
    public let reason: String
}

/// One trigger evaluation, kept so prompts and thresholds can be tuned later.
public struct CoachTriggerRecord: Codable, Equatable, Sendable {
    public let offset: TimeInterval
    public let events: [String]
    public let decision: String
    public let reason: String
    public init(offset: TimeInterval, events: [String], decision: String, reason: String) {
        self.offset = offset; self.events = events; self.decision = decision; self.reason = reason
    }
}
