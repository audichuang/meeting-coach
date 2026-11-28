//
//  MeetingChatStore.swift
//  Kurn
//
//  App-lifetime owner of the chat conversations, one per meeting plus one
//  library-wide (`nil`). Built by `AppComposition`: a question keeps running
//  while the user leaves the Chat tab or the meeting and is there, in
//  progress or answered, on return. Only the stop button or deleting the
//  meeting (`discard`) cancels it.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class MeetingChatStore {
    // Ignored: `viewModel(for:)` inserts while a view body reads it.
    @ObservationIgnored private var models: [UUID?: MeetingChatViewModel] = [:]
    private let modelContext: ModelContext
    private let makeService: @MainActor (_ meetingID: UUID?) -> MeetingChatService

    /// `makeService` defaults to the live stack with coach spend added to the
    /// meeting's newest `CoachRecord`; tests pass a scripted one.
    init(
        modelContext: ModelContext,
        makeService: (@MainActor (_ meetingID: UUID?) -> MeetingChatService)? = nil
    ) {
        self.modelContext = modelContext
        self.makeService = makeService ?? { meetingID in
            MeetingChatService(resolveProvider: ChatRoute.resolver { usd in
                Self.recordSpend(usd, meetingID: meetingID, in: modelContext)
            })
        }
    }

    func viewModel(for meeting: Meeting?) -> MeetingChatViewModel {
        if let existing = models[meeting?.id] { return existing }
        let created = MeetingChatViewModel(
            chatService: makeService(meeting?.id), meeting: meeting, modelContext: modelContext
        )
        models[meeting?.id] = created
        return created
    }

    /// Cancels and forgets the deleted meetings' conversations (each holds its `Meeting`).
    func discard(meetingIDs: Set<UUID>) {
        for id in meetingIDs {
            models.removeValue(forKey: id)?.cancel()
        }
    }

    /// Before erasing the whole library.
    func discardAll() {
        models.values.forEach { $0.cancel() }
        models.removeAll()
    }

    /// shortcut: library-wide chat and meetings without a `CoachRecord` are not
    /// counted anywhere; give spend its own per-meeting home to count those.
    private static func recordSpend(_ usd: Double, meetingID: UUID?, in context: ModelContext) {
        guard let meetingID else { return }
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        guard let meeting = try? context.fetch(descriptor).first,
              let record = meeting.coachRecords.max(by: { $0.createdAt < $1.createdAt }) else { return }
        MeetingCoachFollowUp.addSpend(usd, to: .chat, recordID: record.id, in: context)
    }
}
