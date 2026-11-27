//
//  MeetingCoachPanel.swift
//  Kurn
//
//  The meeting coach while recording: status and spend, the one suggestion
//  card on screen, "what should I say" / wrap-up, and the scrolling live
//  transcript with its untranscribed gaps. All state lives in
//  `MeetingCoachSession`; this view only renders and forwards taps.
//
//  Supports both the landscape side-column / legacy dark panel and the
//  portrait single-line collapsed bar (`MeetingCoachPortraitDock`) that expands
//  on tap without occupying writing space while collapsed.
//

import KurnCore
import SwiftUI

enum MeetingCoachPanelStyle {
    /// Legacy dark-only recorder panel.
    case dark
    /// Adaptive opaque surface for the paper recording screen (sidebar or drawer).
    case adaptive
}

struct MeetingCoachPanel: View {
    let coach: MeetingCoachSession
    /// The in-progress (not yet final) text from the live transcriber.
    let partialText: String
    var style: MeetingCoachPanelStyle = .dark
    /// Set to `false` when an outer host (like `MeetingCoachPortraitDock`)
    /// attaches the budget alert and wrap-up sheet so they still present while
    /// the panel itself is collapsed.
    var embedsModals: Bool = true
    /// Optional collapse button shown in the adaptive header (used when
    /// expanded from the portrait dock).
    var onCollapse: (() -> Void)?

    private var primaryText: Color { style == .dark ? .white : Theme.textPrimary }
    private var secondaryText: Color { style == .dark ? .white.opacity(0.7) : Theme.textSecondary }
    private var mutedText: Color { style == .dark ? .white.opacity(0.45) : Theme.textTertiary }
    private var bodyText: Color { style == .dark ? .white.opacity(0.9) : Theme.textPrimary }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            header
            if let card = coach.currentCard {
                MeetingCoachCardView(coach: coach, card: card, style: style)
                    .id(card.candidate.id)
                    .transition(.opacity)
            }
            transcript
        }
        .padding(14)
        .background(panelBackground)
        .kurnAnimation(.easeOut(duration: 0.25), value: coach.currentCardID)

        if embedsModals {
            content.meetingCoachModals(coach: coach)
        } else {
            content
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        if style == .dark {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.06))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 0.75)
                )
        }
    }

    @ViewBuilder
    private var header: some View {
        if style == .adaptive {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statusLabel
                    Spacer(minLength: 6)
                    costText
                    if let onCollapse {
                        Button(action: onCollapse) {
                            Image(systemName: "chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityHidden(true)
                                .frame(width: 30, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("coach.portrait.collapse", comment: "Collapse meeting coach"))
                        .accessibilityIdentifier("coach.portrait.collapse")
                    }
                }
                HStack(spacing: 8) {
                    askButton
                    wrapUpButton
                    if coach.isAsking || coach.isWrappingUp {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                statusLabel
                costText
                Spacer()
                askButton
                wrapUpButton
            }
            .overlay(alignment: .bottomTrailing) {
                if coach.isAsking || coach.isWrappingUp {
                    ProgressView().tint(.white).offset(y: 24)
                }
            }
        }
    }

    private var statusLabel: some View {
        let presentation = MeetingCoachStatusPresentation(coach: coach)
        return Label(presentation.text, systemImage: presentation.icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(presentation.tone.color)
            .lineLimit(1)
    }

    private var costText: some View {
        Text(String(format: "US$%.2f", coach.cost.totalUSD))
            .font(.footnote.monospacedDigit())
            .foregroundStyle(secondaryText)
            .accessibilityLabel(String(format: NSLocalizedString("coach.cost.accessibility", comment: "Spend so far"), coach.cost.totalUSD))
    }

    private var askButton: some View {
        Button {
            Task { await coach.askForCard() }
        } label: {
            Label(NSLocalizedString("coach.ask", comment: "What should I say"), systemImage: "lightbulb")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .disabled(coach.isAsking || coach.isAIStopped || !coach.transcriptAvailable)
    }

    private var wrapUpButton: some View {
        Button {
            Task { await coach.requestWrapUp() }
        } label: {
            Label(NSLocalizedString("coach.wrapup", comment: "Wrap up"), systemImage: "text.badge.checkmark")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .disabled(coach.isWrappingUp || coach.isAIStopped || !coach.transcriptAvailable)
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
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(segment.start.clockDisplay)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(mutedText)
                                Text(segment.text)
                                    .font(Theme.subheadline)
                                    .foregroundStyle(bodyText)
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
                            .font(Theme.subheadline)
                            .foregroundStyle(secondaryText)
                    } else if coach.segments.isEmpty {
                        Text(NSLocalizedString("recorder.live_listening", comment: "Listening…"))
                            .font(Theme.subheadline)
                            .foregroundStyle(mutedText)
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

/// Portrait-mode coach host: collapses to a single-line Liquid Glass bar at the
/// bottom edge (showing the active card headline or live status) and expands
/// into an opaque drawer on tap without disturbing the paper or recording.
struct MeetingCoachPortraitDock: View {
    let coach: MeetingCoachSession
    let partialText: String
    @Binding var isExpanded: Bool
    let maxExpandedHeight: CGFloat

    private var bar: MeetingCoachCollapsedBarPresentation {
        MeetingCoachCollapsedBarPresentation(coach: coach, partialText: partialText)
    }

    var body: some View {
        Group {
            if isExpanded {
                MeetingCoachPanel(
                    coach: coach,
                    partialText: partialText,
                    style: .adaptive,
                    embedsModals: false,
                    onCollapse: {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
                    }
                )
                .frame(maxHeight: max(220, maxExpandedHeight))
                .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("coach.portrait.drawer")
            } else {
                collapsedBar
            }
        }
        .meetingCoachModals(coach: coach)
    }

    private var collapsedBar: some View {
        let presentation = bar
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: presentation.icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(presentation.tone.color)
                    .accessibilityHidden(true)

                if presentation.showsCard {
                    Text(presentation.text)
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("coach.card.text")
                } else {
                    Text(presentation.text)
                        .font(presentation.tone == .warning ? Theme.subheadlineEmphasized : Theme.subheadline)
                        .foregroundStyle(presentation.tone == .warning ? Theme.warning : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("coach.status.text")
                }

                Spacer(minLength: 8)

                Text(String(format: "US$%.2f", coach.cost.totalUSD))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)

                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(NSLocalizedString("coach.portrait.expand", comment: "Expand meeting coach"))
        .accessibilityIdentifier("coach.portrait.bar")
    }
}

private extension MeetingCoachStatusTone {
    var color: Color {
        switch self {
        case .active: return Theme.success
        case .accent: return Theme.accent
        case .warning: return Theme.warning
        }
    }
}

private extension View {
    func meetingCoachModals(coach: MeetingCoachSession) -> some View {
        self
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
}

private struct MeetingCoachCardView: View {
    let coach: MeetingCoachSession
    let card: CoachLedgerRecord
    let style: MeetingCoachPanelStyle
    @State private var expanded = false
    @State private var offset: CGFloat = 0
    @State private var feedback: String?

    private var titleColor: Color { style == .dark ? .white : Theme.textPrimary }
    private var reasonColor: Color { style == .dark ? .white.opacity(0.8) : Theme.textSecondary }
    private var evidenceColor: Color { style == .dark ? .white.opacity(0.65) : Theme.textSecondary }
    private var cardFill: Color {
        style == .dark ? Theme.accent.opacity(0.22) : Theme.accent.opacity(0.11)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.candidate.shortText)
                .accessibilityIdentifier("coach.card.text")
                .font(.headline)
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                Text(card.candidate.reason)
                    .font(Theme.subheadline)
                    .foregroundStyle(reasonColor)
                ForEach(Array(card.candidate.evidence.enumerated()), id: \.offset) { _, evidence in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(evidence.start.clockDisplay)–\(evidence.end.clockDisplay)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.warning)
                        Text(evidence.context)
                            .font(.caption)
                            .foregroundStyle(evidenceColor)
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
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent.opacity(style == .dark ? 0.25 : 0.22), lineWidth: 1)
        )
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
