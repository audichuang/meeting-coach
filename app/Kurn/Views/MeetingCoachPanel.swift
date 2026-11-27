//
//  MeetingCoachPanel.swift
//  Kurn
//
//  The meeting coach while recording: status and spend, the one suggestion
//  card on screen, "what should I say" / wrap-up, and the scrolling live
//  transcript with its untranscribed gaps. All state lives in
//  `MeetingCoachSession`; this view only renders and forwards taps.
//

import KurnCore
import SwiftUI

struct MeetingCoachPanel: View {
    let coach: MeetingCoachSession
    /// The in-progress (not yet final) text from the live transcriber.
    let partialText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let card = coach.currentCard {
                MeetingCoachCardView(coach: coach, card: card)
                    .id(card.candidate.id)
                    .transition(.opacity)
            }
            transcript
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .kurnAnimation(.easeOut(duration: 0.25), value: coach.currentCardID)
        .alert(
            String(format: NSLocalizedString("coach.budget.title", comment: "Spend warning title with amount"), coach.budget.nextWarningAt),
            isPresented: Binding(get: { coach.isBudgetWarning }, set: { _ in })
        ) {
            Button(NSLocalizedString("coach.budget.continue", comment: "Keep the AI running")) {
                coach.continueAfterBudgetWarning()
            }
        } message: {
            Text(NSLocalizedString("coach.budget.message", comment: "AI stops in 5 minutes unless continued; recording continues"))
        }
        .sheet(isPresented: Binding(get: { coach.wrapUp != nil }, set: { if !$0 { coach.dismissWrapUp() } })) {
            if let wrapUp = coach.wrapUp { WrapUpSheet(wrapUp: wrapUp) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(statusText, systemImage: statusIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(statusColor)
            Text(String(format: "US$%.2f", coach.cost.totalUSD))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel(String(format: NSLocalizedString("coach.cost.accessibility", comment: "Spend so far"), coach.cost.totalUSD))
            Spacer()
            Button {
                Task { await coach.askForCard() }
            } label: {
                Label(NSLocalizedString("coach.ask", comment: "What should I say"), systemImage: "lightbulb")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(coach.isAsking || coach.isAIStopped || !coach.transcriptAvailable)
            Button {
                Task { await coach.requestWrapUp() }
            } label: {
                Label(NSLocalizedString("coach.wrapup", comment: "Wrap up"), systemImage: "text.badge.checkmark")
            }
            .buttonStyle(.glass)
            .disabled(coach.isWrappingUp || coach.isAIStopped || !coach.transcriptAvailable)
        }
        .overlay(alignment: .bottomTrailing) {
            if coach.isAsking || coach.isWrappingUp {
                ProgressView().tint(.white).offset(y: 24)
            }
        }
    }

    private var statusText: String {
        switch coach.stopReason {
        case .budget: return NSLocalizedString("coach.status.stopped", comment: "AI stopped (budget)")
        case .quota: return NSLocalizedString("coach.status.quota", comment: "AI stopped: this month's allowance is used up")
        case .unauthorized: return NSLocalizedString("coach.status.unauthorized", comment: "AI stopped: invite code rejected")
        case nil: break
        }
        switch coach.connection {
        case .live: return NSLocalizedString("coach.status.live", comment: "Live")
        case .connecting: return NSLocalizedString("coach.status.connecting", comment: "Connecting")
        case .reconnecting: return NSLocalizedString("coach.status.paused", comment: "Transcript paused, reconnecting")
        case .stopped: return NSLocalizedString("coach.status.ended", comment: "Ended")
        }
    }

    private var statusIcon: String {
        coach.isAIStopped || coach.connection == .reconnecting ? "pause.circle.fill" : "waveform"
    }

    private var statusColor: Color {
        coach.isAIStopped || coach.connection == .reconnecting ? Theme.warning : .green
    }

    private enum Row: Identifiable {
        case segment(LiveTranscriptSegment)
        case gap(LiveTranscriptGap)
        var id: String {
            switch self {
            case .segment(let s): return "s\(s.start)"
            case .gap(let g): return "g\(g.start)"
            }
        }
        var start: TimeInterval {
            switch self {
            case .segment(let s): return s.start
            case .gap(let g): return g.start
            }
        }
    }

    private var rows: [Row] {
        (coach.segments.map(Row.segment) + coach.gaps.map(Row.gap)).sorted { $0.start < $1.start }
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                // Not lazy: a LazyVStack left a stale text line on screen after the card above it was swiped away.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        switch row {
                        case .segment(let segment):
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(segment.start.clockDisplay)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.45))
                                Text(segment.text)
                                    .font(Theme.body)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .gap(let gap):
                            Label(
                                String(format: NSLocalizedString("coach.gap", comment: "Untranscribed span"), gap.start.clockDisplay, gap.end.clockDisplay),
                                systemImage: "wifi.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                        }
                    }
                    if !partialText.isEmpty {
                        Text(ChineseText.traditional(partialText))
                            .font(Theme.body)
                            .foregroundStyle(.white.opacity(0.5))
                    } else if coach.segments.isEmpty {
                        Text(NSLocalizedString("recorder.live_listening", comment: "Listening…"))
                            .font(Theme.body)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: coach.segments.count) { reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: partialText) { reader.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct MeetingCoachCardView: View {
    let coach: MeetingCoachSession
    let card: CoachLedgerRecord
    @State private var expanded = false
    @State private var offset: CGFloat = 0
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.candidate.shortText)
                .accessibilityIdentifier("coach.card.text")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                Text(card.candidate.reason)
                    .font(Theme.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                ForEach(Array(card.candidate.evidence.enumerated()), id: \.offset) { _, evidence in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(evidence.start.clockDisplay)–\(evidence.end.clockDisplay)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.warning)
                        Text(evidence.context)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(4)
                    }
                }
                HStack(spacing: 12) {
                    feedbackButton(useful: true)
                    feedbackButton(useful: false)
                }
            }
        }
        .padding(14)
        .background(Theme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
        .offset(x: offset)
        .opacity(1 - min(0.6, abs(offset) / 300))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !expanded else { return }
            expanded = true
            coach.expandCurrentCard()
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { offset = $0.translation.width }
                .onEnded { value in
                    if abs(value.translation.width) > 120 {
                        coach.dismissCurrentCard()
                    } else {
                        offset = 0
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(NSLocalizedString("coach.card.hint", comment: "Tap to expand, swipe to dismiss"))
        .accessibilityAction(named: NSLocalizedString("coach.card.dismiss", comment: "Dismiss card")) {
            coach.dismissCurrentCard()
        }
    }

    private func feedbackButton(useful: Bool) -> some View {
        let value = useful ? "useful" : "inaccurate"
        return Button {
            feedback = value
            coach.feedbackOnCurrentCard(useful: useful)
        } label: {
            Label(
                useful ? NSLocalizedString("coach.card.useful", comment: "Useful") : NSLocalizedString("coach.card.inaccurate", comment: "Inaccurate"),
                systemImage: useful ? "hand.thumbsup" : "hand.thumbsdown"
            )
        }
        .buttonStyle(.glass)
        .disabled(feedback != nil)
        .opacity(feedback == nil || feedback == value ? 1 : 0.4)
    }
}

private struct WrapUpSheet: View {
    let wrapUp: CoachWrapUpArguments
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(wrapUp.spokenText)
                    .font(.title3)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(NSLocalizedString("coach.wrapup", comment: "Wrap up"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }
}
