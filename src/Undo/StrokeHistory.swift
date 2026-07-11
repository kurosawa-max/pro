import simd

struct VertexChange: Equatable { let index: Int; let before: SIMD3<Float>; let after: SIMD3<Float> }
struct StrokeCommand: Equatable { let changes: [VertexChange] }

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
