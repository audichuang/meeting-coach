//
//  PaperCanvasView.swift
//  Kurn
//
//  SwiftUI wrapper over PencilKit's `PKCanvasView` with an opaque warm-paper
//  surface, ruled guide lines anchored to page coordinates, and a fixed logical
//  page width so rotating the iPad only updates the display zoom scale and
//  never alters stored stroke coordinates.
//

import PencilKit
import SwiftUI
import UIKit

/// Bridge exposing undo/redo actions from the underlying `PKCanvasView` to
/// the floating SwiftUI tool palette without breaking MVVM boundaries.
@MainActor
@Observable
final class PaperCanvasController {
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored weak var canvasView: PKCanvasView?

    func attach(_ canvasView: PKCanvasView) {
        self.canvasView = canvasView
        refreshUndoState()
    }

    func refreshUndoState() {
        canUndo = canvasView?.undoManager?.canUndo ?? false
        canRedo = canvasView?.undoManager?.canRedo ?? false
    }

    func undo() {
        canvasView?.undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        canvasView?.undoManager?.redo()
        refreshUndoState()
    }
}

/// Interactive or read-only PencilKit paper surface in fixed page coordinates.
struct PaperCanvasView: UIViewRepresentable {
    let drawing: PKDrawing
    var pageWidth: CGFloat = PaperCanvasMetrics.defaultPageWidth
    var tool: PKTool = PaperToolState().makePKTool()
    var isEditable: Bool = true
    var controller: PaperCanvasController?
    var onDrawingChange: ((PKDrawing) -> Void)?

    /// On the simulator there is no Apple Pencil, so DEBUG simulator/UI-test
    /// builds enable `.anyInput`. Release builds always stay `.default`
    /// (Pencil-first: finger scrolls/selects as PencilKit default).
    static var defaultDrawingPolicy: PKCanvasViewDrawingPolicy {
        #if DEBUG
        #if targetEnvironment(simulator)
        return .anyInput
        #else
        return ProcessInfo.processInfo.arguments.contains("UI-Testing-AllowAnyCanvasInput") ? .anyInput : .default
        #endif
        #else
        return .default
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PaperCanvasContainerView {
        let container = PaperCanvasContainerView(pageWidth: pageWidth)
        let canvas = container.canvasView
        canvas.delegate = context.coordinator
        canvas.tool = tool
        canvas.drawingPolicy = Self.defaultDrawingPolicy
        canvas.drawingGestureRecognizer.isEnabled = isEditable
        canvas.accessibilityIdentifier = isEditable ? "paper.canvas" : "paper.canvas.readonly"
        canvas.accessibilityLabel = NSLocalizedString("paper.canvas.accessibility", comment: "Handwriting paper")
        context.coordinator.applyExternalDrawing(drawing, to: container)
        controller?.attach(canvas)
        return container
    }

    func updateUIView(_ container: PaperCanvasContainerView, context: Context) {
        context.coordinator.parent = self
        container.pageWidth = pageWidth
        let canvas = container.canvasView
        canvas.drawingGestureRecognizer.isEnabled = isEditable
        if isEditable {
            canvas.tool = tool
        }
        if canvas.drawing != drawing {
            context.coordinator.applyExternalDrawing(drawing, to: container)
        }
        controller?.attach(canvas)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        var parent: PaperCanvasView
        private var isApplyingExternalDrawing = false

        init(parent: PaperCanvasView) {
            self.parent = parent
        }

        func applyExternalDrawing(_ drawing: PKDrawing, to container: PaperCanvasContainerView) {
            isApplyingExternalDrawing = true
            container.canvasView.drawing = drawing
            container.updateContentSizeForDrawing()
            isApplyingExternalDrawing = false
            parent.controller?.refreshUndoState()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing, parent.isEditable else { return }
            if let container = canvasView.superview as? PaperCanvasContainerView {
                container.updateContentSizeForDrawing()
            }
            parent.controller?.refreshUndoState()
            parent.onDrawingChange?(canvasView.drawing)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView.superview as? PaperCanvasContainerView)?.syncRuledOverlay()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView.superview as? PaperCanvasContainerView)?.syncRuledOverlay()
        }
    }
}

/// Opaque warm-paper backing + ruled guide layer + `PKCanvasView` zoomed to
/// fit the logical page width without ever mutating `PKDrawing` coordinates.
final class PaperCanvasContainerView: UIView {
    static let paperBackgroundColor = UIColor(red: 1.0, green: 0.992, blue: 0.969, alpha: 1.0)
    static let ruledLineColor = UIColor(red: 0.85, green: 0.88, blue: 0.86, alpha: 0.62)

    var pageWidth: CGFloat {
        didSet {
            guard abs(oldValue - pageWidth) > 0.5 else { return }
            lastViewportWidth = 0
            setNeedsLayout()
        }
    }

    private let ruledView = PaperRuledLinesView()
    let canvasView = PKCanvasView()
    private var lastViewportWidth: CGFloat = 0

    init(pageWidth: CGFloat) {
        self.pageWidth = pageWidth
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = Self.paperBackgroundColor
        overrideUserInterfaceStyle = .light
        clipsToBounds = true

        ruledView.isUserInteractionEnabled = false
        ruledView.backgroundColor = .clear
        addSubview(ruledView)

        // Keep ink rendering in light appearance over opaque warm paper so dark
        // mode never inverts pen strokes into invisible white-on-paper.
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        canvasView.alwaysBounceVertical = true
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = true
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.maximumZoomScale = 3.0
        addSubview(canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ruledView.frame = bounds
        canvasView.frame = bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let fitScale = PaperCanvasMetrics.displayScale(forViewportWidth: bounds.width, pageWidth: pageWidth)
        let widthChanged = abs(bounds.width - lastViewportWidth) > 0.5
        if widthChanged {
            lastViewportWidth = bounds.width
            // Update contentSize before zoomScale so PencilKit's tiled view
            // recomputes its tile grid cleanly when rotating orientations.
            updateContentSize(forScale: fitScale)
            canvasView.minimumZoomScale = fitScale
            canvasView.maximumZoomScale = max(fitScale * 3.0, 3.0)
            canvasView.setZoomScale(fitScale, animated: false)
            syncRuledOverlay()
        } else {
            updateContentSizeForDrawing()
        }
    }

    func updateContentSizeForDrawing() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        updateContentSize(forScale: max(0.25, canvasView.zoomScale))
        syncRuledOverlay()
    }

    private func updateContentSize(forScale scale: CGFloat) {
        let drawingMaxY = canvasView.drawing.bounds.isNull ? 0 : canvasView.drawing.bounds.maxY
        let logicalHeight = PaperCanvasMetrics.pageHeight(
            viewportHeight: bounds.height,
            displayScale: scale,
            drawingMaxY: drawingMaxY
        )
        let targetSize = CGSize(width: pageWidth * scale, height: logicalHeight * scale)
        if abs(canvasView.contentSize.width - targetSize.width) > 0.5
            || abs(canvasView.contentSize.height - targetSize.height) > 0.5 {
            canvasView.contentSize = targetSize
        }
    }

    func syncRuledOverlay() {
        ruledView.zoomScale = max(0.25, canvasView.zoomScale)
        ruledView.contentOffsetY = canvasView.contentOffset.y
        ruledView.setNeedsDisplay()
    }
}

/// Draws subtle horizontal notebook lines in page coordinates so they scroll
/// and scale cleanly in lockstep with `PKCanvasView`.
private final class PaperRuledLinesView: UIView {
    var zoomScale: CGFloat = 1
    var contentOffsetY: CGFloat = 0

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), zoomScale > 0 else { return }
        ctx.setStrokeColor(PaperCanvasContainerView.ruledLineColor.cgColor)
        ctx.setLineWidth(1.0 / max(1, traitCollection.displayScale))

        let spacing = PaperCanvasMetrics.ruledLineSpacing * zoomScale
        guard spacing >= 6 else { return }
        let startPageY = PaperCanvasMetrics.ruledTopMargin
        let firstVisibleY = startPageY * zoomScale - contentOffsetY
        var y = firstVisibleY
        if y < rect.minY {
            let skipped = ceil((rect.minY - y) / spacing)
            y += skipped * spacing
        }
        while y <= rect.maxY {
            ctx.move(to: CGPoint(x: rect.minX + 24, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX - 24, y: y))
            y += spacing
        }
        ctx.strokePath()
    }
}
