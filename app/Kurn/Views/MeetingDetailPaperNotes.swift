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
/// Decodes and renders one bounded thumbnail per note revision rather than
/// re-decoding or allocating a full-page bitmap on every SwiftUI body pass.
private struct PaperNotePreviewCard: View {
    let note: PaperNote
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnailCache = PaperNoteThumbnailCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(uiColor: PaperCanvasContainerView.paperBackgroundColor)
                if let image = thumbnailCache.image(for: note, displayScale: displayScale) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: PaperNoteThumbnail.cardSize.width, height: PaperNoteThumbnail.cardSize.height)
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
        .frame(width: PaperNoteThumbnail.cardSize.width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Full-page read-only viewer for a saved `PaperNote`. Uses a read-only
/// `PaperCanvasView` (`PKCanvasView` with scrolling/zooming enabled and
/// drawing disabled) so arbitrarily tall notes tile natively without ever
/// allocating a full-height bitmap, and decodes the persisted drawing once.
struct PaperNoteViewerView: View {
    let note: PaperNote
    @Environment(\.dismiss) private var dismiss
    @State private var drawingCache = PaperNoteDrawingCache()

    var body: some View {
        NavigationStack {
            PaperCanvasView(
                drawing: drawingCache.drawing(for: note),
                pageWidth: max(200, CGFloat(note.pageWidth)),
                isEditable: false
            )
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
}
