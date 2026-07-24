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
                topologyEditMeshChangeVersion.advance()
                markMeshDiagnosticsStale()
                if !isInstallingMeshCleanup { lastMeshCleanupSummary = nil }
            }
            reconcileFaceSelection(previousMesh: oldValue)
            reconcileEdgeSelection(previousMesh: oldValue)
        }
    }
    @Published var camera = CameraState()
    @Published private(set) var objectTransform = ObjectTransform.identity {
        didSet {
            if oldValue.sanitized() != objectTransform.sanitized() {
                topologyEditTransformChangeVersion.advance()
                markMeshDiagnosticsStale()
            }
        }
    }
    @Published var showsTranslationGizmo = true
    @Published private(set) var gizmoMode = GizmoMode.translate
    @Published private(set) var translationGizmoState = TranslationGizmoState()
    @Published private(set) var rotationGizmoState = RotationGizmoState()
    @Published private(set) var scaleGizmoState = ScaleGizmoState()
    @Published private(set) var interactionMode = WorkspaceInteractionMode.sculpt
    @Published private(set) var faceSelectionOperation = FaceSelectionOperation.replace
    @Published private(set) var faceSelection = FaceSelection.emptyUnavailable(
        sourceTopologyID: UUID(), sourceTopologyRevision: 0)
    @Published private(set) var isFaceSelectionProcessing = false
    @Published private(set) var faceSelectionError: String?
    @Published private(set) var edgeSelectionOperation = EdgeSelectionOperation.replace
    @Published private(set) var edgeSelection = EdgeSelection.unavailable(
        topologyID: UUID(), topologyRevision: 0)
    @Published private(set) var meshEdgeTable: MeshEdgeTable?
    @Published private(set) var hoveredEdgeID: Int?
    @Published private(set) var edgeSelectionError: String?
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
    @Published private(set) var isFaceExtrudeRunning = false
    @Published private(set) var faceExtrudePreview: FaceExtrudePreview? = nil
    @Published private(set) var faceExtrudeError: String? = nil
    @Published private(set) var isFaceInsetRunning = false
    @Published private(set) var faceInsetPreview: FaceInsetPreview? = nil
    @Published private(set) var faceInsetError: String? = nil
    @Published private(set) var isFaceBevelRunning = false
    @Published private(set) var faceBevelPreview: FaceBevelPreview? = nil
    @Published private(set) var faceBevelError: String? = nil
    @Published private(set) var isMeshMirrorRunning = false
    @Published private(set) var meshMirrorPreview: MeshMirrorPreview? = nil
    @Published private(set) var meshMirrorError: String? = nil
    @Published private(set) var isMeshLinearArrayRunning = false
    @Published private(set) var meshLinearArrayPreview: MeshLinearArrayPreview? = nil
    @Published private(set) var meshLinearArrayError: String? = nil
    @Published private(set) var isMeshRadialArrayRunning = false
    @Published private(set) var meshRadialArrayPreview: MeshRadialArrayPreview? = nil
    @Published private(set) var meshRadialArrayError: String? = nil
    @Published private(set) var meshSeamEditPreview: MeshSeamEditPreview? = nil
    @Published private(set) var meshSeamEditError: String? = nil
    @Published private(set) var isMeshSeamEditRunning = false
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
    private let pickingCache: MeshBVHCache
    private let sculptSpatialIndex = VertexSpatialIndex()
    private let meshDiagnosticsCache = MeshDiagnosticsCache()
    private var meshDiagnosticsNeedsRefresh = false
    private var isInstallingMeshCleanup = false
    private var meshMutationGeneration = MutationGeneration()
    private var topologyEditMeshChangeVersion = TopologyEditChangeVersion()
    private var topologyEditTransformChangeVersion = TopologyEditChangeVersion()
    private var isTopologyEditSnapshotSafe = false
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
    private var faceSelectionTask: Task<Void, Never>?
    private var faceSelectionTaskID: UUID?
    private var meshLinearArrayPreviewRequestID: UUID?
    private var meshRadialArrayPreviewRequestID: UUID?
    private var meshSeamEditPreviewRequestID: UUID?

    private var isFaceTopologyEditRunning: Bool {
        isFaceExtrudeRunning || isFaceInsetRunning || isFaceBevelRunning
    }

    private var isTopologyEditRunning: Bool {
        isFaceTopologyEditRunning || isMeshMirrorRunning
            || isMeshLinearArrayRunning || isMeshRadialArrayRunning
            || isMeshSeamEditRunning
    }

    private struct PreparedFaceExtrudeCommit {
        let result: FaceExtrudeResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    private struct PreparedFaceInsetCommit {
        let result: FaceInsetResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    private struct PreparedFaceBevelCommit {
        let result: FaceBevelResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    private struct PreparedMeshMirrorCommit {
        let result: MeshMirrorResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    private struct PreparedMeshLinearArrayCommit {
        let result: MeshLinearArrayResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    private struct PreparedMeshRadialArrayCommit {
        let result: MeshRadialArrayResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    private struct PreparedMeshSeamEditCommit {
        let result: MeshSeamEditResult
        let before: WorkspaceMeshSnapshot
        let pickingIndex: MeshBVH
    }

    init(autosaveCoordinator: ProjectAutosaveCoordinator = ProjectAutosaveCoordinator(),
         pickingCache: MeshBVHCache = MeshBVHCache()) {
        self.autosaveCoordinator = autosaveCoordinator
        self.pickingCache = pickingCache
        self.lastSavedGeneration = projectMutationGeneration
        rebuildFaceSelectionForCurrentTopology()
        rebuildEdgeSelectionForCurrentTopology()
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
    }

    func beginStroke() {
        guard interactionMode == .sculpt, !isGizmoDragging else { return }
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
        guard interactionMode == .sculpt else { return }
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
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              (!isFaceExtrudeRunning && !isFaceInsetRunning && !isFaceBevelRunning
                && !isMeshMirrorRunning && !isMeshLinearArrayRunning
                && !isMeshRadialArrayRunning)
                || isTopologyEditSnapshotSafe else {
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

            #if DEBUG
            if let activeBenchmark = benchmarkTask {
                cancelBenchmarks()
                await activeBenchmark.value
            }
            #endif

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
            projectMutationGeneration = recovery.descriptor.sourceGeneration
            lastSavedGeneration = MutationGeneration(value: projectMutationGeneration.value)
            if lastSavedGeneration == projectMutationGeneration { lastSavedGeneration.advance() }
            saveState = .autosaved(recovery.descriptor.capturedAt)
            recoveryDescriptor = recovery.descriptor
            recoveryInspectionError = nil
            isRecoveryPromptPresented = false
            hoverLocation = nil
            #if DEBUG
            benchmarkPreset = nil
            benchmarkProgress = 0
            lastBenchmarkReport = nil
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

    var selectedFaceCount: Int { faceSelection.matches(mesh) ? faceSelection.selectedCount : 0 }
    var totalFaceCount: Int { mesh.indices.count.isMultiple(of: 3) ? mesh.indices.count / 3 : 0 }
    var selectedEdgeCount: Int {
        guard let table = meshEdgeTable, edgeSelection.matches(table) else { return 0 }
        return edgeSelection.selectedCount
    }
    var totalEdgeCount: Int { meshEdgeTable?.edges.count ?? 0 }

    var isEdgeSelectionInteractionEnabled: Bool {
        guard interactionMode == .edgeSelect,
              let table = meshEdgeTable,
              table.matches(mesh),
              edgeSelection.matches(table),
              !isFaceSelectionProcessing,
              !isStrokeActive,
              !isGizmoDragging,
              !isTransformPanelEditing,
              !isSTLImporting,
              !isMeshDiagnosticsRunning,
              !isMeshCleanupRunning,
              !isTopologyEditRunning,
              !isRecoveryOperationInProgress,
              !isRecoveryPromptPresented else { return false }
        #if DEBUG
        return !isBenchmarkRunning
        #else
        return true
        #endif
    }

    var isFaceSelectionInteractionEnabled: Bool {
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh),
              !isFaceSelectionProcessing,
              !isStrokeActive,
              !isGizmoDragging,
              !isTransformPanelEditing,
              !isSTLImporting,
              !isMeshDiagnosticsRunning,
              !isMeshCleanupRunning,
              !isFaceExtrudeRunning,
              !isFaceInsetRunning,
              !isFaceBevelRunning,
              !isMeshMirrorRunning,
              !isMeshLinearArrayRunning,
              !isMeshRadialArrayRunning,
              !isRecoveryOperationInProgress,
              !isRecoveryPromptPresented else { return false }
        #if DEBUG
        return !isBenchmarkRunning
        #else
        return true
        #endif
    }

    var canBeginFaceExtrude: Bool {
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh),
              faceSelection.selectedCount > 0,
              !isFaceSelectionProcessing,
              !isStrokeActive,
              !isGizmoDragging,
              !isTransformPanelEditing,
              !isSTLImporting,
              !isMeshDiagnosticsRunning,
              !isMeshCleanupRunning,
              !isFaceExtrudeRunning,
              !isFaceInsetRunning,
              !isFaceBevelRunning,
              !isMeshMirrorRunning,
              !isMeshLinearArrayRunning,
              !isMeshRadialArrayRunning,
              !isRecoveryOperationInProgress,
              !isRecoveryPromptPresented else { return false }
        #if DEBUG
        return !isBenchmarkRunning
        #else
        return true
        #endif
    }

    var canBeginFaceInset: Bool {
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh),
              faceSelection.selectedCount > 0,
              !isFaceSelectionProcessing,
              !isStrokeActive,
              !isGizmoDragging,
              !isTransformPanelEditing,
              !isSTLImporting,
              !isMeshDiagnosticsRunning,
              !isMeshCleanupRunning,
              !isFaceExtrudeRunning,
              !isFaceInsetRunning,
              !isFaceBevelRunning,
              !isMeshMirrorRunning,
              !isMeshLinearArrayRunning,
              !isMeshRadialArrayRunning,
              !isRecoveryOperationInProgress,
              !isRecoveryPromptPresented else { return false }
        #if DEBUG
        return !isBenchmarkRunning
        #else
        return true
        #endif
    }

    var canBeginFaceBevel: Bool {
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh),
              faceSelection.selectedCount > 0,
              !isFaceSelectionProcessing,
              !isStrokeActive,
              !isGizmoDragging,
              !isTransformPanelEditing,
              !isSTLImporting,
              !isMeshDiagnosticsRunning,
              !isMeshCleanupRunning,
              !isFaceExtrudeRunning,
              !isFaceInsetRunning,
              !isFaceBevelRunning,
              !isMeshMirrorRunning,
              !isMeshLinearArrayRunning,
              !isMeshRadialArrayRunning,
              !isRecoveryOperationInProgress,
              !isRecoveryPromptPresented else { return false }
        #if DEBUG
        return !isBenchmarkRunning
        #else
        return true
        #endif
    }

    func setInteractionMode(_ mode: WorkspaceInteractionMode) {
        guard mode != interactionMode else { return }
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        commitTransformPanelTransaction()
        cancelStroke()
        cancelAllGizmoDrags()
        cancelFaceSelectionProcessing()
        discardFaceExtrudePreview()
        discardFaceInsetPreview()
        discardFaceBevelPreview()
        discardMeshMirrorPreview()
        discardMeshLinearArrayPreview()
        discardMeshRadialArrayPreview()
        discardMeshSeamEditPreview()
        hoverLocation = nil
        interactionMode = mode
        faceSelectionError = nil
        edgeSelectionError = nil
        hoveredEdgeID = nil
        switch mode {
        case .sculpt: status = "Sculpt mode"
        case .faceSelect: status = "Face Select mode"
        case .edgeSelect: status = "Edge Select mode"
        }
    }

    func setFaceSelectionOperation(_ operation: FaceSelectionOperation) {
        guard operation != faceSelectionOperation else { return }
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        faceSelectionOperation = operation
        faceSelectionError = nil
    }

    func setEdgeSelectionOperation(_ operation: EdgeSelectionOperation) {
        guard operation != edgeSelectionOperation else { return }
        #if DEBUG
        guard !isBenchmarkRunning else { return }
        #endif
        edgeSelectionOperation = operation
        edgeSelectionError = nil
    }

    @discardableResult
    func selectEdge(
        fromWorldRay ray: Ray,
        screenPoint: CGPoint,
        viewportSize: CGSize,
        viewProjection: simd_float4x4
    ) -> Bool {
        guard isEdgeSelectionInteractionEnabled, let table = meshEdgeTable else {
            reportEdgeSelectionError(EdgeSelectionError.unavailable)
            return false
        }
        switch MeshEdgePicker.pick(
            worldRay: ray, screenPoint: screenPoint, viewportSize: viewportSize,
            mesh: mesh, transform: objectTransform, viewProjection: viewProjection,
            table: table, cache: pickingCache) {
        case .hit(let edgeID, _):
            return applyEdgeSelectionHit(edgeID)
        case .miss:
            edgeSelectionError = nil
            return false
        case .unavailable:
            reportEdgeSelectionError(EdgeSelectionError.unavailable)
            return false
        }
    }

    func updateEdgeHover(
        fromWorldRay ray: Ray?,
        screenPoint: CGPoint?,
        viewportSize: CGSize,
        viewProjection: simd_float4x4
    ) {
        guard let ray, let screenPoint, isEdgeSelectionInteractionEnabled,
              let table = meshEdgeTable else {
            hoveredEdgeID = nil
            return
        }
        if case .hit(let edgeID, _) = MeshEdgePicker.pick(
            worldRay: ray, screenPoint: screenPoint, viewportSize: viewportSize,
            mesh: mesh, transform: objectTransform, viewProjection: viewProjection,
            table: table, cache: pickingCache) {
            hoveredEdgeID = edgeID
        } else {
            hoveredEdgeID = nil
        }
    }

    func clearEdgeHover() {
        hoveredEdgeID = nil
    }

    func handleEdgeSelectionOverlayUpdate(_ result: EdgeSelectionOverlayUpdateResult) {
        switch result {
        case .unchanged:
            break
        case .updated:
            if edgeSelectionError?.hasPrefix("Edge overlay:") == true {
                edgeSelectionError = nil
            }
        case .unavailable(let error):
            let message = "Edge overlay: \(error.localizedDescription)"
            guard edgeSelectionError != message else { return }
            edgeSelectionError = message
            status = message
        }
    }

    @discardableResult
    func applyEdgeSelectionHit(_ edgeID: Int) -> Bool {
        guard isEdgeSelectionInteractionEnabled, let table = meshEdgeTable,
              edgeSelection.matches(table) else {
            reportEdgeSelectionError(EdgeSelectionError.unavailable)
            return false
        }
        do {
            var updated = edgeSelection
            guard try updated.apply(edgeSelectionOperation, edgeID: edgeID) else {
                edgeSelectionError = nil
                return false
            }
            commitEdgeSelection(updated)
            return true
        } catch {
            reportEdgeSelectionError(error)
            return false
        }
    }

    func clearEdgeSelection() { mutateEdgeSelection { $0.clear() } }
    func selectAllEdges() { mutateEdgeSelection { $0.selectAll() } }
    func invertEdgeSelection() { mutateEdgeSelection { $0.invert() } }

    func selectConnectedEdges() {
        guard isEdgeSelectionInteractionEnabled, let table = meshEdgeTable,
              edgeSelection.matches(table), edgeSelection.selectedCount > 0 else { return }
        do {
            let connected = try EdgeSelectionConnectivity.connectedEdgeIDs(
                table: table, seeds: edgeSelection.selectedEdgeIDs())
            var updated = edgeSelection
            if try updated.formUnion(connected) { commitEdgeSelection(updated) }
        } catch {
            reportEdgeSelectionError(error)
        }
    }

    @discardableResult
    func selectFace(fromWorldRay ray: Ray) -> Bool {
        guard isFaceSelectionInteractionEnabled else {
            reportFaceSelectionError(FaceSelectionError.unavailable)
            return false
        }
        guard let localRay = objectTransform.localRay(fromWorld: ray) else {
            reportFaceSelectionError(FaceSelectionError.invalidMesh)
            return false
        }
        switch MeshPicker.indexedHit(ray: localRay, mesh: mesh, culling: .none,
                                     profiler: profiler, cache: pickingCache) {
        case .hit(let hit):
            return applyFaceSelectionHit(hit.triangleIndex)
        case .miss:
            return applyFaceSelectionHit(nil)
        case .unavailable:
            reportFaceSelectionError(FaceSelectionError.staleTopology)
            return false
        }
    }

    @discardableResult
    func applyFaceSelectionHit(_ faceID: Int?) -> Bool {
        guard isFaceSelectionInteractionEnabled else {
            reportFaceSelectionError(FaceSelectionError.unavailable)
            return false
        }
        do {
            var updated = faceSelection
            let changed: Bool
            switch faceSelectionOperation {
            case .replace:
                changed = try updated.replace(with: faceID)
            case .add:
                if let faceID { changed = try updated.set(faceID, selected: true) }
                else { changed = false }
            case .remove:
                if let faceID { changed = try updated.set(faceID, selected: false) }
                else { changed = false }
            case .toggle:
                if let faceID { changed = try updated.toggle(faceID) }
                else { changed = false }
            }
            if changed { commitFaceSelection(updated) }
            else { faceSelectionError = nil }
            return changed
        } catch {
            reportFaceSelectionError(error)
            return false
        }
    }

    func clearFaceSelection() {
        mutateFaceSelection { $0.clear() }
    }

    func selectAllFaces() {
        mutateFaceSelection { $0.selectAll() }
    }

    func invertFaceSelection() {
        mutateFaceSelection { $0.invert() }
    }

    func selectConnectedFaces() {
        guard isFaceSelectionInteractionEnabled else {
            reportFaceSelectionError(FaceSelectionError.unavailable)
            return
        }
        guard faceSelection.selectedCount > 0 else { return }
        let sourceMesh = mesh
        let sourceSelection = faceSelection
        isFaceSelectionProcessing = true
        faceSelectionError = nil
        let taskID = UUID()
        faceSelectionTaskID = taskID
        faceSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.faceSelectionTaskID == taskID {
                    self.isFaceSelectionProcessing = false
                    self.faceSelectionTask = nil
                    self.faceSelectionTaskID = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard !self.isStrokeActive, !self.isGizmoDragging,
                  self.mesh.runtime.topologyID == sourceMesh.runtime.topologyID,
                  self.mesh.runtime.topologyRevision == sourceMesh.runtime.topologyRevision,
                  self.mesh.indices.count == sourceMesh.indices.count,
                  self.faceSelection == sourceSelection else {
                self.reportFaceSelectionError(FaceSelectionError.activeEdit)
                return
            }
            do {
                let connected = try FaceSelectionConnectivity.connectedFaceIDs(
                    mesh: sourceMesh, seeds: sourceSelection.selectedFaceIDs())
                guard !Task.isCancelled else { return }
                var updated = sourceSelection
                if try updated.formUnion(connected) { self.commitFaceSelection(updated) }
            } catch {
                self.reportFaceSelectionError(error)
            }
        }
    }

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
        discardMeshMirrorPreview()
        discardMeshLinearArrayPreview()
        discardMeshRadialArrayPreview()
        hoverLocation = nil
    }

    func prepareForFaceExtrude() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceExtrudeError.operationInProgress }
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh), faceSelection.selectedCount > 0,
              !isSTLImporting, !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceExtrudeError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    @discardableResult
    func previewFaceExtrude(options: FaceExtrudeOptions) throws -> FaceExtrudePreview {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceExtrudeError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceExtrudeError.activeEdit
        }
        faceExtrudePreview = nil
        faceExtrudeError = nil
        isFaceExtrudeRunning = true
        defer { isFaceExtrudeRunning = false }
        do {
            let preview = try FaceExtrude.makePreview(
                mesh: mesh,
                selection: faceSelection,
                transform: objectTransform,
                options: options,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion
            )
            faceExtrudePreview = preview
            faceExtrudeError = nil
            return preview
        } catch {
            reportFaceExtrudeError(error)
            throw error
        }
    }

    var isFaceExtrudePreviewStale: Bool {
        guard let preview = faceExtrudePreview else { return false }
        return !isFaceExtrudePreviewCurrent(preview)
    }

    func isFaceExtrudePreviewCurrent(_ preview: FaceExtrudePreview) -> Bool {
        faceExtrudePreview == preview && preview.source.matches(
            mesh: mesh,
            selection: faceSelection,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: preview.options
        )
    }

    @discardableResult
    func applyFaceExtrude(preview: FaceExtrudePreview) throws -> FaceExtrudeResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceExtrudeError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceExtrudeError.activeEdit
        }
        guard faceExtrudePreview == preview,
              preview.source.matches(
                mesh: mesh,
                selection: faceSelection,
                transform: objectTransform,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion,
                options: preview.options
              ) else { throw FaceExtrudeError.stalePreview }

        isFaceExtrudeRunning = true
        defer { isFaceExtrudeRunning = false }
        do {
            let prepared = try prepareFaceExtrudeCommit(preview: preview)
            return commitFaceExtrude(prepared, options: preview.options)
        } catch {
            reportFaceExtrudeError(error)
            throw error
        }
    }

    private func prepareFaceExtrudeCommit(
        preview: FaceExtrudePreview
    ) throws -> PreparedFaceExtrudeCommit {
        let result = try FaceExtrude.extrude(
            mesh: mesh, selection: faceSelection,
            transform: objectTransform, options: preview.options)
        guard result.estimate == preview.estimate,
              result.analysisFingerprint == preview.source.analysisFingerprint else {
            throw FaceExtrudeError.stalePreview
        }
        return PreparedFaceExtrudeCommit(
            result: result,
            before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitFaceExtrude(
        _ prepared: PreparedFaceExtrudeCommit,
        options: FaceExtrudeOptions
    ) -> FaceExtrudeResult {
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count,
                                   triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordFaceExtrudeReplacement(command)
        meshDiagnosticsCache.invalidate()
        meshDiagnosticsNeedsRefresh = meshDiagnosticsReport != nil
        meshDiagnosticsError = nil
        meshDiagnosticsOverlayRevision &+= 1
        faceExtrudePreview = nil
        faceExtrudeError = nil
        status = "Extruded \(result.estimate.selectedFaceCount) faces by \(options.distanceMillimeters) mm"
        return result
    }

    private func recordFaceExtrudeReplacement(_ command: ReplaceMeshCommand) {
        precondition(isFaceExtrudeRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardFaceExtrudePreview() {
        guard !isFaceExtrudeRunning else { return }
        faceExtrudePreview = nil
        faceExtrudeError = nil
    }

    private func reportFaceExtrudeError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        faceExtrudeError = message
        status = "Extrude failed: \(message)"
    }

    func prepareForFaceInset() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceInsetError.operationInProgress }
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh), faceSelection.selectedCount > 0,
              !isSTLImporting, !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceInsetError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    @discardableResult
    func previewFaceInset(options: FaceInsetOptions) throws -> FaceInsetPreview {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceInsetError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceInsetError.activeEdit
        }
        faceInsetPreview = nil
        faceInsetError = nil
        isFaceInsetRunning = true
        defer { isFaceInsetRunning = false }
        do {
            let preview = try FaceInset.makePreview(
                mesh: mesh, selection: faceSelection, transform: objectTransform,
                options: options, meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion)
            faceInsetPreview = preview
            return preview
        } catch {
            reportFaceInsetError(error)
            throw error
        }
    }

    var isFaceInsetPreviewStale: Bool {
        guard let preview = faceInsetPreview else { return false }
        return !isFaceInsetPreviewCurrent(preview)
    }

    func isFaceInsetPreviewCurrent(_ preview: FaceInsetPreview) -> Bool {
        faceInsetPreview == preview && preview.source.matches(
            mesh: mesh, selection: faceSelection, transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: preview.options)
    }

    @discardableResult
    func applyFaceInset(preview: FaceInsetPreview) throws -> FaceInsetResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceInsetError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceInsetError.activeEdit
        }
        guard faceInsetPreview == preview,
              preview.source.matches(
                mesh: mesh, selection: faceSelection, transform: objectTransform,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion,
                options: preview.options) else { throw FaceInsetError.stalePreview }

        isFaceInsetRunning = true
        defer { isFaceInsetRunning = false }
        do {
            let prepared = try prepareFaceInsetCommit(preview: preview)
            return commitFaceInset(prepared, options: preview.options)
        } catch {
            reportFaceInsetError(error)
            throw error
        }
    }

    private func prepareFaceInsetCommit(preview: FaceInsetPreview) throws -> PreparedFaceInsetCommit {
        let result = try FaceInset.inset(
            mesh: mesh, selection: faceSelection,
            transform: objectTransform, options: preview.options)
        guard result.estimate == preview.estimate,
              result.analysisFingerprint == preview.source.analysisFingerprint else {
            throw FaceInsetError.stalePreview
        }
        return PreparedFaceInsetCommit(
            result: result, before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitFaceInset(
        _ prepared: PreparedFaceInsetCommit, options: FaceInsetOptions
    ) -> FaceInsetResult {
        // Geometry, validation, bounds, and BVH preparation must remain in the
        // throwing prepared phase. Everything after mesh installation is required
        // to stay nonthrowing so a partial topology commit cannot escape.
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count,
                                   triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordFaceInsetReplacement(command)
        clearMeshDiagnostics()
        faceInsetPreview = nil
        faceInsetError = nil
        status = "Inset \(result.estimate.selectedFaceCount) faces by \(options.distanceMillimeters) mm"
        return result
    }

    private func recordFaceInsetReplacement(_ command: ReplaceMeshCommand) {
        precondition(isFaceInsetRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardFaceInsetPreview() {
        guard !isFaceInsetRunning else { return }
        faceInsetPreview = nil
        faceInsetError = nil
    }

    private func reportFaceInsetError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        faceInsetError = message
        status = "Inset failed: \(message)"
    }

    func prepareForFaceBevel() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceBevelError.operationInProgress }
        guard interactionMode == .faceSelect,
              faceSelection.matches(mesh), faceSelection.selectedCount > 0,
              !isSTLImporting, !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceBevelError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    @discardableResult
    func previewFaceBevel(options: FaceBevelOptions) throws -> FaceBevelPreview {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceBevelError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceBevelError.activeEdit
        }
        faceBevelPreview = nil
        faceBevelError = nil
        isFaceBevelRunning = true
        defer { isFaceBevelRunning = false }
        do {
            let preview = try FaceBevel.makePreview(
                mesh: mesh,
                selection: faceSelection,
                transform: objectTransform,
                options: options,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion)
            faceBevelPreview = preview
            return preview
        } catch {
            reportFaceBevelError(error)
            throw error
        }
    }

    var isFaceBevelPreviewStale: Bool {
        guard let preview = faceBevelPreview else { return false }
        return !isFaceBevelPreviewCurrent(preview)
    }

    func isFaceBevelPreviewCurrent(_ preview: FaceBevelPreview) -> Bool {
        faceBevelPreview == preview && preview.source.matches(
            mesh: mesh,
            selection: faceSelection,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: preview.options)
    }

    @discardableResult
    func applyFaceBevel(preview: FaceBevelPreview) throws -> FaceBevelResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw FaceBevelError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw FaceBevelError.activeEdit
        }
        guard faceBevelPreview == preview,
              preview.source.matches(
                mesh: mesh,
                selection: faceSelection,
                transform: objectTransform,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion,
                options: preview.options) else {
            throw FaceBevelError.stalePreview
        }

        isFaceBevelRunning = true
        defer { isFaceBevelRunning = false }
        do {
            let prepared = try prepareFaceBevelCommit(preview: preview)
            return commitFaceBevel(prepared, options: preview.options)
        } catch {
            reportFaceBevelError(error)
            throw error
        }
    }

    private func prepareFaceBevelCommit(
        preview: FaceBevelPreview
    ) throws -> PreparedFaceBevelCommit {
        let result = try FaceBevel.bevel(
            mesh: mesh,
            selection: faceSelection,
            transform: objectTransform,
            options: preview.options)
        guard result.estimate == preview.estimate,
              result.analysisFingerprint == preview.source.analysisFingerprint else {
            throw FaceBevelError.stalePreview
        }
        return PreparedFaceBevelCommit(
            result: result,
            before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitFaceBevel(
        _ prepared: PreparedFaceBevelCommit,
        options: FaceBevelOptions
    ) -> FaceBevelResult {
        // Geometry, validation, bounds, and BVH preparation must remain in the
        // throwing prepared phase. History recording is currently nonthrowing;
        // a fallible replacement must be preflighted or gain rollback first.
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(
            vertexCount: mesh.vertices.count,
            triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordFaceBevelReplacement(command)
        clearMeshDiagnostics()
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        status = "Beveled \(result.estimate.selectedFaceCount) faces: "
            + "\(options.widthMillimeters) mm width, \(options.heightMillimeters) mm height"
        return result
    }

    private func recordFaceBevelReplacement(_ command: ReplaceMeshCommand) {
        precondition(isFaceBevelRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardFaceBevelPreview() {
        guard !isFaceBevelRunning else { return }
        faceBevelPreview = nil
        faceBevelError = nil
    }

    private func reportFaceBevelError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        faceBevelError = message
        status = "Bevel failed: \(message)"
    }

    func prepareForMeshMirror() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshMirrorError.operationInProgress }
        guard !isSTLImporting, !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshMirrorError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    @discardableResult
    func previewMeshMirror(options: MeshMirrorOptions) throws -> MeshMirrorPreview {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshMirrorError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshMirrorError.activeEdit
        }
        meshMirrorPreview = nil
        meshMirrorError = nil
        isMeshMirrorRunning = true
        defer { isMeshMirrorRunning = false }
        do {
            let preview = try MeshMirror.makePreview(
                mesh: mesh,
                transform: objectTransform,
                options: options,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion)
            meshMirrorPreview = preview
            return preview
        } catch {
            reportMeshMirrorError(error)
            throw error
        }
    }

    var isMeshMirrorPreviewStale: Bool {
        guard let preview = meshMirrorPreview else { return false }
        return !isMeshMirrorPreviewCurrent(preview)
    }

    func isMeshMirrorPreviewCurrent(_ preview: MeshMirrorPreview) -> Bool {
        meshMirrorPreview == preview && preview.source.matches(
            mesh: mesh,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: preview.options)
    }

    @discardableResult
    func applyMeshMirror(preview: MeshMirrorPreview) throws -> MeshMirrorResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshMirrorError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshMirrorError.activeEdit
        }
        guard meshMirrorPreview == preview,
              preview.source.matches(
                mesh: mesh,
                transform: objectTransform,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion,
                options: preview.options) else {
            throw MeshMirrorError.stalePreview
        }

        isMeshMirrorRunning = true
        defer { isMeshMirrorRunning = false }
        do {
            let prepared = try prepareMeshMirrorCommit(preview: preview)
            return commitMeshMirror(prepared, options: preview.options)
        } catch {
            reportMeshMirrorError(error)
            throw error
        }
    }

    private func prepareMeshMirrorCommit(
        preview: MeshMirrorPreview
    ) throws -> PreparedMeshMirrorCommit {
        let result = try MeshMirror.mirror(
            mesh: mesh,
            transform: objectTransform,
            options: preview.options)
        guard result.estimate == preview.estimate,
              result.analysisFingerprint == preview.source.analysisFingerprint else {
            throw MeshMirrorError.stalePreview
        }
        return PreparedMeshMirrorCommit(
            result: result,
            before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitMeshMirror(
        _ prepared: PreparedMeshMirrorCommit,
        options: MeshMirrorOptions
    ) -> MeshMirrorResult {
        // Geometry, validation, adjacency, bounds, snapshots, and BVH preparation
        // must remain in the throwing phase. Everything after this installation
        // is required to stay nonthrowing so a partial topology commit cannot escape.
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(
            vertexCount: mesh.vertices.count,
            triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordMeshMirrorReplacement(command)
        clearMeshDiagnostics()
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
        status = "Mirrored across local \(options.axis.rawValue) = 0"
        return result
    }

    private func recordMeshMirrorReplacement(_ command: ReplaceMeshCommand) {
        precondition(isMeshMirrorRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardMeshMirrorPreview() {
        guard !isMeshMirrorRunning else { return }
        meshMirrorPreview = nil
        meshMirrorError = nil
    }

    private func reportMeshMirrorError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        meshMirrorError = message
        status = "Mirror failed: \(message)"
    }

    func prepareForMeshLinearArray() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshLinearArrayError.operationInProgress }
        guard !isSTLImporting, !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshLinearArrayError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    @discardableResult
    func previewMeshLinearArray(
        options: MeshLinearArrayOptions
    ) throws -> MeshLinearArrayPreview {
        let requestID = UUID()
        try beginMeshLinearArrayPreviewRequest(requestID)
        do {
            let candidate = try makeMeshLinearArrayPreviewCandidate(
                options: options,
                requestID: requestID)
            guard completeMeshLinearArrayPreviewRequest(
                requestID: requestID,
                candidate: candidate) else {
                throw MeshLinearArrayError.stalePreview
            }
            return candidate
        } catch {
            _ = failMeshLinearArrayPreviewRequest(requestID: requestID, error: error)
            throw error
        }
    }

    func beginMeshLinearArrayPreviewRequest(_ requestID: UUID) throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshLinearArrayError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshLinearArrayError.activeEdit
        }
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshLinearArrayPreviewRequestID = requestID
        isMeshLinearArrayRunning = true
    }

    func makeMeshLinearArrayPreviewCandidate(
        options: MeshLinearArrayOptions,
        requestID: UUID
    ) throws -> MeshLinearArrayPreview {
        guard isMeshLinearArrayRunning,
              meshLinearArrayPreviewRequestID == requestID else {
            throw MeshLinearArrayError.stalePreview
        }
        return try MeshLinearArray.makePreview(
            mesh: mesh,
            transform: objectTransform,
            options: options,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion)
    }

    @discardableResult
    func completeMeshLinearArrayPreviewRequest(
        requestID: UUID,
        candidate: MeshLinearArrayPreview
    ) -> Bool {
        guard isMeshLinearArrayRunning,
              meshLinearArrayPreviewRequestID == requestID else { return false }
        meshLinearArrayPreviewRequestID = nil
        isMeshLinearArrayRunning = false
        guard candidate.source.matchesRuntimeIdentity(
            mesh: mesh,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: candidate.options) else {
            meshLinearArrayPreview = nil
            reportMeshLinearArrayError(MeshLinearArrayError.stalePreview)
            return false
        }
        meshLinearArrayPreview = candidate
        meshLinearArrayError = nil
        return true
    }

    @discardableResult
    func failMeshLinearArrayPreviewRequest(
        requestID: UUID,
        error: Error
    ) -> Bool {
        guard meshLinearArrayPreviewRequestID == requestID else { return false }
        meshLinearArrayPreviewRequestID = nil
        isMeshLinearArrayRunning = false
        meshLinearArrayPreview = nil
        reportMeshLinearArrayError(error)
        return true
    }

    var isMeshLinearArrayPreviewStale: Bool {
        guard let preview = meshLinearArrayPreview else { return false }
        return !isMeshLinearArrayPreviewCurrent(preview)
    }

    func isMeshLinearArrayPreviewCurrent(_ preview: MeshLinearArrayPreview) -> Bool {
        meshLinearArrayPreview == preview && preview.source.matchesRuntimeIdentity(
            mesh: mesh,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: preview.options)
    }

    @discardableResult
    func applyMeshLinearArray(
        preview: MeshLinearArrayPreview
    ) throws -> MeshLinearArrayResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshLinearArrayError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshLinearArrayError.activeEdit
        }
        guard meshLinearArrayPreview == preview,
              preview.source.matchesRuntimeIdentity(
                mesh: mesh,
                transform: objectTransform,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion,
                options: preview.options) else {
            if meshLinearArrayPreview == preview { meshLinearArrayPreview = nil }
            throw MeshLinearArrayError.stalePreview
        }

        isMeshLinearArrayRunning = true
        defer { isMeshLinearArrayRunning = false }
        do {
            let prepared = try prepareMeshLinearArrayCommit(preview: preview)
            return commitMeshLinearArray(prepared, options: preview.options)
        } catch {
            if error as? MeshLinearArrayError == .stalePreview {
                meshLinearArrayPreview = nil
            }
            reportMeshLinearArrayError(error)
            throw error
        }
    }

    private func prepareMeshLinearArrayCommit(
        preview: MeshLinearArrayPreview
    ) throws -> PreparedMeshLinearArrayCommit {
        let result = try MeshLinearArray.array(
            mesh: mesh,
            transform: objectTransform,
            options: preview.options)
        guard result.estimate == preview.estimate,
              result.analysisFingerprint == preview.source.analysisFingerprint else {
            throw MeshLinearArrayError.stalePreview
        }
        return PreparedMeshLinearArrayCommit(
            result: result,
            before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitMeshLinearArray(
        _ prepared: PreparedMeshLinearArrayCommit,
        options: MeshLinearArrayOptions
    ) -> MeshLinearArrayResult {
        // All fallible geometry, validation, snapshots, and runtime preparation
        // must complete before this nonthrowing installation boundary.
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(
            vertexCount: mesh.vertices.count,
            triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordMeshLinearArrayReplacement(command)
        clearMeshDiagnostics()
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
        status = "Linear Array: \(options.count) copies along local \(options.axis.rawValue)"
        return result
    }

    private func recordMeshLinearArrayReplacement(_ command: ReplaceMeshCommand) {
        precondition(isMeshLinearArrayRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardMeshLinearArrayPreview(requestID: UUID? = nil) {
        if let requestID, meshLinearArrayPreviewRequestID != requestID { return }
        if meshLinearArrayPreviewRequestID != nil {
            meshLinearArrayPreviewRequestID = nil
            isMeshLinearArrayRunning = false
        }
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
    }

    private func reportMeshLinearArrayError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        meshLinearArrayError = message
        status = "Linear Array failed: \(message)"
    }

    func prepareForMeshRadialArray() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshRadialArrayError.operationInProgress }
        guard !isSTLImporting, !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshRadialArrayError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    @discardableResult
    func previewMeshRadialArray(options: MeshRadialArrayOptions) throws -> MeshRadialArrayPreview {
        let requestID = UUID()
        try beginMeshRadialArrayPreviewRequest(requestID)
        do {
            let candidate = try makeMeshRadialArrayPreviewCandidate(
                options: options, requestID: requestID)
            guard completeMeshRadialArrayPreviewRequest(
                requestID: requestID, candidate: candidate) else {
                throw MeshRadialArrayError.stalePreview
            }
            return candidate
        } catch {
            _ = failMeshRadialArrayPreviewRequest(requestID: requestID, error: error)
            throw error
        }
    }

    func beginMeshRadialArrayPreviewRequest(_ requestID: UUID) throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshRadialArrayError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshRadialArrayError.activeEdit
        }
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
        meshRadialArrayPreviewRequestID = requestID
        isMeshRadialArrayRunning = true
    }

    func makeMeshRadialArrayPreviewCandidate(
        options: MeshRadialArrayOptions,
        requestID: UUID
    ) throws -> MeshRadialArrayPreview {
        guard isMeshRadialArrayRunning,
              meshRadialArrayPreviewRequestID == requestID else {
            throw MeshRadialArrayError.stalePreview
        }
        return try MeshRadialArray.makePreview(
            mesh: mesh,
            transform: objectTransform,
            options: options,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion)
    }

    @discardableResult
    func completeMeshRadialArrayPreviewRequest(
        requestID: UUID,
        candidate: MeshRadialArrayPreview
    ) -> Bool {
        guard isMeshRadialArrayRunning,
              meshRadialArrayPreviewRequestID == requestID else { return false }
        meshRadialArrayPreviewRequestID = nil
        isMeshRadialArrayRunning = false
        guard candidate.source.matchesRuntimeIdentity(
            mesh: mesh,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: candidate.options) else {
            meshRadialArrayPreview = nil
            reportMeshRadialArrayError(MeshRadialArrayError.stalePreview)
            return false
        }
        meshRadialArrayPreview = candidate
        meshRadialArrayError = nil
        return true
    }

    @discardableResult
    func failMeshRadialArrayPreviewRequest(requestID: UUID, error: Error) -> Bool {
        guard meshRadialArrayPreviewRequestID == requestID else { return false }
        meshRadialArrayPreviewRequestID = nil
        isMeshRadialArrayRunning = false
        meshRadialArrayPreview = nil
        reportMeshRadialArrayError(error)
        return true
    }

    var isMeshRadialArrayPreviewStale: Bool {
        guard let preview = meshRadialArrayPreview else { return false }
        return !isMeshRadialArrayPreviewCurrent(preview)
    }

    func isMeshRadialArrayPreviewCurrent(_ preview: MeshRadialArrayPreview) -> Bool {
        meshRadialArrayPreview == preview && preview.source.matchesRuntimeIdentity(
            mesh: mesh,
            transform: objectTransform,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            options: preview.options)
    }

    @discardableResult
    func applyMeshRadialArray(preview: MeshRadialArrayPreview) throws -> MeshRadialArrayResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshRadialArrayError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshRadialArrayError.activeEdit
        }
        guard meshRadialArrayPreview == preview,
              preview.source.matchesRuntimeIdentity(
                mesh: mesh,
                transform: objectTransform,
                meshChangeVersion: topologyEditMeshChangeVersion,
                transformChangeVersion: topologyEditTransformChangeVersion,
                options: preview.options) else {
            if meshRadialArrayPreview == preview { meshRadialArrayPreview = nil }
            throw MeshRadialArrayError.stalePreview
        }

        isMeshRadialArrayRunning = true
        defer { isMeshRadialArrayRunning = false }
        do {
            let prepared = try prepareMeshRadialArrayCommit(preview: preview)
            return commitMeshRadialArray(prepared, options: preview.options)
        } catch {
            if error as? MeshRadialArrayError == .stalePreview {
                meshRadialArrayPreview = nil
            }
            reportMeshRadialArrayError(error)
            throw error
        }
    }

    private func prepareMeshRadialArrayCommit(
        preview: MeshRadialArrayPreview
    ) throws -> PreparedMeshRadialArrayCommit {
        let result = try MeshRadialArray.array(
            mesh: mesh, transform: objectTransform, options: preview.options)
        guard MeshRadialArray.preparedResultMatchesPreview(result, preview: preview) else {
            throw MeshRadialArrayError.stalePreview
        }
        return PreparedMeshRadialArrayCommit(
            result: result,
            before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitMeshRadialArray(
        _ prepared: PreparedMeshRadialArrayCommit,
        options: MeshRadialArrayOptions
    ) -> MeshRadialArrayResult {
        // Geometry, validation, snapshots, and runtime preparation must remain
        // before this nonthrowing installation boundary.
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(
            vertexCount: mesh.vertices.count,
            triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordMeshRadialArrayReplacement(command)
        clearMeshDiagnostics()
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
        status = "Radial Array: \(options.count) copies around local \(options.axis.rawValue)"
        return result
    }

    private func recordMeshRadialArrayReplacement(_ command: ReplaceMeshCommand) {
        precondition(isMeshRadialArrayRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardMeshRadialArrayPreview(requestID: UUID? = nil) {
        if let requestID, meshRadialArrayPreviewRequestID != requestID { return }
        if meshRadialArrayPreviewRequestID != nil {
            meshRadialArrayPreviewRequestID = nil
            isMeshRadialArrayRunning = false
        }
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
    }

    private func reportMeshRadialArrayError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        meshRadialArrayError = message
        status = "Radial Array failed: \(message)"
    }

    var canBeginMeshSeamEdit: Bool {
        interactionMode == .faceSelect && faceSelection.matches(mesh)
            && faceSelection.selectedCount > 0 && !isTopologyEditRunning
    }

    func prepareForMeshSeamEdit() throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshSeamEditError.operationInProgress }
        guard interactionMode == .faceSelect, faceSelection.matches(mesh),
              faceSelection.selectedCount > 0, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshSeamEditError.unavailable
        }
        cancelStroke()
        cancelAllGizmoDrags()
        commitTransformPanelTransaction()
        cancelFaceSelectionProcessing()
        hoverLocation = nil
        discardMeshSeamEditPreview()
    }

    func beginMeshSeamEditPreviewRequest(_ requestID: UUID) throws {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshSeamEditError.operationInProgress }
        guard interactionMode == .faceSelect, faceSelection.matches(mesh),
              faceSelection.selectedCount > 0, !isStrokeActive, !isGizmoDragging,
              !isTransformPanelEditing, !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshSeamEditError.activeEdit
        }
        meshSeamEditPreview = nil
        meshSeamEditError = nil
        meshSeamEditPreviewRequestID = requestID
        isMeshSeamEditRunning = true
    }

    func makeMeshSeamEditPreviewCandidate(
        operation: MeshSeamOperation,
        requestID: UUID
    ) throws -> MeshSeamEditPreview {
        guard isMeshSeamEditRunning,
              meshSeamEditPreviewRequestID == requestID else {
            throw MeshSeamEditError.stalePreview
        }
        return try MeshExactSeamEdit.makePreview(
            mesh: mesh, transform: objectTransform, selection: faceSelection,
            operation: operation, meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion)
    }

    @discardableResult
    func completeMeshSeamEditPreviewRequest(
        requestID: UUID,
        candidate: MeshSeamEditPreview
    ) -> Bool {
        guard isMeshSeamEditRunning,
              meshSeamEditPreviewRequestID == requestID else { return false }
        meshSeamEditPreviewRequestID = nil
        isMeshSeamEditRunning = false
        guard candidate.source.matchesRuntimeIdentity(
            mesh: mesh, transform: objectTransform, selection: faceSelection,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            operation: candidate.operation) else {
            meshSeamEditPreview = nil
            reportMeshSeamEditError(MeshSeamEditError.stalePreview)
            return false
        }
        meshSeamEditPreview = candidate
        meshSeamEditError = nil
        return true
    }

    @discardableResult
    func failMeshSeamEditPreviewRequest(requestID: UUID, error: Error) -> Bool {
        guard meshSeamEditPreviewRequestID == requestID else { return false }
        meshSeamEditPreviewRequestID = nil
        isMeshSeamEditRunning = false
        meshSeamEditPreview = nil
        reportMeshSeamEditError(error)
        return true
    }

    func isMeshSeamEditPreviewCurrent(_ preview: MeshSeamEditPreview) -> Bool {
        meshSeamEditPreview == preview && preview.source.matchesRuntimeIdentity(
            mesh: mesh, transform: objectTransform, selection: faceSelection,
            meshChangeVersion: topologyEditMeshChangeVersion,
            transformChangeVersion: topologyEditTransformChangeVersion,
            operation: preview.operation)
    }

    @discardableResult
    func applyMeshSeamEdit(preview: MeshSeamEditPreview) throws -> MeshSeamEditResult {
        #if DEBUG
        guard !isBenchmarkRunning else { throw WorkspaceError.benchmarkInProgress }
        #endif
        guard !isTopologyEditRunning else { throw MeshSeamEditError.operationInProgress }
        guard !isStrokeActive, !isGizmoDragging, !isTransformPanelEditing,
              !isFaceSelectionProcessing, !isSTLImporting,
              !isMeshDiagnosticsRunning, !isMeshCleanupRunning,
              !isRecoveryOperationInProgress, !isRecoveryPromptPresented else {
            throw MeshSeamEditError.activeEdit
        }
        guard isMeshSeamEditPreviewCurrent(preview) else {
            if meshSeamEditPreview == preview { meshSeamEditPreview = nil }
            throw MeshSeamEditError.stalePreview
        }
        isMeshSeamEditRunning = true
        defer { isMeshSeamEditRunning = false }
        do {
            let prepared = try prepareMeshSeamEditCommit(preview: preview)
            return commitMeshSeamEdit(prepared)
        } catch {
            if error as? MeshSeamEditError == .stalePreview { meshSeamEditPreview = nil }
            reportMeshSeamEditError(error)
            throw error
        }
    }

    private func prepareMeshSeamEditCommit(
        preview: MeshSeamEditPreview
    ) throws -> PreparedMeshSeamEditCommit {
        let result = try MeshExactSeamEdit.edit(
            mesh: mesh, transform: objectTransform, selection: faceSelection,
            operation: preview.operation)
        guard MeshExactSeamEdit.preparedResultMatchesPreview(result, preview: preview) else {
            throw MeshSeamEditError.stalePreview
        }
        return PreparedMeshSeamEditCommit(
            result: result, before: workspaceSnapshot,
            pickingIndex: try pickingCache.makeIndex(for: result.mesh))
    }

    private func commitMeshSeamEdit(
        _ prepared: PreparedMeshSeamEditCommit
    ) -> MeshSeamEditResult {
        // All fallible geometry, validation, snapshots, and runtime preparation
        // must remain before this nonthrowing installation boundary.
        let result = prepared.result
        mesh = result.mesh
        hoverLocation = nil
        #if DEBUG
        benchmarkPreset = nil
        #endif
        profiler?.updateMeshCounts(
            vertexCount: mesh.vertices.count,
            triangleCount: mesh.indices.count / 3)
        pickingCache.install(prepared.pickingIndex, for: mesh)
        sculptSpatialIndex.prepare(for: mesh)
        let command = ReplaceMeshCommand(before: prepared.before, after: workspaceSnapshot)
        recordMeshSeamEditReplacement(command)
        clearMeshDiagnostics()
        faceExtrudePreview = nil; faceExtrudeError = nil
        faceInsetPreview = nil; faceInsetError = nil
        faceBevelPreview = nil; faceBevelError = nil
        meshMirrorPreview = nil; meshMirrorError = nil
        meshLinearArrayPreview = nil; meshLinearArrayError = nil
        meshRadialArrayPreview = nil; meshRadialArrayError = nil
        meshSeamEditPreview = nil; meshSeamEditError = nil
        status = result.estimate.operation == .splitRegion
            ? "Split Region: opened \(result.estimate.seamEdgeCount) seam edges"
            : "Merge Exact Seam: welded \(result.estimate.seamVertexCount) vertices"
        return result
    }

    private func recordMeshSeamEditReplacement(_ command: ReplaceMeshCommand) {
        precondition(isMeshSeamEditRunning)
        isTopologyEditSnapshotSafe = true
        defer { isTopologyEditSnapshotSafe = false }
        record(.replaceMesh(command))
    }

    func discardMeshSeamEditPreview(requestID: UUID? = nil) {
        if let requestID, meshSeamEditPreviewRequestID != requestID { return }
        if meshSeamEditPreviewRequestID != nil {
            meshSeamEditPreviewRequestID = nil
            isMeshSeamEditRunning = false
        }
        meshSeamEditPreview = nil
        meshSeamEditError = nil
    }

    private func reportMeshSeamEditError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        meshSeamEditError = message
        status = "Merge / Split failed: \(message)"
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
            faceExtrudePreview = nil
            faceExtrudeError = nil
            faceInsetPreview = nil
            faceInsetError = nil
            faceBevelPreview = nil
            faceBevelError = nil
            meshMirrorPreview = nil
            meshMirrorError = nil
            meshLinearArrayPreview = nil
            meshLinearArrayError = nil
            meshRadialArrayPreview = nil
            meshRadialArrayError = nil
            meshSeamEditPreview = nil
            meshSeamEditError = nil
            mesh = snapshot.mesh
            objectTransform = snapshot.transform.sanitized()
            camera = snapshot.camera
            hoverLocation = nil
            profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
            if !pickingCache.rebuild(for: mesh) {
                status = "Mesh restored, but Picking is temporarily unavailable. The next pick will retry the index build."
            }
            sculptSpatialIndex.prepare(for: mesh)
            meshDiagnosticsCache.invalidate()
            meshDiagnosticsNeedsRefresh = meshDiagnosticsReport != nil
            meshDiagnosticsError = nil
            meshDiagnosticsOverlayRevision &+= 1
        }
    }

    private var workspaceSnapshot: WorkspaceMeshSnapshot {
        WorkspaceMeshSnapshot(mesh: mesh, transform: objectTransform, camera: camera)
    }

    private func reconcileFaceSelection(previousMesh: EditableMesh) {
        let topologyChanged = previousMesh.runtime.topologyID != mesh.runtime.topologyID
            || previousMesh.runtime.topologyRevision != mesh.runtime.topologyRevision
            || previousMesh.indices.count / 3 != mesh.indices.count / 3
            || !mesh.indices.count.isMultiple(of: 3)
        guard topologyChanged else { return }
        rebuildFaceSelectionForCurrentTopology()
    }

    private func reconcileEdgeSelection(previousMesh: EditableMesh) {
        let topologyChanged = previousMesh.runtime.topologyID != mesh.runtime.topologyID
            || previousMesh.runtime.topologyRevision != mesh.runtime.topologyRevision
            || previousMesh.indices.count != mesh.indices.count
        guard topologyChanged else { return }
        rebuildEdgeSelectionForCurrentTopology()
    }

    private func rebuildEdgeSelectionForCurrentTopology() {
        hoveredEdgeID = nil
        do {
            let table = try MeshEdgeTable.build(mesh: mesh)
            let selection = try EdgeSelection(table: table)
            meshEdgeTable = table
            edgeSelection = selection
            edgeSelectionError = nil
        } catch {
            meshEdgeTable = nil
            edgeSelection = EdgeSelection.unavailable(
                topologyID: mesh.runtime.topologyID,
                topologyRevision: mesh.runtime.topologyRevision)
            reportEdgeSelectionError(error)
        }
    }

    private func rebuildFaceSelectionForCurrentTopology() {
        cancelFaceSelectionProcessing()
        faceExtrudePreview = nil
        faceExtrudeError = nil
        faceInsetPreview = nil
        faceInsetError = nil
        faceBevelPreview = nil
        faceBevelError = nil
        meshMirrorPreview = nil
        meshMirrorError = nil
        meshLinearArrayPreview = nil
        meshLinearArrayError = nil
        meshRadialArrayPreview = nil
        meshRadialArrayError = nil
        meshSeamEditPreview = nil
        meshSeamEditError = nil
        let triangleCount = mesh.indices.count.isMultiple(of: 3) ? mesh.indices.count / 3 : -1
        do {
            faceSelection = try FaceSelection(
                sourceTopologyID: mesh.runtime.topologyID,
                sourceTopologyRevision: mesh.runtime.topologyRevision,
                triangleCount: triangleCount)
            faceSelectionError = nil
        } catch {
            faceSelection = FaceSelection.emptyUnavailable(
                sourceTopologyID: mesh.runtime.topologyID,
                sourceTopologyRevision: mesh.runtime.topologyRevision)
            reportFaceSelectionError(error)
        }
        isFaceSelectionProcessing = false
    }

    private func mutateFaceSelection(_ operation: (inout FaceSelection) throws -> Bool) {
        guard isFaceSelectionInteractionEnabled else {
            reportFaceSelectionError(FaceSelectionError.unavailable)
            return
        }
        do {
            var updated = faceSelection
            if try operation(&updated) { commitFaceSelection(updated) }
            else { faceSelectionError = nil }
        } catch {
            reportFaceSelectionError(error)
        }
    }

    private func commitFaceSelection(_ updated: FaceSelection) {
        faceSelection = updated
        discardMeshSeamEditPreview()
        faceSelectionError = nil
        status = "Selected \(updated.selectedCount) of \(updated.triangleCount) faces"
    }

    private func mutateEdgeSelection(_ operation: (inout EdgeSelection) throws -> Bool) {
        guard isEdgeSelectionInteractionEnabled, let table = meshEdgeTable,
              edgeSelection.matches(table) else {
            reportEdgeSelectionError(EdgeSelectionError.unavailable)
            return
        }
        do {
            var updated = edgeSelection
            if try operation(&updated) { commitEdgeSelection(updated) }
            else { edgeSelectionError = nil }
        } catch {
            reportEdgeSelectionError(error)
        }
    }

    private func commitEdgeSelection(_ updated: EdgeSelection) {
        edgeSelection = updated
        edgeSelectionError = nil
        status = "Selected \(updated.selectedCount) of \(updated.edgeCount) edges"
    }

    private func reportEdgeSelectionError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        edgeSelectionError = message
        status = "Edge selection: \(message)"
    }

    private func reportFaceSelectionError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        faceSelectionError = message
        status = "Face selection: \(message)"
    }

    private func cancelFaceSelectionProcessing() {
        faceSelectionTask?.cancel()
        faceSelectionTask = nil
        faceSelectionTaskID = nil
        isFaceSelectionProcessing = false
    }

    private func projectMutationDidCommit() {
        projectMutationGeneration.advance()
        saveState = .unsavedChanges
        scheduleAutosaveIfSafe()
    }

    #if DEBUG
    var isFaceExtrudeSnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var isFaceInsetSnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var isFaceBevelSnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var isMeshMirrorSnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var isMeshLinearArraySnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var isMeshRadialArraySnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var isMeshSeamEditSnapshotSafeForTesting: Bool { isTopologyEditSnapshotSafe }
    var pickingCacheHasIndexForTesting: Bool { pickingCache.bvh != nil }
    var pickingCacheTopologyIDForTesting: UUID? { pickingCache.topologyID }
    #endif

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

    func handleAutosaveResult(_ result: AutosaveScheduleResult) {
        switch result {
        case .started(let snapshot):
            if snapshot.sessionID == workspaceSessionID,
               snapshot.sourceGeneration == projectMutationGeneration {
                saveState = .autosaving
            }
        case .success(let snapshot, let descriptor):
            if snapshot.sessionID == workspaceSessionID,
               snapshot.sourceGeneration == projectMutationGeneration {
                recoveryDescriptor = descriptor
                recoveryInspectionError = nil
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
