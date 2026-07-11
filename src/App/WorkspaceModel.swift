import Foundation
import CoreGraphics
import Combine
import simd

@MainActor
final class WorkspaceModel: ObservableObject {
    #if DEBUG
    let profiler: PerformanceProfiler? = PerformanceProfiler()
    #else
    let profiler: PerformanceProfiler? = nil
    #endif
    @Published var mesh = EditableMesh.icosphere()
    @Published var camera = CameraState()
    @Published var brush = BrushKind.draw
    @Published var brushSettings = BrushSettings()
    @Published var hoverLocation: CGPoint?
    @Published var status = "Ready"
    #if DEBUG
    @Published private(set) var benchmarkPreset: BenchmarkPreset?
    #endif

    private var history = StrokeHistory()
    private var strokeBefore: [Int: SIMD3<Float>]?
    private var lastHit: SIMD3<Float>?

    init() {
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
    }

    func beginStroke() {
        if strokeBefore != nil { cancelStroke() }
        strokeBefore = [:]
        lastHit = nil
    }

    func updateStroke(sample: PencilSample, ray: Ray) {
        guard let hit = MeshPicker.hit(ray: ray, mesh: mesh, profiler: profiler) else { return }
        let drag = lastHit.map { hit.position - $0 } ?? .zero
        let mutations = SculptBrush.apply(kind: brush, center: hit.position, normal: hit.normal, drag: drag,
                                          pressure: max(sample.pressure, 0.05), settings: brushSettings,
                                          mesh: &mesh, profiler: profiler)
        for mutation in mutations where strokeBefore?[mutation.index] == nil {
            strokeBefore?[mutation.index] = mutation.before
        }
        lastHit = hit.position
    }

    func endStroke() {
        guard let before = strokeBefore else { return }
        let changes: [VertexChange] = before.keys.sorted().compactMap { index -> VertexChange? in
            guard mesh.vertices.indices.contains(index), before[index] != mesh.vertices[index].position else { return nil }
            return VertexChange(index: index, before: before[index]!, after: mesh.vertices[index].position)
        }
        history.record(StrokeCommand(changes: changes))
        strokeBefore = nil; lastHit = nil
    }

    func cancelStroke() {
        if let before = strokeBefore { _ = mesh.updatePositions(before, profiler: profiler) }
        strokeBefore = nil
        lastHit = nil
    }

    func undo() { history.undo(mesh: &mesh, profiler: profiler) }
    func redo() { history.redo(mesh: &mesh, profiler: profiler) }

    func projectData() throws -> Data {
        try ProjectCodec.encode(ForgeProject(mesh: mesh, camera: camera,
                                             metadata: ["generator": "Forge3D Foundation Prototype"]))
    }

    func load(data: Data) {
        cancelStroke()
        do {
            let project = try ProjectCodec.decode(data)
            mesh = project.mesh; camera = project.camera; history = StrokeHistory(); status = "Project loaded"
            #if DEBUG
            benchmarkPreset = nil
            #endif
            profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        } catch { status = "Open failed: \(error.localizedDescription)" }
    }

    func stlData() throws -> Data { try BinarySTLExporter.data(for: mesh) }

    var isStrokeActive: Bool { strokeBefore != nil }
    var undoCount: Int { history.undoStack.count }
    var redoCount: Int { history.redoStack.count }

    #if DEBUG
    func loadBenchmarkPreset(_ preset: BenchmarkPreset) {
        cancelStroke()
        history = StrokeHistory()
        mesh = preset.makeMesh()
        benchmarkPreset = preset
        profiler?.reset(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        status = "Benchmark: \(preset.rawValue)"
    }

    func resetPerformanceMetrics() {
        profiler?.reset(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
    }

    var benchmarkDisplayName: String { benchmarkPreset?.rawValue ?? "Default" }
    #endif
}
