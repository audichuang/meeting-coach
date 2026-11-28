//
//  MeetingChatStoreTests.swift
//  KurnTests
//
//  The chat conversation outlives its view: `MeetingChatStore` (built by
//  `AppComposition`) keeps one view model per meeting, so a question in
//  flight finishes while the user is elsewhere. Only stop, deleting the
//  meeting, or iOS reclaiming the background window ends it early.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Holds every chat call until `release()`, recording whether it saw cancellation.
private final class GatedLLM: LLMProvider, @unchecked Sendable {
    let provider: AIProvider = .openAI
    private let lock = NSLock()
    private var released = false
    private var _calls = 0
    private var _sawCancellation = false
    var calls: Int { lock.withLock { _calls } }
    var sawCancellation: Bool { lock.withLock { _sawCancellation } }

    func release() { lock.withLock { released = true } }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        throw AppError.transcriptionFailed("not scripted")
    }

    func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
        lock.withLock { _calls += 1 }
        while !lock.withLock({ released }) {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                lock.withLock { _sawCancellation = true }
                throw error
            }
        }
        return "We ship on Monday [00:42]."
    }
}

@MainActor
struct MeetingChatStoreTests {

    private static func store(_ llm: LLMProvider, context: ModelContext) -> MeetingChatStore {
        MeetingChatStore(modelContext: context) { _ in
            MeetingChatService(resolveProvider: { _, _ in llm })
        }
    }

    private static func ask(_ vm: MeetingChatViewModel, _ question: String = "When do we ship?") {
        vm.send(
            question: question, transcriptText: "[00:42] Ana: we ship on monday", candidates: [],
            provider: .openAI, model: "gpt-4o"
        )
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aQuestionKeepsRunningAfterTheChatIsLeftAndIsThereOnReturn() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        let llm = GatedLLM()
        let store = Self.store(llm, context: context)

        // The view asks, then goes away; nothing but the store holds the model.
        do {
            Self.ask(store.viewModel(for: meeting))
        }
        await Self.waitUntil { llm.calls > 0 }
        llm.release()

        let returned = store.viewModel(for: meeting)
        await Self.waitUntil { !returned.isResponding }
        #expect(!llm.sawCancellation)
        #expect(returned.turns.map(\.text) == ["When do we ship?", "We ship on Monday [00:42]."])
        #expect(returned.currentSessionID != nil)
    }

    @Test func eachMeetingAndTheLibraryHaveTheirOwnConversation() {
        let context = ModelContext(TestModelContainer.make())
        let first = Meeting(title: "A")
        let second = Meeting(title: "B")
        context.insert(first)
        context.insert(second)
        let store = Self.store(GatedLLM(), context: context)

        #expect(store.viewModel(for: first) === store.viewModel(for: first))
        #expect(store.viewModel(for: first) !== store.viewModel(for: second))
        #expect(store.viewModel(for: nil) === store.viewModel(for: nil))
        #expect(store.viewModel(for: nil) !== store.viewModel(for: first))
    }

    @Test func stopCancelsTheQuestionAndALateReplyIsDropped() async {
        let context = ModelContext(TestModelContainer.make())
        let llm = GatedLLM()
        let vm = Self.store(llm, context: context).viewModel(for: nil)

        Self.ask(vm)
        await Self.waitUntil { llm.calls > 0 }
        vm.cancel()
        #expect(!vm.isResponding)
        #expect(vm.retryableQuestion == "When do we ship?")
        await Self.waitUntil { llm.sawCancellation }
        #expect(llm.sawCancellation)
        #expect(vm.turns.map(\.role) == [.user])
        #expect(vm.failureMessage == nil)
    }

    @Test func aCancelledRunCannotTouchTheQuestionAskedAfterIt() async {
        let context = ModelContext(TestModelContainer.make())
        let llm = GatedLLM()
        let vm = Self.store(llm, context: context).viewModel(for: nil)

        Self.ask(vm, "First?")
        await Self.waitUntil { llm.calls == 1 }
        vm.dropRetryableQuestion() // no-op while responding
        vm.cancel()
        vm.dropRetryableQuestion()
        Self.ask(vm, "Second?")
        await Self.waitUntil { llm.calls == 2 && llm.sawCancellation }
        // Give the first run's unwinding time to (wrongly) clear the second's state.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.isResponding)
        llm.release()
        await Self.waitUntil { !vm.isResponding }

        #expect(vm.turns.map(\.text) == ["Second?", "We ship on Monday [00:42]."])
    }

    @Test func deletingTheMeetingCancelsItsChatAndForgetsIt() async {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        let llm = GatedLLM()
        let store = Self.store(llm, context: context)
        let vm = store.viewModel(for: meeting)

        Self.ask(vm)
        await Self.waitUntil { llm.calls > 0 }
        store.discard(meetingIDs: [meeting.id])

        #expect(!vm.isResponding)
        await Self.waitUntil { llm.sawCancellation }
        #expect(llm.sawCancellation)
        #expect(store.viewModel(for: meeting) !== vm)
    }

    @Test func anExpiredBackgroundWindowEndsTheTurnAsInterrupted() async {
        let context = ModelContext(TestModelContainer.make())
        let llm = GatedLLM()
        let vm = Self.store(llm, context: context).viewModel(for: nil)

        Self.ask(vm)
        await Self.waitUntil { llm.calls > 0 }
        vm.interrupt()

        #expect(!vm.isResponding)
        #expect(vm.retryableQuestion == "When do we ship?")
        #expect(vm.failureMessage == NSLocalizedString("chat.interrupted", comment: ""))
        #expect(vm.error == nil)

        vm.dropRetryableQuestion()
        #expect(vm.failureMessage == nil)
    }

    @Test func deletingAMeetingThroughTheLibraryDiscardsItsChat() throws {
        let container = TestModelContainer.make()
        let defaults = try #require(UserDefaults(suiteName: "MeetingChatStoreTests-\(UUID().uuidString)"))
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
        let environment = AppComposition.makeEnvironment(container: container, settings: settings)
        let meeting = Meeting(title: "Planning")
        container.mainContext.insert(meeting)
        try container.mainContext.save()
        let before = environment.meetingChats.viewModel(for: meeting)

        try environment.meetingLibrary.deleteMeeting(meeting)

        #expect(environment.meetingChats.viewModel(for: meeting) !== before)
    }
}
