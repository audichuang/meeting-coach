//
//  CoachResponsesClient.swift
//  Kurn
//
//  The meeting coach's text-model calls (judge, card, wrap-up): one OpenAI
//  Responses request with a function tool, shaped exactly like the spike's
//  `llm_cards.call` (reasoning effort low, tool_choice auto or forced).
//  `CoachSummaryProvider` sends the post-meeting summary the same way, because
//  the Worker proxies only `/v1/responses` (no streaming, no Chat Completions).
//

import Foundation
import KurnCore

struct CoachTool: Sendable {
    let name: String
    let description: String
    /// JSON schema text.
    let parameters: String
}

struct CoachToolCall: Sendable {
    let name: String
    let arguments: Data
}

struct CoachCallResult: Sendable {
    let calls: [CoachToolCall]
    let usage: CoachTokenUsage
}

protocol CoachLLM: Sendable {
    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult
}

struct CoachResponsesClient: CoachLLM {
    let backend: CoachBackend
    var session: URLSession = .shared

    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "reasoning": ["effort": "low"],
            "tools": try tools.map { tool -> [String: Any] in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": try JSONSerialization.jsonObject(with: Data(tool.parameters.utf8))]
            }
        ]
        body["tool_choice"] = force.map { ["type": "function", "name": $0] as [String: Any] } ?? "auto"
        return try Self.parse(await send(body, timeout: 60))
    }

    func send(_ body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: backend.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(backend.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await LLMHTTP.sendValidated(request, session: session).0
        } catch {
            throw CoachBackend.explained(error)
        }
    }

    static func usage(_ root: [String: Any]) -> CoachTokenUsage {
        let usage = root["usage"] as? [String: Any] ?? [:]
        let cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        return CoachTokenUsage(input: usage["input_tokens"] as? Int ?? 0, cached: cached, output: usage["output_tokens"] as? Int ?? 0)
    }

    static func parse(_ data: Data) throws -> CoachCallResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.apiError(statusCode: 0, message: "invalid response")
        }
        let output = root["output"] as? [[String: Any]] ?? []
        let calls = output.compactMap { item -> CoachToolCall? in
            guard item["type"] as? String == "function_call", let name = item["name"] as? String,
                  let args = item["arguments"] as? String else { return nil }
            return CoachToolCall(name: name, arguments: Data(args.utf8))
        }
        return CoachCallResult(calls: calls, usage: usage(root))
    }
}

/// The post-meeting summary over Responses, reporting each call's usage so the
/// coach's per-meeting spend includes it. Chat is not offered for this provider.
struct CoachSummaryProvider: LLMProvider {
    let client: CoachResponsesClient
    let model: String
    let onUsage: @Sendable (CoachTokenUsage) -> Void

    var provider: AIProvider { client.backend.provider }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        let data = try await client.send([
            "model": model,
            "instructions": systemPrompt,
            "input": userPrompt,
            "max_output_tokens": LLMHTTP.summaryMaxOutputTokens
        ], timeout: LLMHTTP.summaryTimeout)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.decodingError("invalid response")
        }
        onUsage(CoachResponsesClient.usage(root))
        if root["status"] as? String == "incomplete" { throw AppError.summaryTruncated }
        return try LLMHTTP.summaryResult(streamedText: Self.outputText(root), truncated: false, emptyMessage: "empty response")
    }

    func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
        throw AppError.summarizationUnsupported(provider: provider.displayName)
    }

    static func outputText(_ root: [String: Any]) -> String {
        let output = root["output"] as? [[String: Any]] ?? []
        return output.filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}
