import Foundation

/// A key press, independent of AppKit/UIKit.
public struct KeyStroke: Equatable, Sendable {
    /// Lower-case character ("b", "[", "0") or a special name: "return", "escape", "delete", "space", "tab".
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
}

/// Everything a shortcut can do.
public enum PaperCommand: Equatable, Sendable {
    case tool(PaperTool)
    case brushSmaller, brushLarger, brushSofter, brushHarder
    case undo, redo
    case duplicateLayer, mergeDown, newLayer, newGroup, deleteLayer
    case fitToScreen, actualPixels, zoomIn, zoomOut, resetRotation
    case selectAll, deselect, invertSelection, clearPixels, fillSelection
    case commit, cancel
    case save, export, importImage
    case toggleMaskEditing
}

/// Photoshop/Procreate-style shortcuts shared by the Mac app and iPad + Magic Keyboard.
///
/// | Key | Action | Key | Action |
/// |---|---|---|---|
/// | B | Brush | E | Eraser |
/// | S | Smudge | L | Lasso |
/// | V | Move/Transform | G | Fill |
/// | I | Eyedropper | [ / ] | Brush size |
/// | ⇧[ / ⇧] | Brush softness | ⌘Z / ⇧⌘Z | Undo / Redo |
/// | ⌘J | Duplicate layer | ⌘E | Merge down |
/// | ⌘⌥0 | Fit to screen | Space-drag | Pan |
public enum PaperKeymap {
    public static func resolve(_ k: KeyStroke) -> PaperCommand? {
        let key = k.key.lowercased()
        if k.command {
            switch (key, k.shift, k.option) {
            case ("z", false, false): return .undo
            case ("z", true, false), ("y", false, false): return .redo
            case ("j", false, false): return .duplicateLayer
            case ("e", false, false): return .mergeDown
            case ("0", _, true), ("0", false, false): return .fitToScreen
            case ("1", false, false): return .actualPixels
            case ("=", _, false), ("+", _, false): return .zoomIn
            case ("-", false, false): return .zoomOut
            case ("a", false, false): return .selectAll
            case ("d", false, false): return .deselect
            case ("i", true, false): return .invertSelection
            case ("n", true, false): return .newLayer
            case ("g", false, false): return .newGroup
            case ("s", false, false): return .save
            case ("e", true, false): return .export
            case ("o", true, false): return .importImage
            case ("delete", false, false), ("backspace", false, false): return .fillSelection
            default: return nil
            }
        }
        if k.control || k.option { return nil }
        switch key {
        case "b": return .tool(.brush)
        case "e": return .tool(.eraser)
        case "s": return .tool(.smudge)
        case "l": return .tool(.lasso)
        case "v": return .tool(.move)
        case "g": return .tool(.fill)
        case "i": return .tool(.eyedropper)
        case "[", "{": return k.shift ? .brushSofter : .brushSmaller
        case "]", "}": return k.shift ? .brushHarder : .brushLarger
        case "return", "enter": return .commit
        case "escape": return .cancel
        case "delete", "backspace": return .clearPixels
        case "\\": return .toggleMaskEditing
        case "r": return k.shift ? .resetRotation : nil
        default: return nil
        }
    }
}

extension CanvasDocument {
    /// Runs a shortcut command. View commands (zoom/fit) and file commands are returned for the caller.
    /// Returns true if the command was handled here.
    @discardableResult
    public func perform(_ command: PaperCommand) -> Bool {
        switch command {
        case .tool(let t):
            if t == .move { tool = .move; beginTransform() } else { tool = t }
        case .brushSmaller: adjustSize(by: 1 / 1.15)
        case .brushLarger: adjustSize(by: 1.15)
        case .brushSofter: adjustHardness(by: -0.1)
        case .brushHarder: adjustHardness(by: 0.1)
        case .undo: undo()
        case .redo: redo()
        case .duplicateLayer: duplicateLayer()
        case .mergeDown: mergeDown()
        case .newLayer: addLayer()
        case .newGroup: groupActiveLayer()
        case .deleteLayer: deleteLayer()
        case .selectAll: selectAll()
        case .deselect: deselect()
        case .invertSelection: invertSelection()
        case .clearPixels: clearSelectedPixels()
        case .fillSelection: fillSelection()
        case .commit: commitTransform()
        case .cancel:
            if transformState != nil { cancelTransform() } else if !lassoPath.isEmpty { lassoPath = [] } else { deselect() }
        case .toggleMaskEditing:
            if activeLayer?.hasMask == true { editingMask.toggle() }
        case .fitToScreen, .actualPixels, .zoomIn, .zoomOut, .resetRotation, .save, .export, .importImage:
            return false
        }
        return true
    }
}
