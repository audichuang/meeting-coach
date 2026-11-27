//
//  MeetingDetailPaperNotes.swift
//  Kurn
//
//  Read-only display of handwritten paper notes in `MeetingDetailView`, plus
//  a full-page read-only viewer sheet. Mirrors `MeetingDetailPhotos.swift` so
//  saved drawings show immediately after a recording ends.
//

import PencilKit
import SwiftUI
import UIKit

extension MeetingDetailView {
    /// Non-empty handwritten note pages saved for this meeting, oldest first.
    var savedPaperNotes: [PaperNote] {
        queriedPaperNotes.filter(\.hasStrokes)
    }

    @ViewBuilder
    var paperNotesSection: some View {
        if !savedPaperNotes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
                sectionLabel(NSLocalizedString("paper.notes.section", comment: "Handwritten Notes"))
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(savedPaperNotes) { note in
                            Button {
                                presentedPaperNote = note
                            } label: {
                                PaperNotePreviewCard(note: note)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(NSLocalizedString("paper.notes.open_hint", comment: "Opens full-page handwritten notes"))
                            .accessibilityIdentifier("detail.paper.note")
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .clearListRow(insets: EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        }
    }
}

/// Compact read-only preview thumbnail of one saved handwritten notes page.
private struct PaperNotePreviewCard: View {
    let note: PaperNote
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(uiColor: PaperCanvasContainerView.paperBackgroundColor)
                if let image = renderedPreview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 170, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)

            Text(String(
                format: NSLocalizedString("paper.notes.updated", comment: "Updated timestamp"),
                note.updatedAt.formatted(date: .abbreviated, time: .shortened)
            ))
            .font(Theme.caption2)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
        .frame(width: 170, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var renderedPreview: UIImage? {
        let drawing = note.loadDrawing()
        guard !drawing.strokes.isEmpty else { return nil }
        let pageWidth = max(200, CGFloat(note.pageWidth))
        let pageHeight = max(
            PaperCanvasMetrics.minimumPageHeight,
            drawing.bounds.isNull ? 0 : drawing.bounds.maxY + 120
        )
        let rect = CGRect(x: 0, y: 0, width: pageWidth, height: min(pageHeight, pageWidth * 1.5))
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = drawing.image(from: rect, scale: max(1, min(2, displayScale)))
        }
        return rendered
    }
}

/// Full-page read-only viewer for a saved `PaperNote`. Renders the persisted
/// `PKDrawing` directly via `PKDrawing.image(from:scale:)` onto the opaque
/// warm-paper page inside a scrollable view so reviewing notes never mutates
/// them and avoids PencilKit tile-rasterization artifacts inside modal sheets.
struct PaperNoteViewerView: View {
    let note: PaperNote
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let drawing = note.loadDrawing()
                let pageWidth = max(200, CGFloat(note.pageWidth))
                let drawingMaxY = drawing.bounds.isNull ? 0 : drawing.bounds.maxY
                let pageHeight = max(
                    PaperCanvasMetrics.minimumPageHeight,
                    drawingMaxY + PaperCanvasMetrics.bottomGrowthMargin
                )
                let viewportWidth = max(1, proxy.size.width)
                let aspectHeight = viewportWidth * (pageHeight / pageWidth)

                ScrollView {
                    ZStack(alignment: .topLeading) {
                        PaperReadOnlyPageBackground(
                            pageWidth: pageWidth,
                            pageHeight: pageHeight
                        )
                        if let rendered = renderDrawing(drawing, pageWidth: pageWidth, pageHeight: pageHeight) {
                            Image(uiImage: rendered)
                                .resizable()
                                .scaledToFit()
                                .frame(width: viewportWidth, height: aspectHeight, alignment: .topLeading)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: viewportWidth, height: aspectHeight)
                }
                .background(Color(uiColor: PaperCanvasContainerView.paperBackgroundColor))
                .accessibilityIdentifier("paper.canvas.readonly")
                .accessibilityLabel(NSLocalizedString("paper.canvas.accessibility", comment: "Handwriting paper"))
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(NSLocalizedString("paper.notes.title", comment: "Notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationSizing(.page)
    }

    private func renderDrawing(_ drawing: PKDrawing, pageWidth: CGFloat, pageHeight: CGFloat) -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: max(1, min(2, displayScale)))
        }
        return image
    }
}

private struct PaperReadOnlyPageBackground: View {
    let pageWidth: CGFloat
    let pageHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let scale = size.width / max(1, pageWidth)
            let spacing = PaperCanvasMetrics.ruledLineSpacing * scale
            guard spacing >= 4 else { return }
            var y = PaperCanvasMetrics.ruledTopMargin * scale
            let lineColor = Color(uiColor: PaperCanvasContainerView.ruledLineColor)
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 24 * scale, y: y))
                path.addLine(to: CGPoint(x: size.width - 24 * scale, y: y))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.75)
                y += spacing
            }
        }
        .background(Color(uiColor: PaperCanvasContainerView.paperBackgroundColor))
        .accessibilityHidden(true)
    }
}
