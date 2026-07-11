import Foundation
import CoreGraphics
import simd

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var mesh = EditableMesh.uvSphere()
    @Published var camera = CameraState()
    @Published var brush = BrushKind.draw
    @Published var brushSettings = BrushSettings()
    @Published var hoverLocation: CGPoint?
    @Published var status = "Ready"

    private var history = StrokeHistory()
    private var strokeBefore: [SIMD3<Float>]?
    private var lastHit: SIMD3<Float>?

    func beginStroke() {
        strokeBefore = mesh.vertices.map(\.position)
        lastHit = nil
    }

    func updateStroke(sample: PencilSample, ray: Ray) {
        guard let hit = MeshPicker.hit(ray: ray, mesh: mesh) else { return }
        let drag = lastHit.map { hit.position - $0 } ?? .zero
        _ = SculptBrush.apply(kind: brush, center: hit.position, normal: hit.normal, drag: drag,
                              pressure: max(sample.pressure, 0.05), settings: brushSettings, mesh: &mesh)
        lastHit = hit.position
    }

    func endStroke() {
        guard let before = strokeBefore, before.count == mesh.vertices.count else { strokeBefore = nil; return }
        let changes = mesh.vertices.indices.compactMap { index in
            before[index] == mesh.vertices[index].position ? nil :
                VertexChange(index: index, before: before[index], after: mesh.vertices[index].position)
        }
        history.record(StrokeCommand(changes: changes))
        strokeBefore = nil; lastHit = nil
    }

    func undo() { history.undo(mesh: &mesh) }
    func redo() { history.redo(mesh: &mesh) }

    func projectData() throws -> Data {
        try ProjectCodec.encode(ForgeProject(mesh: mesh, camera: camera,
                                             metadata: ["generator": "Forge3D Foundation Prototype"]))
    }

    func load(data: Data) {
        do {
            let project = try ProjectCodec.decode(data)
            mesh = project.mesh; camera = project.camera; history = StrokeHistory(); status = "Project loaded"
        } catch { status = "Open failed: \(error.localizedDescription)" }
    }

    func stlData() throws -> Data { try BinarySTLExporter.data(for: mesh) }
}
