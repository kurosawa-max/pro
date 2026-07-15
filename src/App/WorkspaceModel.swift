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
    @Published var showsTranslationGizmo = true
    @Published private(set) var gizmoMode = GizmoMode.translate
    @Published private(set) var translationGizmoState = TranslationGizmoState()
    @Published private(set) var rotationGizmoState = RotationGizmoState()
    @Published private(set) var scaleGizmoState = ScaleGizmoState()
    @Published var brush = BrushKind.draw
    @Published var brushSettings = BrushSettings()
    @Published var symmetry = SculptSymmetry.none
    @Published var hoverLocation: CGPoint?
    @Published var status = "Ready"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    #if DEBUG
    @Published private(set) var benchmarkPreset: BenchmarkPreset?
    @Published private(set) var isBenchmarkRunning = false
    @Published private(set) var benchmarkProgress = 0.0
    @Published private(set) var lastBenchmarkReport: BenchmarkReport?
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkRunner: BenchmarkRunner?
    #endif

    private var history = WorkspaceHistory()
    private let pickingCache = MeshBVHCache()
    private let sculptSpatialIndex = VertexSpatialIndex()
    private var strokeBefore: [Int: SIMD3<Float>]?
    private var lastHit: SIMD3<Float>?
    private var strokeSymmetry = SculptSymmetry.none
    private var flattenPlane: FlattenPlane?
    private var panelTransformBefore: ObjectTransform?

    init() {
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
    }

    func beginStroke() {
        guard !isGizmoDragging else { return }
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        commitTransformPanelTransaction()
        if strokeBefore != nil { cancelStroke() }
        strokeBefore = [:]
        strokeSymmetry = symmetry
        flattenPlane = nil
        lastHit = nil
    }

    func updateStroke(sample: PencilSample, ray: Ray) {
        guard let localRay = objectTransform.localRay(fromWorld: ray),
              let hit = MeshPicker.hit(ray: localRay, mesh: mesh, profiler: profiler, cache: pickingCache) else { return }
        let drag = lastHit.map { hit.position - $0 } ?? .zero
        if brush == .flatten, flattenPlane == nil { flattenPlane = FlattenPlane(origin: hit.position, normal: hit.normal) }
        var localSettings = brushSettings
        let maximumScale = max(abs(objectTransform.scale.x), abs(objectTransform.scale.y), abs(objectTransform.scale.z))
        localSettings.radius = brushSettings.radius / max(maximumScale, ObjectTransform.minimumScaleMagnitude)
        let mutations = SculptBrush.apply(kind: brush, center: hit.position, normal: hit.normal, drag: drag,
                                          pressure: sample.pressure, settings: localSettings,
                                          mesh: &mesh, profiler: profiler, symmetry: strokeSymmetry,
                                          flattenPlane: flattenPlane, spatialIndex: sculptSpatialIndex)
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
        record(.sculpt(StrokeCommand(changes: changes)))
        strokeBefore = nil; lastHit = nil; flattenPlane = nil
    }

    func cancelStroke() {
        if let before = strokeBefore {
            let mutations = mesh.updatePositions(before, profiler: profiler)
            sculptSpatialIndex.didUpdate(mutations, mesh: mesh)
        }
        strokeBefore = nil
        lastHit = nil
        flattenPlane = nil
    }

    func undo() {
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        guard let command = history.undoCommand() else { return }
        apply(command, useAfter: false)
        syncHistoryAvailability()
    }

    func redo() {
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        guard let command = history.redoCommand() else { return }
        apply(command, useAfter: true)
        syncHistoryAvailability()
    }

    func projectData() throws -> Data {
        try ProjectCodec.encode(ForgeProject(mesh: mesh, camera: camera, transform: objectTransform,
                                             metadata: ["generator": "Forge3D Foundation Prototype"]))
    }

    func load(data: Data) {
        cancelStroke()
        cancelAllGizmoDrags()
        do {
            let project = try ProjectCodec.decode(data)
            discardTransformPanelTransaction()
            mesh = project.mesh; camera = project.camera; objectTransform = project.transform.sanitized()
            symmetry = .none
            history.removeAll(); syncHistoryAvailability(); status = "Project loaded"
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
    var isTransformPanelEditing: Bool { panelTransformBefore != nil }

    func subdivisionEstimate() throws -> SubdivisionEstimate {
        try MeshSubdivision.estimate(mesh)
    }

    func subdivideMeshOnce() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        let estimate = try MeshSubdivision.estimate(mesh)
        try MeshSubdivision.validateLimits(estimate)
        let before = workspaceSnapshot
        let subdivided = try MeshSubdivision.subdivideOnce(mesh)
        mesh = subdivided
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        record(.replaceMesh(ReplaceMeshCommand(before: before, after: workspaceSnapshot)))
        status = "Subdivided: \(estimate.resultVertices) vertices, \(estimate.resultTriangles) triangles"
    }

    func createPrimitive(parameters: PrimitiveParameters) throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        let generated = try PrimitiveMeshBuilder.build(parameters)
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        let before = workspaceSnapshot
        mesh = generated
        objectTransform = .identity
        camera = Self.framedCamera(for: generated)
        hoverLocation = nil
        translationGizmoState = TranslationGizmoState()
        rotationGizmoState = RotationGizmoState()
        scaleGizmoState = ScaleGizmoState()
        gizmoMode = .translate
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        let after = workspaceSnapshot
        record(.replaceMesh(ReplaceMeshCommand(before: before, after: after)))
        status = "Created \(parameters.kind.displayName)"
    }

    static func framedCamera(for mesh: EditableMesh) -> CameraState {
        let bounds = mesh.bounds
        guard bounds.isFinite else { return CameraState() }
        let radius = max(simd_length(bounds.extent) * 0.5, 0.001)
        let distance = radius / tan(Float(22.5) * .pi / 180) * 1.25
        return CameraState(yaw: 0.4, pitch: 0.25,
                           distance: distance.isFinite ? max(distance, 0.01) : 3.5,
                           target: bounds.center)
    }

    func updateTransform(_ value: ObjectTransform) {
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        cancelStroke()
        cancelAllGizmoDrags()
        let before = objectTransform
        objectTransform = value.sanitized()
        if panelTransformBefore == nil { recordTransform(before: before, after: objectTransform) }
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

    func resetTransform() {
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        let before = objectTransform
        objectTransform = .identity
        recordTransform(before: before, after: objectTransform)
        status = "Transform reset"
    }

    func beginTransformPanelTransaction() {
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        guard panelTransformBefore == nil else { return }
        cancelStroke()
        cancelAllGizmoDrags()
        panelTransformBefore = objectTransform
    }

    func commitTransformPanelTransaction() {
        guard let before = panelTransformBefore else { return }
        panelTransformBefore = nil
        recordTransform(before: before, after: objectTransform)
    }

    func discardTransformPanelTransaction() {
        panelTransformBefore = nil
    }

    func translationGizmoHit(ray: Ray, scale: Float) -> TranslationGizmoHit? {
        guard showsTranslationGizmo, gizmoMode == .translate else { return nil }
        #if DEBUG
        guard !isBenchmarkRunning else { return nil }
        #endif
        return TranslationGizmoGeometry.hit(ray: ray, origin: objectTransform.translation, scale: scale)
    }

    @discardableResult
    func beginTranslationGizmoDrag(handle: TranslationGizmoHandle, ray: Ray,
                                   cameraDirection: SIMD3<Float>) -> Bool {
        guard showsTranslationGizmo, gizmoMode == .translate, !isGizmoDragging else { return false }
        #if DEBUG
        guard !isBenchmarkRunning else { return false }
        #endif
        commitTransformPanelTransaction()
        cancelStroke()
        cancelTranslationGizmoDrag()
        guard let session = TranslationGizmoGeometry.beginSession(handle: handle, ray: ray,
                                                                   transform: objectTransform,
                                                                   cameraDirection: cameraDirection) else { return false }
        translationGizmoState.activeHandle = handle
        translationGizmoState.dragSession = session
        return true
    }

    func updateTranslationGizmoDrag(ray: Ray, cameraDirection: SIMD3<Float>) {
        guard let session = translationGizmoState.dragSession,
              let translation = TranslationGizmoGeometry.translation(session: session, ray: ray,
                                                                      cameraDirection: cameraDirection) else { return }
        var transform = session.startTransform
        transform.translation = translation
        objectTransform = transform.sanitized()
        status = "Move Gizmo"
    }

    func endTranslationGizmoDrag() {
        let startTransform = translationGizmoState.dragSession?.startTransform
        translationGizmoState.dragSession = nil
        translationGizmoState.activeHandle = nil
        if let startTransform { recordTransform(before: startTransform, after: objectTransform) }
    }

    func cancelTranslationGizmoDrag() {
        if let session = translationGizmoState.dragSession { objectTransform = session.startTransform }
        translationGizmoState.dragSession = nil
        translationGizmoState.activeHandle = nil
    }

    func updateTranslationGizmoHover(ray: Ray?, scale: Float) {
        guard !translationGizmoState.isDragging else { return }
        translationGizmoState.hoverHandle = ray.flatMap { translationGizmoHit(ray: $0, scale: scale)?.handle }
    }

    func setTranslationGizmoVisible(_ visible: Bool) {
        if !visible {
            cancelAllGizmoDrags()
            translationGizmoState.hoverHandle = nil
            rotationGizmoState.hoverHandle = nil
            scaleGizmoState.hoverHandle = nil
        }
        showsTranslationGizmo = visible
    }

    var isGizmoDragging: Bool {
        translationGizmoState.isDragging || rotationGizmoState.isDragging || scaleGizmoState.isDragging
    }

    func setGizmoMode(_ mode: GizmoMode) {
        guard mode != gizmoMode else { return }
        cancelAllGizmoDrags()
        translationGizmoState.hoverHandle = nil
        rotationGizmoState.hoverHandle = nil
        scaleGizmoState.hoverHandle = nil
        gizmoMode = mode
    }

    func rotationGizmoHit(ray: Ray, scale: Float) -> RotationGizmoHit? {
        guard showsTranslationGizmo, gizmoMode == .rotate else { return nil }
        #if DEBUG
        guard !isBenchmarkRunning else { return nil }
        #endif
        return RotationGizmoGeometry.hit(ray: ray, origin: objectTransform.translation, scale: scale)
    }

    @discardableResult
    func beginRotationGizmoDrag(handle: RotationGizmoHandle, ray: Ray) -> Bool {
        guard showsTranslationGizmo, gizmoMode == .rotate, !isGizmoDragging else { return false }
        #if DEBUG
        guard !isBenchmarkRunning else { return false }
        #endif
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        guard let session = RotationGizmoGeometry.beginSession(handle: handle, ray: ray,
                                                                transform: objectTransform) else { return false }
        rotationGizmoState.activeHandle = handle
        rotationGizmoState.dragSession = session
        return true
    }

    func updateRotationGizmoDrag(ray: Ray) {
        guard var session = rotationGizmoState.dragSession,
              let update = RotationGizmoGeometry.rotation(session: session, ray: ray) else { return }
        var transform = session.startTransform
        transform.rotation = update.rotation
        objectTransform = transform.sanitized()
        session.lastRawAngle = update.rawAngle
        session.accumulatedAngle = update.accumulatedAngle
        rotationGizmoState.dragSession = session
        status = "Rotate Gizmo"
    }

    func endRotationGizmoDrag() {
        let startTransform = rotationGizmoState.dragSession?.startTransform
        rotationGizmoState.dragSession = nil
        rotationGizmoState.activeHandle = nil
        if let startTransform { recordTransform(before: startTransform, after: objectTransform) }
    }

    func cancelRotationGizmoDrag() {
        if let session = rotationGizmoState.dragSession { objectTransform = session.startTransform }
        rotationGizmoState.dragSession = nil
        rotationGizmoState.activeHandle = nil
    }

    func updateRotationGizmoHover(ray: Ray?, scale: Float) {
        guard !rotationGizmoState.isDragging else { return }
        rotationGizmoState.hoverHandle = ray.flatMap { rotationGizmoHit(ray: $0, scale: scale)?.handle }
    }

    func scaleGizmoHit(ray: Ray, scale: Float) -> ScaleGizmoHit? {
        guard showsTranslationGizmo, gizmoMode == .scale else { return nil }
        #if DEBUG
        guard !isBenchmarkRunning else { return nil }
        #endif
        return ScaleGizmoGeometry.hit(ray: ray, origin: objectTransform.translation, scale: scale)
    }

    @discardableResult
    func beginScaleGizmoDrag(handle: ScaleGizmoHandle, ray: Ray,
                             cameraDirection: SIMD3<Float>, referenceLength: Float) -> Bool {
        guard showsTranslationGizmo, gizmoMode == .scale, !isGizmoDragging else { return false }
        #if DEBUG
        guard !isBenchmarkRunning else { return false }
        #endif
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        guard let session = ScaleGizmoGeometry.beginSession(
            handle: handle, ray: ray, transform: objectTransform,
            cameraDirection: cameraDirection, referenceLength: referenceLength) else { return false }
        scaleGizmoState.activeHandle = handle
        scaleGizmoState.dragSession = session
        return true
    }

    func updateScaleGizmoDrag(ray: Ray, cameraDirection: SIMD3<Float>) {
        guard var session = scaleGizmoState.dragSession,
              let scale = ScaleGizmoGeometry.scale(session: session, ray: ray,
                                                   cameraDirection: cameraDirection) else { return }
        var transform = session.startTransform
        transform.scale = scale
        objectTransform = transform.sanitized()
        session.lastValidScale = objectTransform.scale
        scaleGizmoState.dragSession = session
        status = "Scale Gizmo"
    }

    func endScaleGizmoDrag() {
        let startTransform = scaleGizmoState.dragSession?.startTransform
        scaleGizmoState.dragSession = nil
        scaleGizmoState.activeHandle = nil
        if let startTransform { recordTransform(before: startTransform, after: objectTransform) }
    }

    func cancelScaleGizmoDrag() {
        if let session = scaleGizmoState.dragSession { objectTransform = session.startTransform }
        scaleGizmoState.dragSession = nil
        scaleGizmoState.activeHandle = nil
    }

    func updateScaleGizmoHover(ray: Ray?, scale: Float) {
        guard !scaleGizmoState.isDragging else { return }
        scaleGizmoState.hoverHandle = ray.flatMap { scaleGizmoHit(ray: $0, scale: scale)?.handle }
    }

    func cancelAllGizmoDrags() {
        cancelTranslationGizmoDrag()
        cancelRotationGizmoDrag()
        cancelScaleGizmoDrag()
    }

    private func record(_ command: WorkspaceCommand) {
        history.record(command)
        syncHistoryAvailability()
    }

    private func recordTransform(before: ObjectTransform, after: ObjectTransform) {
        guard let command = TransformCommand(before: before, after: after) else { return }
        record(.transform(command))
    }

    private func apply(_ command: WorkspaceCommand, useAfter: Bool) {
        switch command {
        case .sculpt(let stroke):
            let positions = Dictionary(uniqueKeysWithValues: stroke.changes.map {
                ($0.index, useAfter ? $0.after : $0.before)
            })
            let mutations = mesh.updatePositions(positions, profiler: profiler)
            sculptSpatialIndex.didUpdate(mutations, mesh: mesh)
        case .transform(let transform):
            objectTransform = (useAfter ? transform.after : transform.before).sanitized()
        case .replaceMesh(let replacement):
            let snapshot = useAfter ? replacement.after : replacement.before
            mesh = snapshot.mesh
            objectTransform = snapshot.transform.sanitized()
            camera = snapshot.camera
            hoverLocation = nil
            profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        }
    }

    private var workspaceSnapshot: WorkspaceMeshSnapshot {
        WorkspaceMeshSnapshot(mesh: mesh, transform: objectTransform, camera: camera)
    }

    private func syncHistoryAvailability() {
        #if DEBUG
        let isEnabled = !isBenchmarkRunning
        #else
        let isEnabled = true
        #endif
        canUndo = isEnabled && history.canUndo
        canRedo = isEnabled && history.canRedo
    }

    #if DEBUG
    func loadBenchmarkPreset(_ preset: BenchmarkPreset) {
        cancelAllGizmoDrags()
        cancelStroke()
        discardTransformPanelTransaction()
        history.removeAll()
        syncHistoryAvailability()
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
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        let originalMesh = mesh, originalCamera = camera, originalBrush = brush
        let originalSettings = brushSettings, originalPreset = benchmarkPreset, originalHistory = history
        let originalSymmetry = symmetry
        let originalTransform = objectTransform
        let runner = BenchmarkRunner(); benchmarkRunner = runner
        objectTransform = .identity
        symmetry = .none
        isBenchmarkRunning = true; benchmarkProgress = 0; lastBenchmarkReport = nil
        syncHistoryAvailability()
        benchmarkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.mesh = originalMesh; self.camera = originalCamera; self.brush = originalBrush
                self.brushSettings = originalSettings; self.benchmarkPreset = originalPreset; self.history = originalHistory
                self.objectTransform = originalTransform
                self.symmetry = originalSymmetry
                self.profiler?.reset(vertexCount: originalMesh.vertices.count, triangleCount: originalMesh.indices.count / 3)
                self.isBenchmarkRunning = false; self.benchmarkRunner = nil; self.benchmarkTask = nil
                self.syncHistoryAvailability()
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

enum WorkspaceError: Error { case benchmarkInProgress }
