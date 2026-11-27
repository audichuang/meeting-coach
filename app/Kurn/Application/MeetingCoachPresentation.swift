//
//  MeetingCoachPresentation.swift
//  Kurn
//
//  Pure presentation state for the meeting coach's expanded status header and
//  portrait collapsed bar. Lives in `Application/` (beside `MeetingCoachSession`)
//  so both views share one source of truth for status wording and priority.
//

import Foundation
import KurnCore

enum MeetingCoachStatusTone: Equatable, Sendable {
    case active
    case accent
    case warning
}

struct MeetingCoachStatusPresentation: Equatable, Sendable {
    let text: String
    let icon: String
    let tone: MeetingCoachStatusTone
    let prioritizesStatus: Bool

    init(stopReason: MeetingCoachSession.StopReason?, connection: LiveConnectionState) {
        if let stopReason {
            switch stopReason {
            case .budget:
                text = NSLocalizedString("coach.status.stopped", comment: "AI stopped (budget)")
            case .quota:
                text = NSLocalizedString("coach.status.quota", comment: "AI stopped: this month's allowance is used up")
            case .unauthorized:
                text = NSLocalizedString("coach.status.unauthorized", comment: "AI stopped: invite code rejected")
            case .accessMissing:
                text = NSLocalizedString("coach.status.accessMissing", comment: "AI stopped: the build lacks the Worker address or Access token")
            }
        } else {
            switch connection {
            case .live:
                text = NSLocalizedString("coach.status.live", comment: "Live")
            case .connecting:
                text = NSLocalizedString("coach.status.connecting", comment: "Connecting")
            case .reconnecting:
                text = NSLocalizedString("coach.status.paused", comment: "Transcript paused, reconnecting")
            case .stopped:
                text = NSLocalizedString("coach.status.ended", comment: "Ended")
            }
        }
        let degraded = stopReason != nil || connection == .reconnecting || connection == .stopped
        prioritizesStatus = degraded
        icon = degraded ? "pause.circle.fill" : "waveform"
        tone = degraded ? .warning : .active
    }

    @MainActor
    init(coach: MeetingCoachSession) {
        self.init(stopReason: coach.stopReason, connection: coach.connection)
    }
}

struct MeetingCoachCollapsedBarPresentation: Equatable, Sendable {
    let text: String
    let icon: String
    let tone: MeetingCoachStatusTone
    let showsCard: Bool
    let accessibilityLabel: String

    @MainActor
    init(coach: MeetingCoachSession, partialText: String) {
        self.init(
            status: MeetingCoachStatusPresentation(coach: coach),
            cardText: coach.currentCard?.candidate.shortText,
            latestSegmentText: coach.segments.last?.text,
            partialText: partialText
        )
    }

    init(
        status: MeetingCoachStatusPresentation,
        cardText: String?,
        latestSegmentText: String?,
        partialText: String
    ) {
        if status.prioritizesStatus {
            text = status.text
            icon = status.icon
            tone = .warning
            showsCard = false
            accessibilityLabel = status.text
        } else if let cardText, !cardText.isEmpty {
            text = cardText
            icon = "lightbulb.fill"
            tone = .accent
            showsCard = true
            accessibilityLabel = "\(status.text): \(cardText)"
        } else {
            let summary: String
            if let latestSegmentText, !latestSegmentText.isEmpty {
                summary = "\(status.text) · \(latestSegmentText)"
            } else if !partialText.isEmpty {
                summary = "\(status.text) · \(ChineseText.traditional(partialText))"
            } else {
                summary = status.text
            }
            text = summary
            icon = status.icon
            tone = status.tone
            showsCard = false
            accessibilityLabel = summary
        }
    }
}
