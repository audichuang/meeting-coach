//
//  CoachResponsesClient.swift
//  Kurn
//
//  The meeting coach's text-model calls (judge, card, wrap-up): one OpenAI
//  Responses request with a function tool, shaped exactly like the spike's
//  `llm_cards.call` (reasoning effort low, tool_choice auto or forced).
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
    let apiKey: String
    var session: URLSession = .shared

    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else { throw AppError.invalidProviderURL }
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
        return try Self.parse(data)
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
        let usage = root["usage"] as? [String: Any] ?? [:]
        let cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        return CoachCallResult(calls: calls, usage: CoachTokenUsage(
            input: usage["input_tokens"] as? Int ?? 0, cached: cached, output: usage["output_tokens"] as? Int ?? 0
        ))
    }
}
