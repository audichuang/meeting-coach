//
//  PaperCanvasMetrics.swift
//  Kurn
//
//  Pure page-coordinate and adaptive-layout calculations for the paper
//  recording screen. Rotation only changes the display scale returned here,
//  never the underlying `PKDrawing` page coordinates.
//

import CoreGraphics
import Foundation

enum PaperCanvasMetrics {
    /// Fixed logical page width in points (matches iPad mini portrait width).
    static let defaultPageWidth: CGFloat = CGFloat(PaperNote.defaultPageWidth)
    /// Initial logical page height in points (matches iPad mini portrait height).
    static let minimumPageHeight: CGFloat = 1_133
    /// Extra vertical room maintained below the lowest ink stroke so the writer
    /// always has space to continue down the page.
    static let bottomGrowthMargin: CGFloat = 420
    /// Vertical distance between ruled lines in page coordinates.
    static let ruledLineSpacing: CGFloat = 36
    /// Top inset before the first ruled line in page coordinates.
    static let ruledTopMargin: CGFloat = 128

    /// Display zoom scale that fits the logical page width into `viewportWidth`.
    /// Clamped away from zero so transient zero-size layout passes stay safe.
    static func displayScale(forViewportWidth viewportWidth: CGFloat, pageWidth: CGFloat = defaultPageWidth) -> CGFloat {
        guard viewportWidth > 0, pageWidth > 0 else { return 1 }
        return max(0.25, viewportWidth / pageWidth)
    }

    /// Logical page height in page coordinates: fills at least the visible
    /// viewport height and grows past the lowest stroke with breathing room.
    static func pageHeight(viewportHeight: CGFloat, displayScale: CGFloat, drawingMaxY: CGFloat) -> CGFloat {
        let safeScale = max(0.25, displayScale)
        let visiblePageHeight = viewportHeight > 0 ? (viewportHeight / safeScale) : minimumPageHeight
        let inkNeededHeight = drawingMaxY > 0 ? (drawingMaxY + bottomGrowthMargin) : 0
        return max(minimumPageHeight, visiblePageHeight, inkNeededHeight)
    }

    /// Whether the recording screen should use the side-by-side landscape layout.
    static func isLandscape(_ containerSize: CGSize) -> Bool {
        containerSize.width > containerSize.height
    }

    /// Width of the side coach column in landscape. Sized to keep roughly 70%
    /// of the iPad mini landscape width for the paper surface.
    static func coachColumnWidth(forContainerSize containerSize: CGSize) -> CGFloat {
        guard containerSize.width > 0 else { return 300 }
        return min(340, max(280, floor(containerSize.width * 0.29)))
    }

    /// Fraction of the container area occupied by `paperFrame`.
    static func areaFraction(of paperFrame: CGRect, in containerSize: CGSize) -> CGFloat {
        let totalArea = containerSize.width * containerSize.height
        guard totalArea > 0 else { return 0 }
        let paperArea = max(0, paperFrame.width) * max(0, paperFrame.height)
        return paperArea / totalArea
    }
}
