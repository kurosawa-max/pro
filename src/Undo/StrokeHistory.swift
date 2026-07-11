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
    mutating func undo(mesh: inout EditableMesh) {
        guard let command = undoStack.popLast() else { return }
        apply(command, to: &mesh, useAfter: false); redoStack.append(command)
    }
    mutating func redo(mesh: inout EditableMesh) {
        guard let command = redoStack.popLast() else { return }
        apply(command, to: &mesh, useAfter: true); undoStack.append(command)
    }
    private func apply(_ command: StrokeCommand, to mesh: inout EditableMesh, useAfter: Bool) {
        for change in command.changes where mesh.vertices.indices.contains(change.index) {
            mesh.vertices[change.index].position = useAfter ? change.after : change.before
        }
        mesh.recalculateNormals()
    }
}

