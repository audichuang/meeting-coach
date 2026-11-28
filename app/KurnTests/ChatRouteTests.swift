//
//  ChatRouteTests.swift
//  KurnTests
//
//  With the coach backend configured, meeting chat goes to the Worker with
//  the chosen model and reads a long transcript in one pass (the on-device
//  route took three calls and stopped in the background); without it, chat
//  keeps the summary provider.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct ChatRouteTests {
    private let worker = CoachBackend(baseURL: URL(string: "https://worker.test/v1")!, token: "mc_test", viaWorker: true)

    private func makeSettings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "ChatRouteTests-\(UUID().uuidString)"))
        return AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
    }

    @Test func theCoachBackendAnswersWithTheDefaultModel() throws {
        let route = ChatRoute.resolve(settings: try makeSettings(), backend: worker)
        #expect(route.viaCoach)
        #expect(route.provider.baseURLString == "https://worker.test/v1")
        #expect(route.model == "gpt-6.1-terra")
    }

    @Test func thePickedModelIsUsedAndRemembered() throws {
        let settings = try makeSettings()
        settings.coachChatModel = "gpt-6-luna"
        #expect(ChatRoute.resolve(settings: settings, backend: worker).model == "gpt-6-luna")
        #expect(CoachPricing.chatModels == ["gpt-6.1-terra", "gpt-6-luna"])
    }

    @Test func withoutACoachBackendChatKeepsTheSummaryProvider() throws {
        let settings = try makeSettings()
        for backend in [nil, CoachBackend.unconfigured] {
            let route = ChatRoute.resolve(settings: settings, backend: backend)
            #expect(!route.viaCoach)
            #expect(route.provider == settings.aiProvider)
            #expect(route.model == settings.summaryModel(for: settings.aiProvider))
        }
    }

    @Test func aNinetyFiveMinuteTranscriptIsAnsweredInOnePassOnTheCoachRoute() async throws {
        // About 340 Chinese characters a minute (one line every 10 s), in the `[mm:ss] Speaker: text` lines chat sends.
        let line = "[12:34] Speaker 1: " + String(repeating: "我們下週一上線", count: 8)
        let transcript = Array(repeating: line, count: 95 * 6).joined(separator: "\n")
        let route = ChatRoute.resolve(settings: try makeSettings(), backend: worker)
        #expect(ContextBudget.resolve(provider: route.provider, model: route.model).fits(transcript))
        #expect(!ContextBudget.conservative.fits(transcript)) // what an unknown model got before

        let llm = ScriptedLLMProvider(chat: { _, _ in "週一 [12:34]。" })
        let phases = PhaseLog()
        let answer = try await MeetingChatService(resolveProvider: { _, _ in llm }).answerAboutMeeting(
            question: "這會議在說什麼", history: [], transcriptText: transcript, candidates: [],
            provider: route.provider, model: route.model, onEvent: { phases.append($0) }
        )
        #expect(answer.text == "週一 [12:34]。")
        #expect(llm.chatCalls.count == 1)
        #expect(!phases.events.contains { if case .phase(.rewritingQuery) = $0 { true } else { false } })
    }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ChatStreamEvent] = []
    var events: [ChatStreamEvent] { lock.withLock { _events } }
    func append(_ event: ChatStreamEvent) { lock.withLock { _events.append(event) } }
}

extension ProviderHTTPTests {
    /// Chat over the Worker's `/v1/responses`: the history as input messages,
    /// the reply's text and usage back, and the usage reported for the meeting's spend.
    @Suite
    struct CoachChatProviderTests {
        @Test func chatSendsTheConversationAndReportsUsage() async throws {
            MockURLProtocol.enqueue([MockURLProtocol.json([
                "status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": "週一上線 [00:42]。"]]]],
                "usage": ["input_tokens": 40_000, "output_tokens": 300, "input_tokens_details": ["cached_tokens": 0]]
            ])])
            let backend = CoachBackend(baseURL: URL(string: "https://worker.test/v1")!, token: "mc_test", viaWorker: true)
            let reported = UsageBox()
            let llm = CoachSummaryProvider(
                client: CoachResponsesClient(backend: backend, session: MockURLProtocol.session()),
                model: "gpt-6.1-terra", onUsage: { reported.set($0) }
            )

            let collected = UsageBox()
            let usage = try await llm.streamChat(
                systemPrompt: "Answer from the transcript.",
                messages: [
                    ChatMessage(role: .user, content: "Earlier?"),
                    ChatMessage(role: .assistant, content: "Yes."),
                    ChatMessage(role: .user, content: "When do we ship?")
                ],
                onDelta: { collected.text += $0 }
            )

            #expect(collected.text == "週一上線 [00:42]。")
            #expect(usage == TokenUsage(promptTokens: 40_000, completionTokens: 300))
            #expect(reported.value == CoachTokenUsage(input: 40_000, cached: 0, output: 300))
            let request = try #require(MockURLProtocol.lastRequest)
            #expect(request.url?.path == "/v1/responses")
            let body = try #require(JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any])
            #expect(body["model"] as? String == "gpt-6.1-terra")
            #expect(body["instructions"] as? String == "Answer from the transcript.")
            #expect(body["stream"] == nil)
            let input = try #require(body["input"] as? [[String: String]])
            #expect(input.map { $0["role"] } == ["user", "assistant", "user"])
            #expect(input.last?["content"] == "When do we ship?")
            let reportedUsage = try #require(usage)
            let cost = try #require(ModelPricing.estimatedCostUSD(model: "gpt-6.1-terra", usage: reportedUsage))
            #expect(abs(cost - 0.0415) < 1e-9)
        }
    }
}

private final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: CoachTokenUsage?
    private var _text = ""
    var value: CoachTokenUsage? { lock.withLock { _value } }
    func set(_ usage: CoachTokenUsage) { lock.withLock { _value = usage } }
    var text: String {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }
}
