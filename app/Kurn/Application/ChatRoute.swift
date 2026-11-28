//
//  ChatRoute.swift
//  Kurn
//
//  Which provider answers meeting and library chat. With the coach backend
//  configured, chat goes to the Worker's `/v1/responses` like the recap: its
//  model's window holds a whole long transcript, which the on-device model's
//  does not (that path falls back to three-call retrieval and cannot run in
//  the background). Without it, chat keeps the summary provider.
//

import Foundation
import KurnCore

struct ChatRoute: Equatable {
    let provider: AIProvider
    let model: String

    var viaCoach: Bool { provider.id == AIProvider.meetingCoach.id }

    @MainActor
    static func resolve(settings: AppSettings, backend: CoachBackend? = CoachBackend.current()) -> ChatRoute {
        if let backend, !backend.notConfigured {
            return ChatRoute(provider: backend.provider, model: settings.coachChatModel)
        }
        let provider = settings.aiProvider
        return ChatRoute(provider: provider, model: settings.summaryModel(for: provider))
    }

    /// `ProviderFactory.liveLLM`, except the coach route, which goes to the Worker and
    /// reports each call's spend (rewrite and rerank included) through `onSpend`.
    static func resolver(onSpend: @escaping @MainActor @Sendable (Double) -> Void) -> ProviderFactory.LLMResolver {
        { provider, model in
            guard provider.id == AIProvider.meetingCoach.id else { return try ProviderFactory.liveLLM(provider, model) }
            guard let backend = CoachBackend.current() else { throw AppError.noAPIKey(provider: provider.displayName) }
            try backend.requireReady()
            return CoachSummaryProvider(client: CoachResponsesClient(backend: backend), model: model) { usage in
                var meter = CoachCostMeter()
                meter.addTokens(model: model, usage: usage)
                let usd = meter.totalUSD
                Task { await onSpend(usd) }
            }
        }
    }
}
