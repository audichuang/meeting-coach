//
//  FoundationModelsProviderTests.swift
//  KurnTests
//
//  `SystemLanguageModel.default.availability` can't be forced into a specific
//  state from a test (and CI's simulator has no Apple Intelligence to exercise
//  a live response against), so these exercise the pure logic around it
//  instead: prompt folding and output-token clamping.
//

import Foundation
import FoundationModels
import KurnCore
import Testing
@testable import Kurn

struct FoundationModelsProviderTests {

    // MARK: - foldPrompt

    @Test func foldPromptDropsSystemMessagesAndJoinsUserAssistantTurns() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: "What did we decide?"),
            ChatMessage(role: .assistant, content: "You decided to ship it.")
        ]
        let folded = FoundationModelsProvider.foldPrompt(messages)
        #expect(!folded.contains("helpful assistant"))
        #expect(folded == "User: What did we decide?\n\nAssistant: You decided to ship it.")
    }

    @Test func foldPromptOnEmptyMessagesIsEmptyString() {
        #expect(FoundationModelsProvider.foldPrompt([]).isEmpty)
    }

    @Test func foldPromptOnOnlySystemMessagesIsEmptyString() {
        let messages = [ChatMessage(role: .system, content: "Only instructions.")]
        #expect(FoundationModelsProvider.foldPrompt(messages).isEmpty)
    }

    // MARK: - clampedOutputTokens

    @Test func clampedOutputTokensCapsAValueAboveTheOnDeviceCeiling() {
        // The cloud chat/document budgets (4096-8192) alone would exceed the
        // on-device session window, so a request at that scale must be capped.
        #expect(FoundationModelsProvider.clampedOutputTokens(8192) < 8192)
    }

    @Test func clampedOutputTokensPassesThroughASmallerValueUnchanged() {
        #expect(FoundationModelsProvider.clampedOutputTokens(200) == 200)
    }

    // MARK: - AIProvider.isUsable

    // MARK: - readableError

    @Test func anUnrecognisedFrameworkErrorReadsAsInterruptedNotAsAPIErrorZero() {
        // What the field report showed: "API 錯誤 0：… LanguageModelError 錯誤-1".
        let raw = NSError(domain: "FoundationModels.LanguageModelError", code: -1)
        guard case .onDeviceModelUnavailable(let reason)? = FoundationModelsProvider.readableError(raw) as? AppError else {
            Issue.record("expected an on-device AppError")
            return
        }
        #expect(reason == NSLocalizedString("error.on_device_interrupted", comment: ""))
    }

    @Test func cancellationAndAppErrorsPassThrough() {
        #expect(FoundationModelsProvider.readableError(CancellationError()) is CancellationError)
        guard case .summaryTruncated? = FoundationModelsProvider.readableError(AppError.summaryTruncated) as? AppError else {
            Issue.record("expected the AppError unchanged")
            return
        }
    }

    @Test func aContextOverflowLetsChatFallBackToRetrieval() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let overflow = LanguageModelError.contextSizeExceeded(.init(contextSize: 4_096, tokenCount: 9_000, debugDescription: "too long"))
        let mapped = try #require(FoundationModelsProvider.readableError(overflow) as? AppError)
        #expect(mapped.isContextOverflow)
    }

    @Test func appleOnDeviceIsUsableMatchesOnDeviceModelAvailability() {
        #expect(AIProvider.appleOnDevice.isUsable == (OnDeviceModelAvailability.unavailableReason == nil))
    }
}
