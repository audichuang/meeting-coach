//
//  MeetingCoachPortraitDockTests.swift
//  KurnTests
//
//  Verifies that `MeetingCoachPortraitDock`'s collapsed bar gives stopped and
//  reconnecting statuses priority over any stale suggestion card, using the
//  same status wording as the expanded `MeetingCoachPanel`.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingCoachPortraitDockTests {

    private final class CardThenRefuseLLM: CoachLLM, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let refuseStatus: Int

        init(refuseStatus: Int) {
            self.refuseStatus = refuseStatus
        }

        func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
            let index = lock.withLock { () -> Int in
                calls += 1
                return calls
            }
            if index == 1 {
                let args = #"{"short_text":"要不要先確認口徑？","reason":"數字沒對齊","evidence_start":0,"evidence_end":20,"category":"clarify"}"#
                return CoachCallResult(
                    calls: [CoachToolCall(name: "emit_suggestion", arguments: Data(args.utf8))],
                    usage: CoachTokenUsage(input: 400, cached: 0, output: 60)
                )
            }
            throw AppError.apiError(statusCode: refuseStatus, message: "refused")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: [
        (402, MeetingCoachSession.StopReason.quota, "coach.status.quota"),
        (401, MeetingCoachSession.StopReason.unauthorized, "coach.status.unauthorized")
    ])
    func collapsedBarPrioritizesStoppedCoachOverStaleCard(
        status: Int,
        expectedReason: MeetingCoachSession.StopReason,
        expectedKey: String
    ) async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach Dock")
        context.insert(meeting)

        let coach = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "測試者", budgetUSD: 10, backend: .test),
            llm: CardThenRefuseLLM(refuseStatus: status),
            elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.connection(.live))
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable && coach.connection == .live }

        await coach.askForCard()
        #expect(coach.currentCard != nil)
        let liveBar = MeetingCoachCollapsedBarPresentation(coach: coach, partialText: "")
        #expect(liveBar.showsCard)
        #expect(liveBar.text == "要不要先確認口徑？")

        // Second ask hits HTTP 402/401 -> coach stops while the previous card remains in `currentCard`.
        await coach.askForCard()
        #expect(coach.stopReason == expectedReason)
        #expect(coach.currentCard != nil)

        let expandedStatus = MeetingCoachStatusPresentation(coach: coach)
        let stoppedBar = MeetingCoachCollapsedBarPresentation(coach: coach, partialText: "")
        let expectedText = NSLocalizedString(expectedKey, comment: "")

        #expect(!stoppedBar.showsCard)
        #expect(stoppedBar.text == expandedStatus.text)
        #expect(stoppedBar.text == expectedText)
        #expect(stoppedBar.icon == expandedStatus.icon)
        #expect(stoppedBar.tone == .warning)
        #expect(stoppedBar.accessibilityLabel == expectedText)

        await coach.finish(at: 160)
    }

    @Test func collapsedBarPrioritizesBudgetStopReconnectingAndEndedOverCard() {
        let cases: [(MeetingCoachSession.StopReason?, LiveConnectionState, String)] = [
            (.budget, .live, "coach.status.stopped"),
            (.quota, .live, "coach.status.quota"),
            (.unauthorized, .live, "coach.status.unauthorized"),
            (nil, .reconnecting, "coach.status.paused"),
            (nil, .stopped, "coach.status.ended")
        ]

        for (stopReason, connection, key) in cases {
            let status = MeetingCoachStatusPresentation(stopReason: stopReason, connection: connection)
            let bar = MeetingCoachCollapsedBarPresentation(
                status: status,
                cardText: "先對齊交付範圍？",
                latestSegmentText: "上一句逐字稿",
                partialText: "進行中"
            )
            let expected = NSLocalizedString(key, comment: "")
            #expect(!bar.showsCard)
            #expect(bar.text == status.text)
            #expect(bar.text == expected)
            #expect(bar.icon == "pause.circle.fill")
            #expect(bar.tone == .warning)
            #expect(bar.accessibilityLabel == expected)
        }
    }

    @Test func collapsedBarShowsCardWhenLiveAndStatusSummaryWhenNoCard() {
        let liveStatus = MeetingCoachStatusPresentation(stopReason: nil, connection: .live)
        let withCard = MeetingCoachCollapsedBarPresentation(
            status: liveStatus,
            cardText: "先對齊交付範圍？",
            latestSegmentText: "上一句逐字稿",
            partialText: ""
        )
        #expect(withCard.showsCard)
        #expect(withCard.text == "先對齊交付範圍？")
        #expect(withCard.icon == "lightbulb.fill")
        #expect(withCard.tone == .accent)

        let withoutCard = MeetingCoachCollapsedBarPresentation(
            status: liveStatus,
            cardText: nil,
            latestSegmentText: "上一句逐字稿",
            partialText: ""
        )
        #expect(!withoutCard.showsCard)
        #expect(withoutCard.text == "\(liveStatus.text) · 上一句逐字稿")
        #expect(withoutCard.icon == "waveform")
        #expect(withoutCard.tone == .active)
    }
}
