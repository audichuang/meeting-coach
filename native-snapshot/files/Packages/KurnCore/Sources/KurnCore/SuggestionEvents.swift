import Foundation

/// Recording-relative evidence; wall-clock dates are kept on the events.
public struct SuggestionEvidence: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let transcriptRevisionID: UUID?
    public let context: String

    public init(recordingID: UUID, start: TimeInterval, end: TimeInterval, transcriptRevisionID: UUID? = nil, context: String) throws {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw SuggestionEventError.invalidEvidence }
        self.recordingID = recordingID
        self.start = start
        self.end = end
        self.transcriptRevisionID = transcriptRevisionID
        self.context = context
    }

    private enum CodingKeys: String, CodingKey { case recordingID, start, end, transcriptRevisionID, context }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recordingID: c.decode(UUID.self, forKey: .recordingID),
                      start: c.decode(TimeInterval.self, forKey: .start),
                      end: c.decode(TimeInterval.self, forKey: .end),
                      transcriptRevisionID: c.decodeIfPresent(UUID.self, forKey: .transcriptRevisionID),
                      context: c.decode(String.self, forKey: .context))
    }
}

public struct SuggestionVersion: Codable, Equatable, Sendable {
    public let model: String
    public let prompt: String
    public let policy: String
    public init(model: String, prompt: String, policy: String) {
        self.model = model; self.prompt = prompt; self.policy = policy
    }
}

public struct SuggestionCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let shortText: String
    public let fullText: String
    /// Concise evidence-based explanation, never hidden model reasoning.
    public let reason: String
    public let evidence: [SuggestionEvidence]
    public let version: SuggestionVersion
    public init(id: UUID = UUID(), meetingID: UUID, shortText: String, fullText: String,
                reason: String, evidence: [SuggestionEvidence], version: SuggestionVersion) {
        self.id = id; self.meetingID = meetingID; self.shortText = shortText
        self.fullText = fullText; self.reason = reason; self.evidence = evidence; self.version = version
    }
}

public enum SuggestionEventKind: Codable, Equatable, Sendable {
    case created
    case suppressed(reason: String)
    case shown
    case expanded
    case dismissed
    case feedback(value: String)
}

public struct SuggestionEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let suggestionID: UUID
    public let occurredAt: Date
    public let meetingOffset: TimeInterval
    public let kind: SuggestionEventKind
    public init(id: UUID = UUID(), suggestionID: UUID, occurredAt: Date, meetingOffset: TimeInterval, kind: SuggestionEventKind) {
        self.id = id; self.suggestionID = suggestionID; self.occurredAt = occurredAt
        self.meetingOffset = meetingOffset; self.kind = kind
    }
}

public enum SuggestionEventError: Error, Equatable {
    case invalidEvidence, invalidTimestamp, wrongSuggestion, duplicateEvent, invalidTransition
}

/// The app should atomically persist the candidate and its creation event before
/// evaluating the display gate; later interactions are append-only events.
public struct SuggestionLedger: Sendable {
    public let candidate: SuggestionCandidate
    public private(set) var events: [SuggestionEvent]

    public init(candidate: SuggestionCandidate, createdAt: Date, meetingOffset: TimeInterval) throws {
        guard meetingOffset.isFinite, meetingOffset >= 0, createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SuggestionEventError.invalidTimestamp
        }
        self.candidate = candidate
        self.events = [SuggestionEvent(suggestionID: candidate.id, occurredAt: createdAt, meetingOffset: meetingOffset, kind: .created)]
    }

    /// Reconstruct only after validating every persisted event in order.
    public init(candidate: SuggestionCandidate, restoring events: [SuggestionEvent]) throws {
        guard let first = events.first, first.kind == .created, first.suggestionID == candidate.id else {
            throw SuggestionEventError.invalidTransition
        }
        try self.init(candidate: candidate, createdAt: first.occurredAt, meetingOffset: first.meetingOffset)
        self.events = [first]
        for event in events.dropFirst() { try append(event) }
    }

    public mutating func append(_ event: SuggestionEvent) throws {
        guard event.suggestionID == candidate.id else { throw SuggestionEventError.wrongSuggestion }
        guard !events.contains(where: { $0.id == event.id }) else { throw SuggestionEventError.duplicateEvent }
        guard event.meetingOffset.isFinite, event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              let last = events.last, event.meetingOffset >= last.meetingOffset, event.occurredAt >= last.occurredAt else {
            throw SuggestionEventError.invalidTimestamp
        }
        let hasShown = events.contains { if case .shown = $0.kind { return true }; return false }
        let closed = events.contains { switch $0.kind { case .suppressed, .dismissed: return true; default: return false } }
        switch event.kind {
        case .created: throw SuggestionEventError.invalidTransition
        case .suppressed, .shown:
            guard !hasShown, !closed else { throw SuggestionEventError.invalidTransition }
        case .expanded, .dismissed:
            guard hasShown, !closed else { throw SuggestionEventError.invalidTransition }
        case .feedback:
            guard hasShown else { throw SuggestionEventError.invalidTransition }
        }
        events.append(event)
    }
}

public enum SuggestionGateDecision: Equatable, Sendable {
    case show
    case suppress(reason: String)
}

/// `shownOffsets` must contain only displayed events from the same meeting.
/// Boundaries are inclusive for the minimum gap and exclusive for the rolling window.
public struct SuggestionThrottle: Sendable {
    public let minimumGap: TimeInterval
    public let window: TimeInterval
    public let maximumInWindow: Int
    public init(minimumGap: TimeInterval = 90, window: TimeInterval = 600, maximumInWindow: Int = 3) {
        precondition(minimumGap.isFinite && minimumGap >= 0 && window.isFinite && window > 0 && maximumInWindow > 0)
        self.minimumGap = minimumGap; self.window = window; self.maximumInWindow = maximumInWindow
    }
    public func decide(at now: TimeInterval, shownOffsets: [TimeInterval]) throws -> SuggestionGateDecision {
        guard now.isFinite, now >= 0, shownOffsets.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= now }) else {
            throw SuggestionEventError.invalidTimestamp
        }
        if let last = shownOffsets.max(), now - last < minimumGap { return .suppress(reason: "minimum_gap") }
        if shownOffsets.filter({ now - $0 < window }).count >= maximumInWindow { return .suppress(reason: "window_limit") }
        return .show
    }
}
