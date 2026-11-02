import Foundation

/// Undo/redo as a stack of reversible steps, bounded by a memory budget (pixel snapshots are big).
public final class UndoHistory {
    public struct Step {
        public let name: String
        let undo: () -> Void
        let redo: () -> Void
        /// Approximate GPU memory the step keeps alive.
        let bytes: Int
        /// Steps with the same key pushed in quick succession merge (e.g. dragging an opacity slider).
        let coalesceKey: String?
        let time: Date
    }

    public private(set) var undoStack: [Step] = []
    public private(set) var redoStack: [Step] = []
    /// Oldest steps are dropped once the kept snapshots exceed this many bytes.
    public var memoryBudget: Int
    public var maxSteps = 250

    public init() {
        #if os(iOS)
        memoryBudget = 600 << 20
        #else
        memoryBudget = 2 << 30
        #endif
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    public func push(_ name: String, bytes: Int = 0, coalesceKey: String? = nil,
                     undo: @escaping () -> Void, redo: @escaping () -> Void) {
        redoStack.removeAll()
        if let key = coalesceKey, let last = undoStack.last, last.coalesceKey == key,
           Date().timeIntervalSince(last.time) < 1.5 {
            // Keep the original "undo" (state before the whole drag) and the newest "redo".
            undoStack[undoStack.count - 1] = Step(name: name, undo: last.undo, redo: redo, bytes: last.bytes + bytes,
                                                  coalesceKey: key, time: Date())
            return
        }
        undoStack.append(Step(name: name, undo: undo, redo: redo, bytes: bytes, coalesceKey: coalesceKey, time: Date()))
        trim()
    }

    @discardableResult
    public func undo() -> String? {
        guard let step = undoStack.popLast() else { return nil }
        step.undo()
        redoStack.append(step)
        return step.name
    }

    @discardableResult
    public func redo() -> String? {
        guard let step = redoStack.popLast() else { return nil }
        step.redo()
        undoStack.append(step)
        return step.name
    }

    public func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func trim() {
        var total = undoStack.reduce(0) { $0 + $1.bytes }
        while undoStack.count > 1 && (total > memoryBudget || undoStack.count > maxSteps) {
            total -= undoStack.removeFirst().bytes
        }
    }
}
