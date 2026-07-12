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
    @Published private(set) var objectTransform = ObjectTransform.identity
    @Published var brush = BrushKind.draw
    @Published var brushSettings = BrushSettings()
    @Published var hoverLocation: CGPoint?
    @Published var status = "Ready"
    #if DEBUG
    @Published private(set) var benchmarkPreset: BenchmarkPreset?
    @Published private(set) var isBenchmarkRunning = false
    @Published private(set) var benchmarkProgress = 0.0
    @Published private(set) var lastBenchmarkReport: BenchmarkReport?
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkRunner: BenchmarkRunner?
    #endif

    private var history = StrokeHistory()
    private let pickingCache = MeshBVHCache()
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
        guard let localRay = objectTransform.localRay(fromWorld: ray),
              let hit = MeshPicker.hit(ray: localRay, mesh: mesh, profiler: profiler, cache: pickingCache) else { return }
        let drag = lastHit.map { hit.position - $0 } ?? .zero
        var localSettings = brushSettings
        let maximumScale = max(abs(objectTransform.scale.x), abs(objectTransform.scale.y), abs(objectTransform.scale.z))
        localSettings.radius = brushSettings.radius / max(maximumScale, ObjectTransform.minimumScaleMagnitude)
        let mutations = SculptBrush.apply(kind: brush, center: hit.position, normal: hit.normal, drag: drag,
                                          pressure: max(sample.pressure, 0.05), settings: localSettings,
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
        try ProjectCodec.encode(ForgeProject(mesh: mesh, camera: camera, transform: objectTransform,
                                             metadata: ["generator": "Forge3D Foundation Prototype"]))
    }

    func load(data: Data) {
        cancelStroke()
        do {
            let project = try ProjectCodec.decode(data)
            mesh = project.mesh; camera = project.camera; objectTransform = project.transform.sanitized()
            history = StrokeHistory(); status = "Project loaded"
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

    func updateTransform(_ value: ObjectTransform) {
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        cancelStroke()
        objectTransform = value.sanitized()
        status = "Transform updated"
    }

    func updateTranslation(_ value: SIMD3<Float>) {
        var transform = objectTransform; transform.translation = value; updateTransform(transform)
    }

    func updateRotationDegrees(_ value: SIMD3<Float>) {
        var transform = objectTransform; transform.rotation = ObjectTransform.rotation(degrees: value); updateTransform(transform)
    }

    func updateScale(_ value: SIMD3<Float>) {
        var transform = objectTransform; transform.scale = value; updateTransform(transform)
    }

    func resetTransform() { updateTransform(.identity) }

    #if DEBUG
    func loadBenchmarkPreset(_ preset: BenchmarkPreset) {
        cancelStroke()
        history = StrokeHistory()
        mesh = preset.makeMesh()
        objectTransform = .identity
        benchmarkPreset = preset
        profiler?.reset(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        status = "Benchmark: \(preset.rawValue)"
    }

    func resetPerformanceMetrics() {
        profiler?.reset(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
    }

    var benchmarkDisplayName: String { benchmarkPreset?.rawValue ?? "Default" }

    func runAllBenchmarks() {
        guard !isBenchmarkRunning, let profiler else { return }
        cancelStroke()
        let originalMesh = mesh, originalCamera = camera, originalBrush = brush
        let originalSettings = brushSettings, originalPreset = benchmarkPreset, originalHistory = history
        let originalTransform = objectTransform
        let runner = BenchmarkRunner(); benchmarkRunner = runner
        objectTransform = .identity
        isBenchmarkRunning = true; benchmarkProgress = 0; lastBenchmarkReport = nil
        benchmarkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.mesh = originalMesh; self.camera = originalCamera; self.brush = originalBrush
                self.brushSettings = originalSettings; self.benchmarkPreset = originalPreset; self.history = originalHistory
                self.objectTransform = originalTransform
                self.profiler?.reset(vertexCount: originalMesh.vertices.count, triangleCount: originalMesh.indices.count / 3)
                self.isBenchmarkRunning = false; self.benchmarkRunner = nil; self.benchmarkTask = nil
            }
            let report = await runner.run(profiler: profiler, progress: { completed, total in
                self.benchmarkProgress = Double(completed) / Double(max(total, 1))
            }, installMesh: { self.mesh = $0 })
            if let report { self.lastBenchmarkReport = report }
        }
    }

    func cancelBenchmarks() {
        benchmarkRunner?.cancel()
        benchmarkTask?.cancel()
    }
    #endif
}
