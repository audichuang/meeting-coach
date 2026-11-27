//
//  PaperNotePreview.swift
//  Kurn
//
//  Bounded thumbnail sizing and decode-once caches for read-only paper note
//  previews and viewers. Ensures SwiftUI body passes never re-decode
//  `PKDrawing` bytes or allocate unbounded bitmaps for long notes.
//

import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// Computes bounded thumbnail rects and scales so preview cards never allocate
/// full-resolution or full-height page bitmaps regardless of note length.
enum PaperNoteThumbnail {
    /// Logical size of the preview card in `MeetingDetailView`.
    static let cardSize = CGSize(width: 170, height: 220)
    /// Upper bound on either pixel dimension of a rendered preview thumbnail.
    static let maxPixelDimension: CGFloat = 512

    struct RenderSpec: Equatable {
        let rect: CGRect
        let scale: CGFloat

        var pixelWidth: CGFloat { rect.width * scale }
        var pixelHeight: CGFloat { rect.height * scale }
    }

    static func renderSpec(
        pageWidth: CGFloat,
        drawingBounds: CGRect,
        targetSize: CGSize = cardSize,
        displayScale: CGFloat
    ) -> RenderSpec {
        let safePageWidth = max(200, pageWidth)
        let drawingMaxY = drawingBounds.isNull ? 0 : drawingBounds.maxY
        let pageHeight = max(PaperCanvasMetrics.minimumPageHeight, drawingMaxY + 120)
        let rectHeight = min(pageHeight, safePageWidth * 1.5)
        let rect = CGRect(x: 0, y: 0, width: safePageWidth, height: rectHeight)

        let clampedDisplayScale = max(1, min(3, displayScale))
        let maxPixelWidth = min(maxPixelDimension, max(1, targetSize.width) * clampedDisplayScale)
        let maxPixelHeight = min(maxPixelDimension, max(1, targetSize.height) * clampedDisplayScale)
        let fitScale = min(clampedDisplayScale, maxPixelWidth / rect.width, maxPixelHeight / rect.height)
        return RenderSpec(rect: rect, scale: max(0.1, fitScale))
    }

    @MainActor
    static func renderImage(
        drawing: PKDrawing,
        pageWidth: CGFloat,
        targetSize: CGSize = cardSize,
        displayScale: CGFloat,
        render: @MainActor (PKDrawing, CGRect, CGFloat) -> UIImage = defaultRender
    ) -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let spec = renderSpec(
            pageWidth: pageWidth,
            drawingBounds: drawing.bounds,
            targetSize: targetSize,
            displayScale: displayScale
        )
        return render(drawing, spec.rect, spec.scale)
    }

    @MainActor
    static func defaultRender(drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        var rendered = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = drawing.image(from: rect, scale: scale)
        }
        return rendered
    }
}

/// Caches the decoded `PKDrawing` for a `PaperNote` revision so repeated
/// SwiftUI `body` evaluations never re-decode `drawingData`.
@MainActor
final class PaperNoteDrawingCache {
    private struct Key: Equatable {
        let noteID: UUID
        let updatedAt: Date
        let byteCount: Int
    }

    private var cachedKey: Key?
    private var cachedDrawing = PKDrawing()

    func drawing(
        for note: PaperNote,
        decode: (PaperNote) -> PKDrawing = { $0.loadDrawing() }
    ) -> PKDrawing {
        let key = Key(noteID: note.id, updatedAt: note.updatedAt, byteCount: note.drawingData.count)
        if cachedKey == key {
            return cachedDrawing
        }
        let decoded = decode(note)
        cachedKey = key
        cachedDrawing = decoded
        return decoded
    }
}

/// Caches one bounded preview `UIImage` for a `PaperNote` revision and display
/// scale so `PaperNotePreviewCard` decodes and renders once per revision.
@MainActor
final class PaperNoteThumbnailCache {
    private struct Key: Equatable {
        let noteID: UUID
        let updatedAt: Date
        let byteCount: Int
        let scaleBucket: Int
    }

    private var cachedKey: Key?
    private var cachedImage: UIImage?

    func image(
        for note: PaperNote,
        displayScale: CGFloat,
        decode: (PaperNote) -> PKDrawing = { $0.loadDrawing() },
        render: @MainActor (PKDrawing, CGRect, CGFloat) -> UIImage = PaperNoteThumbnail.defaultRender
    ) -> UIImage? {
        let key = Key(
            noteID: note.id,
            updatedAt: note.updatedAt,
            byteCount: note.drawingData.count,
            scaleBucket: Int((displayScale * 100).rounded())
        )
        if cachedKey == key {
            return cachedImage
        }
        let drawing = decode(note)
        let rendered = PaperNoteThumbnail.renderImage(
            drawing: drawing,
            pageWidth: CGFloat(note.pageWidth),
            displayScale: displayScale,
            render: render
        )
        cachedKey = key
        cachedImage = rendered
        return rendered
    }
}
