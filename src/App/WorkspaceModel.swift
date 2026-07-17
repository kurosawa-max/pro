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
    @Published var mesh = EditableMesh.icosphere() {
        didSet {
            if oldValue != mesh || oldValue.runtime != mesh.runtime {
                meshMutationGeneration.advance()
                markMeshDiagnosticsStale()
                if !isInstallingMeshCleanup { lastMeshCleanupSummary = nil }
            }
        }
    }
    @Published var camera = CameraState()
    @Published private(set) var objectTransform = ObjectTransform.identity {
        didSet {
            if oldValue.sanitized() != objectTransform.sanitized() { markMeshDiagnosticsStale() }
        }
    }
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
    @Published private(set) var isSTLImporting = false
    @Published private(set) var meshDiagnosticsReport: MeshDiagnosticsReport? = nil
    @Published private(set) var isMeshDiagnosticsRunning = false
    @Published private(set) var meshDiagnosticsError: String? = nil
    @Published var meshDiagnosticsOverlayOptions = MeshDiagnosticsOverlayOptions()
    @Published private(set) var meshDiagnosticsOverlayRevision: UInt64 = 0
    @Published private(set) var isMeshCleanupRunning = false
    @Published private(set) var lastMeshCleanupSummary: MeshCleanupSummary? = nil
    @Published private(set) var saveState = ProjectSaveState.saved
    @Published private(set) var recoveryDescriptor: RecoveryDescriptor?
    @Published private(set) var recoveryInspectionError: String?
    @Published private(set) var isRecoveryPromptPresented = false
    @Published private(set) var isRecoveryOperationInProgress = false
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
    private let meshDiagnosticsCache = MeshDiagnosticsCache()
    private var meshDiagnosticsNeedsRefresh = false
    private var isInstallingMeshCleanup = false
    private var meshMutationGeneration = MutationGeneration()
    private(set) var projectMutationGeneration = MutationGeneration()
    private(set) var lastSavedGeneration: MutationGeneration
    private var workspaceSessionID = UUID()
    private(set) var currentProjectName = "Unsaved Project"
    private var projectMetadata = ["generator": "Forge3D Foundation Prototype"]
    private let autosaveCoordinator: ProjectAutosaveCoordinator
    private var autosaveSubmissionTask: Task<Void, Never>?
    private var hasInspectedRecovery = false
    private var isAutosaveEnabled = false
    private var strokeBefore: [Int: SIMD3<Float>]?
    private var lastHit: SIMD3<Float>?
    private var strokeSymmetry = SculptSymmetry.none
    private var flattenPlane: FlattenPlane?
    private var panelTransformBefore: ObjectTransform?

    init(autosaveCoordinator: ProjectAutosaveCoordinator = ProjectAutosaveCoordinator()) {
        self.autosaveCoordinator = autosaveCoordinator
        self.lastSavedGeneration = projectMutationGeneration
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
        strokeBefore = nil; lastHit = nil; flattenPlane = nil
        record(.sculpt(StrokeCommand(changes: changes)))
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
        projectMutationDidCommit()
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
        projectMutationDidCommit()
    }

    func projectData() throws -> Data {
        try ProjectCodec.encode(currentProject)
    }

    func load(data: Data) {
        do {
            try loadProject(data: data)
        } catch { status = "Open failed: \(error.localizedDescription)" }
    }

    var isDirty: Bool { projectMutationGeneration != lastSavedGeneration }
    var hasRecoveryConflict: Bool {
        recoveryDescriptor.map { $0.sessionID != workspaceSessionID } ?? false
    }

    private var currentProject: ForgeProject {
        ForgeProject(mesh: mesh, camera: camera, transform: objectTransform,
                     metadata: projectMetadata)
    }

    func makeAutosaveSnapshot(capturedAt: Date = Date()) throws -> ProjectAutosaveSnapshot {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else {
            throw WorkspaceError.activeEditInProgress
        }
        return ProjectAutosaveSnapshot(project: currentProject,
                                       sourceGeneration: projectMutationGeneration,
                                       capturedAt: capturedAt,
                                       sessionID: workspaceSessionID,
                                       projectName: currentProjectName)
    }

    func prepareExplicitSave(capturedAt: Date = Date()) throws -> ProjectAutosaveSnapshot {
        guard !isStrokeActive, !isGizmoDragging else { throw WorkspaceError.activeEditInProgress }
        commitTransformPanelTransaction()
        return try makeAutosaveSnapshot(capturedAt: capturedAt)
    }

    func explicitSaveSucceeded(_ snapshot: ProjectAutosaveSnapshot, url: URL) async {
        guard snapshot.sessionID == workspaceSessionID else { return }
        currentProjectName = url.deletingPathExtension().lastPathComponent
        lastSavedGeneration = snapshot.sourceGeneration
        saveState = isDirty ? .unsavedChanges : .saved
        do {
            autosaveSubmissionTask?.cancel()
            autosaveSubmissionTask = nil
            await autosaveCoordinator.cancelPending()
            try await autosaveCoordinator.discardSavedRecovery(
                sessionID: snapshot.sessionID, generation: snapshot.sourceGeneration)
            do {
                let retainedRecovery = try await autosaveCoordinator.inspectRecovery()
                recoveryDescriptor = retainedRecovery.descriptor
                recoveryInspectionError = nil
                isRecoveryPromptPresented = retainedRecovery.descriptor.sessionID != workspaceSessionID
            } catch RecoveryStorageError.missing {
                recoveryDescriptor = nil
                recoveryInspectionError = nil
                isRecoveryPromptPresented = false
            }
        } catch {
            status = "Saved, but Recovery cleanup failed: \(error.localizedDescription)"
        }
        if isDirty { scheduleAutosaveIfSafe() }
    }

    func explicitSaveFailed(_ error: Error) {
        saveState = isDirty ? .unsavedChanges : .saved
        status = "Save failed: \(error.localizedDescription)"
    }

    func explicitSaveCancelled() {
        saveState = isDirty ? .unsavedChanges : .saved
        status = "Save cancelled"
    }

    func loadProject(data: Data, projectName: String = "Unsaved Project") throws {
        let project = try ProjectCodec.decode(data)
        var rebuiltMesh = project.mesh
        _ = rebuiltMesh.adjacency()
        let rebuiltPicking = try MeshBVH(mesh: rebuiltMesh)

        cancelStroke()
        cancelAllGizmoDrags()
        discardTransformPanelTransaction()
        mesh = rebuiltMesh
        camera = project.camera
        objectTransform = project.transform.sanitized()
        projectMetadata = project.metadata
        clearMeshDiagnostics()
        symmetry = .none
        history.removeAll()
        syncHistoryAvailability()
        pickingCache.install(rebuiltPicking, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        workspaceSessionID = UUID()
        currentProjectName = projectName
        projectMutationGeneration.advance()
        lastSavedGeneration = projectMutationGeneration
        saveState = .saved
        status = "Project loaded"
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
    }

    func inspectRecoveryOnLaunch(force: Bool = false) async {
        guard force || !hasInspectedRecovery else { return }
        hasInspectedRecovery = true
        isAutosaveEnabled = true
        do {
            let recovery = try await autosaveCoordinator.inspectRecovery()
            recoveryDescriptor = recovery.descriptor
            recoveryInspectionError = nil
            isRecoveryPromptPresented = true
        } catch RecoveryStorageError.missing {
            recoveryDescriptor = nil
            recoveryInspectionError = nil
        } catch {
            recoveryDescriptor = nil
            recoveryInspectionError = error.localizedDescription
            isRecoveryPromptPresented = true
        }
    }

    func recoverAutosave() async {
        guard !isRecoveryOperationInProgress else { return }
        isRecoveryOperationInProgress = true
        defer { isRecoveryOperationInProgress = false }
        do {
            let recovery = try await autosaveCoordinator.inspectRecovery()
            var recoveredMesh = recovery.project.mesh
            _ = recoveredMesh.adjacency()
            let rebuiltPicking = try MeshBVH(mesh: recoveredMesh)

            cancelStroke()
            cancelAllGizmoDrags()
            discardTransformPanelTransaction()
            mesh = recoveredMesh
            camera = recovery.project.camera
            objectTransform = recovery.project.transform.sanitized()
            projectMetadata = recovery.project.metadata
            clearMeshDiagnostics()
            history.removeAll()
            syncHistoryAvailability()
            pickingCache.install(rebuiltPicking, for: mesh)
            sculptSpatialIndex.prepare(for: mesh)
            workspaceSessionID = recovery.descriptor.sessionID
            currentProjectName = recovery.descriptor.projectName
            lastSavedGeneration = projectMutationGeneration
            projectMutationGeneration.advance()
            saveState = .autosaved(recovery.descriptor.capturedAt)
            recoveryDescriptor = recovery.descriptor
            recoveryInspectionError = nil
            isRecoveryPromptPresented = false
            hoverLocation = nil
            #if DEBUG
            benchmarkPreset = nil
            #endif
            profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
            status = "Recovered unsaved work"
        } catch {
            recoveryInspectionError = error.localizedDescription
            isRecoveryPromptPresented = true
            status = "Recovery failed: \(error.localizedDescription)"
        }
    }

    func discardRecovery() async {
        guard !isRecoveryOperationInProgress else { return }
        isRecoveryOperationInProgress = true
        defer { isRecoveryOperationInProgress = false }
        do {
            try await autosaveCoordinator.discardRecovery()
            recoveryDescriptor = nil
            recoveryInspectionError = nil
            isRecoveryPromptPresented = false
            status = "Recovery discarded"
            if isDirty { scheduleAutosaveIfSafe() }
        } catch {
            recoveryInspectionError = error.localizedDescription
            status = "Recovery discard failed: \(error.localizedDescription)"
        }
    }

    func postponeRecovery() { isRecoveryPromptPresented = false }
    func presentRecovery() {
        guard recoveryDescriptor != nil || recoveryInspectionError != nil else { return }
        isRecoveryPromptPresented = true
    }

    func retryAutosave() async { _ = await requestImmediateAutosave() }

    @discardableResult
    func requestImmediateAutosave() async -> Bool {
        guard isDirty else { return true }
        if let recoveryDescriptor,
           recoveryDescriptor.sessionID == workspaceSessionID,
           recoveryDescriptor.sourceGeneration == projectMutationGeneration {
            saveState = .autosaved(recoveryDescriptor.capturedAt)
            return true
        }
        #if DEBUG
        guard !isBenchmarkRunning else {
            saveState = .unsavedChanges
            status = "Autosave is waiting for the benchmark to finish."
            return false
        }
        #endif
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else {
            saveState = .unsavedChanges
            status = "Autosave is waiting for the active edit to finish."
            return false
        }
        autosaveSubmissionTask?.cancel()
        autosaveSubmissionTask = nil
        do {
            let snapshot = try makeAutosaveSnapshot()
            saveState = .autosaving
            let descriptor = try await autosaveCoordinator.flush(snapshot)
            handleAutosaveResult(.success(snapshot, descriptor))
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            status = "Autosave failed: \(error.localizedDescription)"
            return false
        }
    }

    func prepareForProjectLoad() async -> Bool {
        #if DEBUG
        guard !isBenchmarkRunning else {
            status = "Wait for the benchmark to finish before opening a project."
            return false
        }
        #endif
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else {
            status = "Finish the active edit before opening another project."
            return false
        }
        if hasRecoveryConflict {
            status = "Resolve the existing Recovery before opening another project."
            presentRecovery()
            return false
        }
        if !isDirty { return true }
        return await requestImmediateAutosave()
    }

    func handleLifecycleActive() async { await inspectRecoveryOnLaunch(force: recoveryDescriptor == nil) }
    func handleLifecycleInactiveOrBackground() async {
        guard isDirty else { return }
        _ = await requestImmediateAutosave()
    }

    func commitCameraChange(from before: CameraState) {
        guard before != camera else { return }
        projectMutationDidCommit()
    }

    var objectDimensions: ObjectDimensions? { ObjectDimensions.make(mesh: mesh, transform: objectTransform) }

    var isMeshDiagnosticsStale: Bool {
        guard let report = meshDiagnosticsReport else { return false }
        return meshDiagnosticsNeedsRefresh
            || report.sourceTopologyID != mesh.runtime.topologyID
            || report.sourceTopologyRevision != mesh.runtime.topologyRevision
            || report.sourceRevision != mesh.runtime.revision
            || report.sourceTransform != objectTransform.sanitized()
    }

    var currentMeshDiagnosticsReport: MeshDiagnosticsReport? {
        isMeshDiagnosticsStale ? nil : meshDiagnosticsReport
    }

    var currentMeshDiagnosticsOverlay: MeshDiagnosticsOverlayData? {
        return currentMeshDiagnosticsReport?.overlay
    }

    @discardableResult
    func analyzeCurrentMesh() throws -> MeshDiagnosticsReport {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isMeshDiagnosticsRunning else { throw WorkspaceError.diagnosticsInProgress }
        guard !isStrokeActive, !isGizmoDragging else { throw WorkspaceError.activeDiagnosticsEdit }
        isMeshDiagnosticsRunning = true
        meshDiagnosticsError = nil
        defer { isMeshDiagnosticsRunning = false }
        let previousOverlay = meshDiagnosticsReport?.overlay
        let report = meshDiagnosticsCache.report(mesh: mesh, transform: objectTransform)
        meshDiagnosticsReport = report
        meshDiagnosticsNeedsRefresh = false
        lastMeshCleanupSummary = nil
        let overlayChanged = previousOverlay.map { $0 != report.overlay } ?? true
        if overlayChanged { meshDiagnosticsOverlayRevision &+= 1 }
        status = "Mesh diagnostics: \(report.severity.displayName)"
        return report
    }

    func refreshMeshDiagnostics() {
        do { _ = try analyzeCurrentMesh() }
        catch {
            meshDiagnosticsError = error.localizedDescription
            status = "Diagnostics failed: \(error.localizedDescription)"
        }
    }

    func clearMeshDiagnostics() {
        meshDiagnosticsReport = nil
        meshDiagnosticsNeedsRefresh = false
        meshDiagnosticsError = nil
        lastMeshCleanupSummary = nil
        meshDiagnosticsCache.invalidate()
        meshDiagnosticsOverlayRevision &+= 1
    }

    private func markMeshDiagnosticsStale() {
        if meshDiagnosticsReport != nil { meshDiagnosticsNeedsRefresh = true }
    }

    func prepareForMeshCleanup() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isMeshCleanupRunning else { throw MeshCleanupError.cleanupInProgress }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        hoverLocation = nil
    }

    func previewMeshCleanup(options: MeshCleanupOptions) throws -> MeshCleanupPreview {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isMeshCleanupRunning else { throw MeshCleanupError.cleanupInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else {
            throw MeshCleanupError.activeEdit
        }
        isMeshCleanupRunning = true
        defer { isMeshCleanupRunning = false }
        return MeshCleanupPreview(
            options: options,
            estimate: try MeshCleanup.estimate(mesh: mesh, options: options),
            source: MeshCleanupSourceKey(mesh: mesh, workspaceMutationGeneration: meshMutationGeneration)
        )
    }

    @discardableResult
    func applyMeshCleanup(preview: MeshCleanupPreview) throws -> MeshCleanupResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isMeshCleanupRunning else { throw MeshCleanupError.cleanupInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else {
            throw MeshCleanupError.activeEdit
        }
        guard preview.source == MeshCleanupSourceKey(
            mesh: mesh, workspaceMutationGeneration: meshMutationGeneration
        ) else { throw MeshCleanupError.stalePreview }
        isMeshCleanupRunning = true
        defer { isMeshCleanupRunning = false }

        let currentEstimate = try MeshCleanup.estimate(mesh: mesh, options: preview.options)
        guard currentEstimate == preview.estimate else { throw MeshCleanupError.stalePreview }
        let result = try MeshCleanup.clean(mesh: mesh, options: preview.options)
        let rebuiltPickingIndex = try MeshBVH(mesh: result.mesh)

        let before = workspaceSnapshot
        do {
            isInstallingMeshCleanup = true
            defer { isInstallingMeshCleanup = false }
            mesh = result.mesh
        }
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        pickingCache.install(rebuiltPickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        record(.replaceMesh(ReplaceMeshCommand(before: before, after: workspaceSnapshot)))

        meshDiagnosticsCache.invalidate()
        meshDiagnosticsNeedsRefresh = meshDiagnosticsReport != nil
        meshDiagnosticsError = nil
        meshDiagnosticsOverlayRevision &+= 1
        lastMeshCleanupSummary = result.summary
        status = "Cleanup complete: removed \(result.removedDegenerateTriangleCount + result.removedDuplicateTriangleCount) triangles and \(result.removedIsolatedVertexCount + result.removedUnreferencedVertexCount) vertices"
        return result
    }

    var pickingCacheBuildCount: Int { pickingCache.buildCount }
    var sculptSpatialIndexBuildCount: Int { sculptSpatialIndex.buildCount }

    func prepareForSTLExport() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        hoverLocation = nil
    }

    func stlEstimate(options: STLExportOptions = STLExportOptions()) throws -> STLExportEstimate {
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else { throw WorkspaceError.activeEditInProgress }
        return try STLExportPipeline.estimate(mesh: mesh, transform: objectTransform, options: options)
    }

    func stlData(options: STLExportOptions = STLExportOptions()) throws -> Data {
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing else { throw WorkspaceError.activeEditInProgress }
        return try BinarySTLExporter.data(for: mesh, transform: objectTransform, options: options)
    }

    func previewSTLImport(data: Data) throws -> STLImportResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isSTLImporting else { throw WorkspaceError.importInProgress }
        isSTLImporting = true
        defer { isSTLImporting = false }
        return try STLImporter.importMesh(from: data)
    }

    func importSTL(data: Data, fileName: String = "STL") throws {
        let result = try previewSTLImport(data: data)
        try installSTLImport(result, fileName: fileName)
    }

    func installSTLImport(_ result: STLImportResult, fileName: String = "STL") throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isSTLImporting else { throw WorkspaceError.importInProgress }
        isSTLImporting = true
        defer { isSTLImporting = false }

        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        let before = workspaceSnapshot
        mesh = result.mesh
        objectTransform = .identity
        camera = Self.framedCamera(for: result.mesh)
        hoverLocation = nil
        translationGizmoState = TranslationGizmoState()
        rotationGizmoState = RotationGizmoState()
        scaleGizmoState = ScaleGizmoState()
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        record(.replaceMesh(ReplaceMeshCommand(before: before, after: workspaceSnapshot)))
        status = "Imported \(fileName): \(result.sourceTriangleCount) triangles, \(result.weldedVertexCount) vertices (mm)"
    }

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
        let previousCount = history.undoStack.count
        history.record(command)
        syncHistoryAvailability()
        if history.undoStack.count != previousCount { projectMutationDidCommit() }
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

    private func projectMutationDidCommit() {
        projectMutationGeneration.advance()
        saveState = .unsavedChanges
        scheduleAutosaveIfSafe()
    }

    private func scheduleAutosaveIfSafe() {
        guard isAutosaveEnabled else { return }
        if let recoveryDescriptor,
           recoveryDescriptor.sessionID == workspaceSessionID,
           recoveryDescriptor.sourceGeneration == projectMutationGeneration { return }
        guard let snapshot = try? makeAutosaveSnapshot() else { return }
        autosaveSubmissionTask?.cancel()
        autosaveSubmissionTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.autosaveCoordinator.schedule(snapshot) { [weak self] result in
                Task { @MainActor in self?.handleAutosaveResult(result) }
            }
        }
    }

    private func handleAutosaveResult(_ result: AutosaveScheduleResult) {
        switch result {
        case .started(let snapshot):
            if snapshot.sessionID == workspaceSessionID,
               snapshot.sourceGeneration == projectMutationGeneration {
                saveState = .autosaving
            }
        case .success(let snapshot, let descriptor):
            if descriptor.sessionID == workspaceSessionID { recoveryDescriptor = descriptor }
            recoveryInspectionError = nil
            if snapshot.sessionID == workspaceSessionID,
               snapshot.sourceGeneration == projectMutationGeneration {
                saveState = .autosaved(descriptor.capturedAt)
                status = "Recovery snapshot updated"
            }
        case .failure(let snapshot, let message):
            if snapshot.sessionID == workspaceSessionID,
               snapshot.sourceGeneration == projectMutationGeneration {
                saveState = .failed(message)
                status = "Autosave failed: \(message)"
            }
        }
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
        clearMeshDiagnostics()
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
        clearMeshDiagnostics()
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

enum WorkspaceError: Error, LocalizedError, Equatable {
    case benchmarkInProgress
    case activeEditInProgress
    case importInProgress
    case diagnosticsInProgress
    case activeDiagnosticsEdit

    var errorDescription: String? {
        switch self {
        case .benchmarkInProgress: "A benchmark is in progress."
        case .activeEditInProgress: "Finish or cancel the active edit before exporting."
        case .importInProgress: "An STL import is already in progress."
        case .diagnosticsInProgress: "Mesh diagnostics are already running."
        case .activeDiagnosticsEdit: "Finish or cancel the active Sculpt or Gizmo edit before analyzing."
        }
    }
}
