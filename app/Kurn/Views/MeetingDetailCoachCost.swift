//
//  MeetingDetailCoachCost.swift
//  Kurn
//
//  The meeting coach's estimated spend for one meeting, in the detail header:
//  one line with the total that expands to the per-step breakdown. Meetings
//  whose spend predates per-step tracking show the total only.
//

import KurnCore
import SwiftUI

struct MeetingDetailCoachCost: View {
    let totalUSD: Double
    let breakdown: CoachCostBreakdown?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if breakdown == nil {
                totalLine
            } else {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        totalLine
                        Image(systemName: "chevron.down")
                            .font(Theme.caption2Emphasized)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    // A taller hit area than the footnote line, without growing the header.
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -14)
                .accessibilityValue(NSLocalizedString(isExpanded ? "detail.coach_cost.expanded" : "detail.coach_cost.collapsed",
                                                      comment: "Whether the cost breakdown is shown"))
                .accessibilityIdentifier("detail.coachCost")
            }
            if isExpanded, let breakdown {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    ForEach(CoachCostStep.allCases, id: \.self) { step in
                        GridRow {
                            Text(Self.title(step))
                            Text(breakdown[step] > 0 ? Self.usd(breakdown[step]) : "—")
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }
        }
        .font(Theme.footnote)
        .foregroundStyle(Theme.textSecondary)
    }

    private var totalLine: some View {
        Text(String(format: NSLocalizedString("detail.coach_cost.total", comment: "Estimated AI spend for this meeting"),
                    Self.usd(totalUSD)))
    }

    /// Two decimals, except that a step which cost under a cent does not read as free.
    static func usd(_ value: Double) -> String {
        value > 0 && value < 0.005 ? "<US$0.01" : String(format: "US$%.2f", value)
    }

    private static func title(_ step: CoachCostStep) -> String {
        switch step {
        case .liveTranscript: NSLocalizedString("detail.coach_cost.live_transcript", comment: "Cost step: live transcript")
        case .cards: NSLocalizedString("detail.coach_cost.cards", comment: "Cost step: suggestion cards")
        case .wrapUp: NSLocalizedString("detail.coach_cost.wrap_up", comment: "Cost step: wrap-up")
        case .formalTranscript: NSLocalizedString("detail.coach_cost.formal_transcript", comment: "Cost step: post-meeting transcript")
        case .summary: NSLocalizedString("detail.coach_cost.summary", comment: "Cost step: post-meeting summary")
        case .chat: NSLocalizedString("detail.coach_cost.chat", comment: "Cost step: questions asked in the meeting chat")
        }
    }
}
