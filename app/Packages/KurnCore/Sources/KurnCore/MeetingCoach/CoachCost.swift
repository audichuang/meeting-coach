import Foundation

/// Every price the meeting coach pays, in one place.
/// Source: https://developers.openai.com/api/docs/pricing (read 2026-11-27).
public enum CoachPricing {
    public static let liveTranscribeModel = "gpt-live-transcribe"
    public static let judgeModel = "gpt-6-luna"
    public static let cardModel = "gpt-6.1-terra"

    /// `gpt-live-transcribe`: USD per audio minute.
    public static let liveTranscribePerMinute = 0.017

    /// Post-meeting formal transcript.
    public static let transcribeModel = "gpt-transcribe"
    /// `gpt-transcribe`: USD per audio minute (no per-token rate is listed).
    public static let transcribePerMinute = 0.0045

    /// USD per 1M tokens; output includes reasoning tokens.
    public struct TokenRates: Sendable {
        public let input: Double
        public let cached: Double
        public let output: Double
    }

    public static func tokenRates(model: String) -> TokenRates? {
        switch model {
        case "gpt-6.1-terra": return TokenRates(input: 1, cached: 0.05, output: 5)
        case "gpt-6-luna": return TokenRates(input: 0.10, cached: 0.01, output: 0.50)
        default: return nil
        }
    }
}

public struct CoachTokenUsage: Codable, Equatable, Sendable {
    public let input: Int
    public let cached: Int
    public let output: Int
    public init(input: Int, cached: Int, output: Int) { self.input = input; self.cached = cached; self.output = output }
}

/// Accumulates the session's spend from usage the API reported.
public struct CoachCostMeter: Codable, Equatable, Sendable {
    public private(set) var totalUSD: Double = 0
    public private(set) var transcribedSeconds: Double = 0
    public init() {}

    public mutating func addTranscription(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        transcribedSeconds += seconds
        totalUSD += seconds / 60 * CoachPricing.liveTranscribePerMinute
    }

    public mutating func addTokens(model: String, usage: CoachTokenUsage) {
        guard let rate = CoachPricing.tokenRates(model: model) else { return }
        let uncached = max(0, usage.input - usage.cached)
        totalUSD += (Double(uncached) * rate.input + Double(usage.cached) * rate.cached + Double(usage.output) * rate.output) / 1_000_000
    }
}

/// Per-meeting spend guard: crossing the threshold asks the user; no answer within
/// the grace period stops AI processing (recording is not affected).
/// Continuing re-arms the guard one more threshold higher.
public struct CoachBudgetGuard: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case normal
        case warning(since: Date)
        case stopped
    }

    public let threshold: Double
    public let grace: TimeInterval
    public private(set) var nextWarningAt: Double
    public private(set) var state: State = .normal

    public init(threshold: Double, grace: TimeInterval = 300) {
        self.threshold = max(0.01, threshold)
        self.grace = grace
        self.nextWarningAt = self.threshold
    }

    /// Advance with the current spend and clock; returns the new state.
    @discardableResult
    public mutating func update(cost: Double, now: Date) -> State {
        switch state {
        case .normal where cost >= nextWarningAt:
            state = .warning(since: now)
        case .warning(let since) where now.timeIntervalSince(since) >= grace:
            state = .stopped
        default:
            break
        }
        return state
    }

    public mutating func continueSpending(cost: Double) {
        guard case .warning = state else { return }
        state = .normal
        while nextWarningAt <= cost { nextWarningAt += threshold }
    }
}
