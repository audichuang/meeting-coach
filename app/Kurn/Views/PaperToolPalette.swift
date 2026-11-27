//
//  PaperToolPalette.swift
//  Kurn
//
//  Compact floating Liquid Glass drawing palette for the paper recording
//  screen: pen, highlighter, eraser, lasso, curated opaque ink colors, and
//  undo/redo. Avoids `PKToolPicker` layout conflicts with the portrait coach
//  bar and landscape sidebar while keeping tools one tap away.
//

import PencilKit
import SwiftUI
import UIKit

enum PaperToolKind: String, CaseIterable, Identifiable {
    case pen
    case highlighter
    case eraser
    case lasso

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pen: return NSLocalizedString("paper.tool.pen", comment: "Pen tool")
        case .highlighter: return NSLocalizedString("paper.tool.highlighter", comment: "Highlighter tool")
        case .eraser: return NSLocalizedString("paper.tool.eraser", comment: "Eraser tool")
        case .lasso: return NSLocalizedString("paper.tool.lasso", comment: "Lasso selection tool")
        }
    }

    var accessibilityIdentifier: String { "paper.tool.\(rawValue)" }

    var supportsColor: Bool {
        self == .pen || self == .highlighter
    }
}

struct PaperInkColor: Identifiable, Equatable {
    let id: String
    let localizationKey: String
    let penColor: UIColor
    let highlighterColor: UIColor

    var displayColor: Color { Color(uiColor: penColor) }
    var accessibilityLabel: String { NSLocalizedString(localizationKey, comment: "Ink color") }

    static let palette: [PaperInkColor] = [
        PaperInkColor(
            id: "charcoal",
            localizationKey: "paper.color.charcoal",
            penColor: UIColor(red: 0.11, green: 0.14, blue: 0.13, alpha: 1),
            highlighterColor: UIColor(red: 0.96, green: 0.80, blue: 0.26, alpha: 0.7)
        ),
        PaperInkColor(
            id: "blue",
            localizationKey: "paper.color.blue",
            penColor: UIColor(red: 0.11, green: 0.37, blue: 0.62, alpha: 1),
            highlighterColor: UIColor(red: 0.41, green: 0.72, blue: 0.96, alpha: 0.7)
        ),
        PaperInkColor(
            id: "crimson",
            localizationKey: "paper.color.crimson",
            penColor: UIColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 1),
            highlighterColor: UIColor(red: 0.95, green: 0.55, blue: 0.51, alpha: 0.7)
        ),
        PaperInkColor(
            id: "forest",
            localizationKey: "paper.color.forest",
            penColor: UIColor(red: 0.17, green: 0.43, blue: 0.31, alpha: 1),
            highlighterColor: UIColor(red: 0.42, green: 0.83, blue: 0.56, alpha: 0.7)
        )
    ]

    static func resolve(_ id: String) -> PaperInkColor {
        palette.first { $0.id == id } ?? palette[0]
    }
}

struct PaperToolState: Equatable {
    var kind: PaperToolKind = .pen
    var colorID: String = PaperInkColor.palette[0].id

    var selectedColor: PaperInkColor { PaperInkColor.resolve(colorID) }

    func makePKTool() -> PKTool {
        switch kind {
        case .pen:
            return PKInkingTool(.pen, color: selectedColor.penColor, width: 3.0)
        case .highlighter:
            return PKInkingTool(.marker, color: selectedColor.highlighterColor, width: 18.0)
        case .eraser:
            return PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        }
    }
}

struct PaperToolPalette: View {
    @Binding var selection: PaperToolState
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PaperToolKind.allCases) { tool in
                toolButton(tool)
            }

            paletteDivider

            HStack(spacing: 6) {
                ForEach(PaperInkColor.palette) { ink in
                    colorButton(ink)
                }
            }
            .padding(.horizontal, 4)
            .opacity(selection.kind.supportsColor ? 1 : 0.35)
            .allowsHitTesting(selection.kind.supportsColor)

            paletteDivider

            undoRedoButton(
                systemImage: "arrow.uturn.backward",
                label: NSLocalizedString("paper.tool.undo", comment: "Undo"),
                identifier: "paper.tool.undo",
                disabled: !canUndo,
                action: onUndo
            )
            undoRedoButton(
                systemImage: "arrow.uturn.forward",
                label: NSLocalizedString("paper.tool.redo", comment: "Redo"),
                identifier: "paper.tool.redo",
                disabled: !canRedo,
                action: onRedo
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paper.tool.palette")
    }

    private func toolButton(_ tool: PaperToolKind) -> some View {
        let isSelected = selection.kind == tool
        return Button {
            selection.kind = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                .accessibilityHidden(true)
                .frame(width: 36, height: 34)
                .background(
                    isSelected ? Theme.accent.opacity(0.14) : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tool.accessibilityIdentifier)
    }

    private func colorButton(_ ink: PaperInkColor) -> some View {
        let isSelected = selection.colorID == ink.id
        return Button {
            selection.colorID = ink.id
        } label: {
            ZStack {
                Circle()
                    .fill(ink.displayColor)
                    .frame(width: 18, height: 18)
                if isSelected {
                    Circle()
                        .strokeBorder(Theme.textPrimary, lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 28, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ink.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paper.color.\(ink.id)")
    }

    private func undoRedoButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(disabled ? Theme.textTertiary : Theme.textPrimary)
                .accessibilityHidden(true)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var paletteDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}
