import simd

struct VertexChange: Equatable { let index: Int; let before: SIMD3<Float>; let after: SIMD3<Float> }
struct StrokeCommand: Equatable { let changes: [VertexChange] }

struct TransformCommand: Equatable {
    let before: ObjectTransform
    let after: ObjectTransform

    init?(before: ObjectTransform, after: ObjectTransform) {
        guard before.isFinite, after.isFinite else { return nil }
        let safeBefore = before.sanitized(), safeAfter = after.sanitized()
        guard !safeBefore.isApproximatelyEqual(to: safeAfter) else { return nil }
        self.before = safeBefore
        self.after = safeAfter
    }
}

struct WorkspaceMeshSnapshot: Equatable {
    let mesh: EditableMesh
    let transform: ObjectTransform
    let camera: CameraState
}

struct ReplaceMeshCommand: Equatable {
    let before: WorkspaceMeshSnapshot
    let after: WorkspaceMeshSnapshot
}

enum WorkspaceCommand: Equatable {
    case sculpt(StrokeCommand)
    case transform(TransformCommand)
    case replaceMesh(ReplaceMeshCommand)
}

struct WorkspaceHistory: Equatable {
    private(set) var undoStack: [WorkspaceCommand] = []
    private(set) var redoStack: [WorkspaceCommand] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ command: WorkspaceCommand) {
        if case .sculpt(let stroke) = command, stroke.changes.isEmpty { return }
        undoStack.append(command)
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func undoCommand() -> WorkspaceCommand? {
        guard let command = undoStack.popLast() else { return nil }
        redoStack.append(command)
        return command
    }

    mutating func redoCommand() -> WorkspaceCommand? {
        guard let command = redoStack.popLast() else { return nil }
        undoStack.append(command)
        return command
    }

    mutating func removeAll() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }
}

struct StrokeHistory {
    private(set) var undoStack: [StrokeCommand] = []
    private(set) var redoStack: [StrokeCommand] = []

    mutating func record(_ command: StrokeCommand) {
        guard !command.changes.isEmpty else { return }
        undoStack.append(command); redoStack.removeAll(keepingCapacity: true)
    }
    mutating func undo(mesh: inout EditableMesh, profiler: PerformanceProfiler? = nil) {
        guard let command = undoStack.popLast() else { return }
        apply(command, to: &mesh, useAfter: false, profiler: profiler); redoStack.append(command)
    }
    mutating func redo(mesh: inout EditableMesh, profiler: PerformanceProfiler? = nil) {
        guard let command = redoStack.popLast() else { return }
        apply(command, to: &mesh, useAfter: true, profiler: profiler); undoStack.append(command)
    }
    private func apply(
        _ command: StrokeCommand,
        to mesh: inout EditableMesh,
        useAfter: Bool,
        profiler: PerformanceProfiler?
    ) {
        let positions = Dictionary(uniqueKeysWithValues: command.changes.map {
            ($0.index, useAfter ? $0.after : $0.before)
        })
        _ = mesh.updatePositions(positions, profiler: profiler)
    }
}
