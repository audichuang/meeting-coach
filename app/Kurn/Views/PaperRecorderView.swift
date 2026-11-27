//
//  PaperRecorderView.swift
//  Kurn
//
//  The "paper" recording screen (iPad and iPhone): an opaque writing surface fills
//  the screen while recording, Liquid Glass controls and the drawing tool
//  palette float above it, and the meeting coach adapts by orientation
//  (side column in landscape; collapsible single-line bar in portrait).
//

import SwiftUI

struct PaperRecorderView: View {
    @Bindable var vm: RecorderViewModel
    let session: RecordingSessionController
    @Binding var showingPhotoCapture: Bool

    @State private var toolState = PaperToolState()
    @State private var canvasController = PaperCanvasController()
    @State private var isPortraitCoachExpanded = false
    @State private var showingTitlePopover = false

    private var hasRecordingInProgress: Bool {
        vm.state != .idle || vm.isStarting
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = PaperCanvasMetrics.isLandscape(proxy.size)
            let showsLandscapeSidebar = isLandscape && vm.coach != nil
            ZStack {
                Theme.background.ignoresSafeArea()

                // Keep `paperStage` at a single stable SwiftUI identity across
                // portrait <-> landscape rotation so `PKCanvasView` and its
                // undo history are never torn down and recreated on rotate.
                HStack(spacing: showsLandscapeSidebar ? 12 : 0) {
                    paperStage
                    if showsLandscapeSidebar, let coach = vm.coach {
                        MeetingCoachPanel(
                            coach: coach,
                            partialText: vm.livePartialText,
                            style: .adaptive
                        )
                        .frame(width: PaperCanvasMetrics.coachColumnWidth(forContainerSize: proxy.size))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("coach.landscape.column")
                    }
                }
                .padding(.horizontal, showsLandscapeSidebar ? 12 : 8)
                .padding(.vertical, showsLandscapeSidebar ? 8 : 6)
                .overlay(alignment: .bottom) {
                    if !isLandscape {
                        portraitBottomOverlay(containerHeight: proxy.size.height)
                    }
                }
            }
            .onChange(of: isLandscape) { _, nowLandscape in
                if nowLandscape { isPortraitCoachExpanded = false }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder
    private func portraitBottomOverlay(containerHeight: CGFloat) -> some View {
        if let coach = vm.coach {
            MeetingCoachPortraitDock(
                coach: coach,
                partialText: vm.livePartialText,
                isExpanded: $isPortraitCoachExpanded,
                maxExpandedHeight: containerHeight * 0.44
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if vm.isLiveTranscriptionRequested, !vm.livePartialText.isEmpty {
            Text(vm.livePartialText)
                .font(Theme.footnote)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Paper stage & floating Liquid Glass chrome

    private var paperStage: some View {
        ZStack(alignment: .top) {
            PaperCanvasView(
                drawing: vm.paperNotes.drawing,
                pageWidth: CGFloat(vm.paperNotes.pageWidth),
                tool: toolState.makePKTool(),
                isEditable: true,
                controller: canvasController,
                onDrawingChange: { vm.paperNotes.drawingDidChange($0) }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)

            VStack(spacing: 8) {
                topControlBar
                // Scrolls sideways on a narrow iPhone rather than widening the screen.
                ViewThatFits(in: .horizontal) {
                    toolPalette
                    ScrollView(.horizontal, showsIndicators: false) { toolPalette }
                }
                statusBanners
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolPalette: some View {
        PaperToolPalette(
            selection: $toolState,
            canUndo: canvasController.canUndo,
            canRedo: canvasController.canRedo,
            onUndo: { canvasController.undo() },
            onRedo: { canvasController.redo() }
        )
    }

    /// One row when it fits (iPad, iPhone landscape); on a narrow iPhone the
    /// title capsule and the recording controls take a row each instead of
    /// pushing the paper off screen.
    private var topControlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                titleCapsule
                Spacer(minLength: 6)
                controlsCapsule
            }
            VStack(spacing: 8) {
                HStack { titleCapsule; Spacer(minLength: 0) }
                HStack { Spacer(minLength: 0); controlsCapsule }
            }
        }
    }

    private var titleCapsule: some View {
        HStack(spacing: 8) {
            Button(role: hasRecordingInProgress ? .destructive : .cancel) {
                session.discard()
            } label: {
                Image(systemName: hasRecordingInProgress ? "trash" : "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hasRecordingInProgress ? Theme.accent : Theme.textPrimary)
                    .accessibilityHidden(true)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                hasRecordingInProgress
                    ? NSLocalizedString("recorder.discard", comment: "Discard the in-progress recording")
                    : NSLocalizedString("common.cancel", comment: "Cancel")
            )
            .accessibilityIdentifier("recorder.discard")

            statusPill

            Button {
                showingTitlePopover = true
            } label: {
                Text(vm.meetingTitle.isEmpty
                     ? NSLocalizedString("recorder.add_title", comment: "Add title…")
                     : vm.meetingTitle)
                    .font(Theme.subheadlineEmphasized)
                    .foregroundStyle(vm.meetingTitle.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("paper.title.edit", comment: "Edit meeting title"))
            .popover(isPresented: $showingTitlePopover) {
                titleEditorPopover
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var controlsCapsule: some View {
        HStack(spacing: 6) {
            Button {
                vm.markHighlight()
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.state == .recording ? Theme.warning : Theme.textTertiary)
                    .accessibilityHidden(true)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(vm.state != .recording)
            .sensoryFeedback(.success, trigger: vm.highlightCount)
            .accessibilityLabel(NSLocalizedString("recorder.highlight", comment: "Highlight"))

            Button {
                showingPhotoCapture = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.state == .recording ? Theme.textPrimary : Theme.textTertiary)
                    .accessibilityHidden(true)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(vm.state != .recording)
            .accessibilityLabel(NSLocalizedString("recorder.photo", comment: "Photo"))

            Button {
                vm.togglePause()
            } label: {
                Image(systemName: vm.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.state == .idle ? Theme.textTertiary : Theme.textPrimary)
                    .accessibilityHidden(true)
                    .frame(width: 34, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(vm.state == .idle)
            .accessibilityLabel(
                vm.state == .paused
                    ? NSLocalizedString("recorder.resume", comment: "Resume")
                    : NSLocalizedString("recorder.pause", comment: "Pause")
            )
            .accessibilityIdentifier("recorder.pause")

            Button {
                vm.stopAndSave()
            } label: {
                Label(NSLocalizedString("recorder.stop", comment: "Stop"), systemImage: "stop.fill")
                    .font(.footnote.weight(.semibold))
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Theme.accent)
            .disabled(vm.state == .idle)
            .accessibilityLabel(NSLocalizedString("recorder.stop", comment: "Stop"))
            .accessibilityIdentifier("recorder.stop")

            Button {
                session.minimize()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.canMinimize ? Theme.textPrimary : Theme.textTertiary)
                    .accessibilityHidden(true)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!session.canMinimize)
            .accessibilityLabel(NSLocalizedString("recorder.minimize", comment: "Minimize the recorder"))
            .accessibilityIdentifier("recorder.minimize")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if vm.state == .recording {
                PulsingDot(color: Theme.accent)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(vm.state == .paused ? Theme.warning : Theme.accent)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(vm.elapsed.clockDisplay)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            if vm.highlightCount > 0 {
                Label("\(vm.highlightCount)", systemImage: "bookmark.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.warning)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recorder.timer")
    }

    @ViewBuilder
    private var statusBanners: some View {
        if vm.isStarting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("recorder.connecting", comment: "Setting up the microphone before recording starts"))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
        if let message = vm.routeMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var titleEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("paper.title.edit", comment: "Edit meeting title"))
                .font(Theme.footnoteEmphasized)
                .foregroundStyle(Theme.textSecondary)
            TextField(
                NSLocalizedString("recorder.add_title", comment: "Add title…"),
                text: $vm.meetingTitle
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240)
            .accessibilityLabel(NSLocalizedString(
                "recorder.title_field.accessibility_label",
                comment: "Meeting title text field (VoiceOver)"
            ))
            .onSubmit { showingTitlePopover = false }
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }
}
