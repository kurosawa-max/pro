import XCTest
import MetalKit
import simd
@testable import Forge3D

final class AutosaveRecoveryTests: XCTestCase {
    func testMutationGenerationAdvancesWithoutWrappingAtMaximum() {
        let identity = UUID()
        var generation = MutationGeneration(value: .max, overflowIdentity: identity)
        generation.advance()
        XCTAssertEqual(generation.value, .max)
        XCTAssertNotEqual(generation.overflowIdentity, identity)
        let firstOverflowIdentity = generation.overflowIdentity
        generation.advance()
        XCTAssertEqual(generation.value, .max)
        XCTAssertNotEqual(generation.overflowIdentity, firstOverflowIdentity)
        XCTAssertFalse(generation.isNotNewer(than: MutationGeneration(value: .max,
                                                                       overflowIdentity: identity)))
    }

    @MainActor
    func testDirtyStateTracksCommittedContentButIgnoresRuntimeOnlySettingsAndNoOps() throws {
        let model = WorkspaceModel()
        let initialGeneration = model.projectMutationGeneration
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.saveState, .saved)

        model.brush = .crease
        model.brushSettings.radius = 7
        model.symmetry = SculptSymmetry(x: true)
        model.meshDiagnosticsOverlayOptions.showsBoundaryEdges.toggle()
        _ = try model.analyzeCurrentMesh()
        model.updateTransform(.identity)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.projectMutationGeneration, initialGeneration)

        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        XCTAssertTrue(model.isDirty)
        XCTAssertNotEqual(model.projectMutationGeneration, initialGeneration)
        let committedGeneration = model.projectMutationGeneration
        model.undo()
        XCTAssertNotEqual(model.projectMutationGeneration, committedGeneration)
        let undoGeneration = model.projectMutationGeneration
        model.redo()
        XCTAssertNotEqual(model.projectMutationGeneration, undoGeneration)
    }

    @MainActor
    func testCancelledAndCommittedSculptAndGizmoHaveDifferentDirtySemantics() {
        let sample = PencilSample(location: .zero, force: 1, maximumForce: 1,
                                  altitude: 1, azimuth: 0, timestamp: 0)
        let sculptRay = Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1))
        let sculptModel = WorkspaceModel()
        let originalMesh = sculptModel.mesh
        sculptModel.beginStroke()
        sculptModel.updateStroke(sample: sample, ray: sculptRay)
        sculptModel.cancelStroke()
        XCTAssertEqual(sculptModel.mesh, originalMesh)
        XCTAssertFalse(sculptModel.isDirty)
        sculptModel.beginStroke()
        sculptModel.updateStroke(sample: sample, ray: sculptRay)
        sculptModel.endStroke()
        XCTAssertTrue(sculptModel.isDirty)

        let gizmoModel = WorkspaceModel()
        let start = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(gizmoModel.beginTranslationGizmoDrag(handle: .xyPlane, ray: start,
                                                            cameraDirection: SIMD3<Float>(0, 0, -1)))
        gizmoModel.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(0.8, 0.6, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        gizmoModel.cancelTranslationGizmoDrag()
        XCTAssertFalse(gizmoModel.isDirty)
        XCTAssertTrue(gizmoModel.beginTranslationGizmoDrag(handle: .xyPlane, ray: start,
                                                            cameraDirection: SIMD3<Float>(0, 0, -1)))
        gizmoModel.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(0.8, 0.6, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        gizmoModel.endTranslationGizmoDrag()
        XCTAssertTrue(gizmoModel.isDirty)
    }

    @MainActor
    func testTopologyReplacementOperationsAndCameraCommitBecomeDirty() throws {
        let primitive = WorkspaceModel()
        try primitive.createPrimitive(parameters: PrimitiveParameters(kind: .cube))
        XCTAssertTrue(primitive.isDirty)

        let subdivision = WorkspaceModel()
        try subdivision.subdivideMeshOnce()
        XCTAssertTrue(subdivision.isDirty)

        let imported = WorkspaceModel()
        let importedMesh = try PrimitiveMeshBuilder.cube(size: 4)
        let importResult = STLImportResult(
            mesh: importedMesh, format: .binary, sourceByteCount: 84 + importedMesh.indices.count / 3 * 50,
            sourceTriangleCount: importedMesh.indices.count / 3, weldedVertexCount: importedMesh.vertices.count,
            bounds: importedMesh.bounds,
            estimate: STLImportEstimate(sourceByteCount: 84 + importedMesh.indices.count / 3 * 50,
                                        sourceTriangleCount: importedMesh.indices.count / 3,
                                        maximumPossibleVertexCount: importedMesh.indices.count,
                                        estimatedWorkingByteCount: 1_024))
        try imported.installSTLImport(importResult, fileName: "cube.stl")
        XCTAssertTrue(imported.isDirty)

        let cleanup = WorkspaceModel()
        cleanup.mesh = cleanupSourceMesh()
        let preview = try cleanup.previewMeshCleanup(
            options: MeshCleanupOptions(removeIsolatedVertices: true))
        _ = try cleanup.applyMeshCleanup(preview: preview)
        XCTAssertTrue(cleanup.isDirty)

        let camera = WorkspaceModel()
        let before = camera.camera
        camera.camera.yaw += 0.25
        XCTAssertFalse(camera.isDirty)
        camera.commitCameraChange(from: before)
        XCTAssertTrue(camera.isDirty)
    }

    @MainActor
    func testSnapshotIsConsistentImmutableAndRejectsActiveEdits() throws {
        let model = WorkspaceModel()
        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        let snapshot = try model.makeAutosaveSnapshot(capturedAt: Date(timeIntervalSince1970: 100))
        let capturedMesh = snapshot.project.mesh
        let capturedTransform = snapshot.project.transform
        let capturedCamera = snapshot.project.camera
        let capturedHistory = model.undoCount

        model.updateScale(SIMD3<Float>(2, 3, 4))
        model.camera.yaw += 0.5
        XCTAssertEqual(snapshot.project.mesh, capturedMesh)
        XCTAssertEqual(snapshot.project.transform, capturedTransform)
        XCTAssertEqual(snapshot.project.camera, capturedCamera)
        XCTAssertEqual(model.undoCount, capturedHistory + 1)

        model.beginStroke()
        XCTAssertThrowsError(try model.makeAutosaveSnapshot()) {
            XCTAssertEqual($0 as? WorkspaceError, .activeEditInProgress)
        }
        model.cancelStroke()
        model.beginTransformPanelTransaction()
        XCTAssertThrowsError(try model.makeAutosaveSnapshot())
        XCTAssertNoThrow(try model.prepareExplicitSave())
        XCTAssertFalse(model.isTransformPanelEditing)
    }

    func testRecoveryCodecRoundTripMetadataChecksumAndLimits() throws {
        let snapshot = try makeSnapshot(name: "Ring", capturedAt: Date(timeIntervalSince1970: 123))
        let data = try ProjectRecoveryCodec.encode(snapshot)
        let recovery = try ProjectRecoveryCodec.decode(data)
        XCTAssertEqual(recovery.project, snapshot.project)
        XCTAssertEqual(recovery.descriptor.projectName, "Ring")
        XCTAssertEqual(recovery.descriptor.vertexCount, snapshot.project.mesh.vertices.count)
        XCTAssertEqual(recovery.descriptor.triangleCount, snapshot.project.mesh.indices.count / 3)
        XCTAssertEqual(recovery.descriptor.fileSize, data.count)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, snapshot.sourceGeneration)
        XCTAssertTrue(recovery.descriptor.dimensions.allFinite)

        var corrupted = data
        corrupted[corrupted.count - 1] ^= 0x01
        XCTAssertThrowsError(try ProjectRecoveryCodec.decode(corrupted)) {
            XCTAssertEqual($0 as? RecoveryStorageError, .checksumMismatch)
        }
        XCTAssertThrowsError(try ProjectRecoveryCodec.decode(Data())) {
            XCTAssertEqual($0 as? RecoveryStorageError, .empty)
        }
        XCTAssertThrowsError(try ProjectRecoveryCodec.decode(Data(data.dropLast())))
        XCTAssertThrowsError(try ProjectRecoveryCodec.validateProjectByteCount(
            ProjectRecoveryCodec.maximumProjectBytes + 1)) {
            XCTAssertEqual($0 as? RecoveryStorageError, .projectTooLarge)
        }
        XCTAssertThrowsError(try ProjectRecoveryCodec.validateRecoveryByteCount(
            ProjectRecoveryCodec.maximumRecoveryBytes + 1)) {
            XCTAssertEqual($0 as? RecoveryStorageError, .oversized)
        }
    }

    func testRecoveryCodecRejectsCorruptMetadataUnsupportedWrapperAndFormatVersion() throws {
        let snapshot = try makeSnapshot(name: "Metadata")
        let validData = try ProjectRecoveryCodec.encode(snapshot)
        var corruptedMetadata = validData
        corruptedMetadata[56] ^= 0x01
        XCTAssertThrowsError(try ProjectRecoveryCodec.decode(corruptedMetadata)) {
            XCTAssertEqual($0 as? RecoveryStorageError, .checksumMismatch)
        }

        var unsupportedWrapper = validData
        unsupportedWrapper[8] = 2
        XCTAssertThrowsError(try ProjectRecoveryCodec.decode(unsupportedWrapper)) {
            XCTAssertEqual($0 as? RecoveryStorageError, .unsupportedWrapper)
        }

        let futureProject = ForgeProject(formatVersion: 2, mesh: snapshot.project.mesh,
                                         camera: snapshot.project.camera)
        let futureSnapshot = ProjectAutosaveSnapshot(
            project: futureProject, sourceGeneration: snapshot.sourceGeneration,
            capturedAt: snapshot.capturedAt, sessionID: snapshot.sessionID,
            projectName: snapshot.projectName)
        XCTAssertThrowsError(try ProjectRecoveryCodec.decode(ProjectRecoveryCodec.encode(futureSnapshot))) {
            XCTAssertEqual($0 as? RecoveryStorageError, .invalidMetadata)
        }
    }

    func testRecoveryInspectionReportsMissingAndRejectsZeroByteFile() throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        XCTAssertThrowsError(try environment.storage.inspect()) {
            XCTAssertEqual($0 as? RecoveryStorageError, .missing)
        }
        try Data().write(to: environment.storage.recoveryURL)
        XCTAssertThrowsError(try environment.storage.inspect()) {
            XCTAssertEqual($0 as? RecoveryStorageError, .empty)
        }
    }

    func testAtomicWriteReplacesSameSessionAndRejectsDifferentSession() throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let first = try makeSnapshot(name: "First", sessionID: environment.sessionID,
                                     capturedAt: Date(timeIntervalSince1970: 1))
        let second = try makeSnapshot(name: "Second", sessionID: environment.sessionID,
                                      capturedAt: Date(timeIntervalSince1970: 2), translation: SIMD3<Float>(1, 0, 0))
        _ = try environment.storage.write(first)
        _ = try environment.storage.write(second)
        XCTAssertEqual(try environment.storage.inspect().project, second.project)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: environment.directory.path)
            .contains { $0.hasSuffix(".tmp") })

        let other = try makeSnapshot(name: "Other", sessionID: UUID(),
                                     capturedAt: Date(timeIntervalSince1970: 3))
        XCTAssertThrowsError(try environment.storage.write(other)) {
            XCTAssertEqual($0 as? RecoveryStorageError, .conflictingRecovery)
        }
        XCTAssertEqual(try environment.storage.inspect().project, second.project)
    }

    func testReplacementFailurePreservesPreviousRecoveryAndCleansTemporaryFile() throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let first = try makeSnapshot(name: "First", sessionID: environment.sessionID,
                                     capturedAt: Date(timeIntervalSince1970: 1))
        _ = try environment.storage.write(first)
        let originalData = try Data(contentsOf: environment.storage.recoveryURL)
        let failingStorage = ProjectRecoveryStorage(
            directoryURL: environment.directory,
            beforeReplacement: { throw TestFailure.injected })
        let second = try makeSnapshot(name: "Second", sessionID: environment.sessionID,
                                      capturedAt: Date(timeIntervalSince1970: 2), translation: SIMD3<Float>(2, 0, 0))
        XCTAssertThrowsError(try failingStorage.write(second))
        XCTAssertEqual(try Data(contentsOf: environment.storage.recoveryURL), originalData)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: environment.directory.path)
            .contains { $0.hasSuffix(".tmp") })
    }

    func testEncodeFailureDoesNotReplacePreviousRecovery() throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        _ = try environment.storage.write(try makeSnapshot(name: "Valid", sessionID: environment.sessionID))
        let originalData = try Data(contentsOf: environment.storage.recoveryURL)
        let invalidMesh = EditableMesh(
            vertices: [MeshVertex(position: SIMD3<Float>(.nan, 0, 0), normal: SIMD3<Float>(0, 1, 0))],
            indices: [0, 0, 0])
        let invalidSnapshot = ProjectAutosaveSnapshot(
            project: ForgeProject(mesh: invalidMesh, camera: CameraState()),
            sourceGeneration: MutationGeneration(), capturedAt: Date(),
            sessionID: environment.sessionID, projectName: "Invalid")
        XCTAssertThrowsError(try environment.storage.write(invalidSnapshot))
        XCTAssertEqual(try Data(contentsOf: environment.storage.recoveryURL), originalData)
    }

    func testDebounceKeepsOnlyLatestSnapshotWithoutRealTimeDelay() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let scheduler = ManualAutosaveDelayScheduler()
        let coordinator = ProjectAutosaveCoordinator(storage: environment.storage, scheduler: scheduler)
        let recorder = AutosaveResultRecorder()
        let first = try makeSnapshot(name: "First", sessionID: environment.sessionID,
                                     capturedAt: Date(timeIntervalSince1970: 1))
        let second = try makeSnapshot(name: "Second", sessionID: environment.sessionID,
                                      capturedAt: Date(timeIntervalSince1970: 2), translation: SIMD3<Float>(3, 0, 0))
        await coordinator.schedule(first) { result in Task { await recorder.receive(result) } }
        await waitUntil { await scheduler.waiterCount == 1 }
        await coordinator.schedule(second) { result in Task { await recorder.receive(result) } }
        await waitUntil { await scheduler.waiterCount == 2 }
        await scheduler.releaseAll()
        await waitUntil { await recorder.successCount == 1 }
        let successfulWriteCount = await coordinator.successfulWriteCount
        let inspectedProject = try await coordinator.inspectRecovery().project
        let failureCount = await recorder.failureCount
        XCTAssertEqual(successfulWriteCount, 1)
        XCTAssertEqual(inspectedProject, second.project)
        XCTAssertEqual(failureCount, 0)
    }

    @MainActor
    func testExplicitSaveBaselineAndConcurrentEditOrdering() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let coordinator = ProjectAutosaveCoordinator(storage: environment.storage)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        model.updateTranslation(SIMD3<Float>(1, 0, 0))
        let savedSnapshot = try model.prepareExplicitSave(capturedAt: Date(timeIntervalSince1970: 10))
        let didProtectSnapshot = await model.requestImmediateAutosave()
        XCTAssertTrue(didProtectSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))
        await model.explicitSaveSucceeded(savedSnapshot, url: environment.directory.appendingPathComponent("Ring.forge3d"))
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.currentProjectName, "Ring")
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))

        model.updateScale(SIMD3<Float>(repeating: 2))
        let olderSnapshot = try model.prepareExplicitSave(capturedAt: Date(timeIntervalSince1970: 20))
        model.updateTranslation(SIMD3<Float>(5, 0, 0))
        await model.explicitSaveSucceeded(olderSnapshot, url: environment.directory.appendingPathComponent("Ring.forge3d"))
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.lastSavedGeneration, olderSnapshot.sourceGeneration)
    }

    @MainActor
    func testExplicitSaveFailureAndCancellationPreserveRecoveryAndDirtyState() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let coordinator = ProjectAutosaveCoordinator(storage: environment.storage)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch()
        model.updateTranslation(SIMD3<Float>(1, 0, 0))
        let didAutosave = await model.requestImmediateAutosave()
        XCTAssertTrue(didAutosave)
        let recoveryData = try Data(contentsOf: environment.storage.recoveryURL)
        model.explicitSaveFailed(TestFailure.injected)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(try Data(contentsOf: environment.storage.recoveryURL), recoveryData)
        model.explicitSaveCancelled()
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(try Data(contentsOf: environment.storage.recoveryURL), recoveryData)
    }

    @MainActor
    func testLoadCreatesCleanBaselineAndFailureLeavesWorkspaceUnchanged() throws {
        let model = WorkspaceModel()
        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        let project = ForgeProject(mesh: try PrimitiveMeshBuilder.cube(size: 8),
                                   camera: CameraState(yaw: 0.8, pitch: 0.1, distance: 30, target: .zero),
                                   transform: ObjectTransform(translation: SIMD3<Float>(4, 5, 6)),
                                   metadata: ["name": "Loaded metadata"])
        try model.loadProject(data: ProjectCodec.encode(project), projectName: "Loaded")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.currentProjectName, "Loaded")
        XCTAssertEqual(try ProjectCodec.decode(model.projectData()).metadata, project.metadata)
        XCTAssertEqual(model.undoCount, 0)
        let before = try model.projectData()
        let generation = model.projectMutationGeneration
        XCTAssertThrowsError(try model.loadProject(data: Data([0, 1, 2]), projectName: "Broken"))
        XCTAssertEqual(try model.projectData(), before)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        model.updateScale(SIMD3<Float>(repeating: 2))
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testRecoverRestoresProjectWithFreshRuntimeCachesAndClearHistory() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let recoveredProject = ForgeProject(
            mesh: try PrimitiveMeshBuilder.cube(size: 12),
            camera: CameraState(yaw: 0.7, pitch: -0.2, distance: 40, target: SIMD3<Float>(1, 2, 3)),
            transform: ObjectTransform(translation: SIMD3<Float>(4, 5, 6),
                                       scale: SIMD3<Float>(2, 3, 4)),
            metadata: ["name": "Recovered metadata"])
        let snapshot = ProjectAutosaveSnapshot(project: recoveredProject,
                                               sourceGeneration: MutationGeneration(),
                                               capturedAt: Date(timeIntervalSince1970: 100),
                                               sessionID: environment.sessionID,
                                               projectName: "Recovered Ring")
        _ = try environment.storage.write(snapshot)
        let model = WorkspaceModel(autosaveCoordinator: ProjectAutosaveCoordinator(storage: environment.storage))
        model.updateTranslation(SIMD3<Float>(9, 9, 9))
        _ = try model.analyzeCurrentMesh()
        await model.inspectRecoveryOnLaunch()
        await model.recoverAutosave()
        XCTAssertEqual(model.mesh, recoveredProject.mesh)
        XCTAssertNotEqual(model.mesh.runtime.topologyID, recoveredProject.mesh.runtime.topologyID)
        XCTAssertEqual(model.objectTransform, recoveredProject.transform)
        XCTAssertEqual(model.camera, recoveredProject.camera)
        XCTAssertEqual(try ProjectCodec.decode(model.projectData()).metadata, recoveredProject.metadata)
        XCTAssertEqual(model.currentProjectName, "Recovered Ring")
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertNil(model.meshDiagnosticsReport)
        XCTAssertNil(model.lastMeshCleanupSummary)
        XCTAssertTrue(model.mesh.hasCachedAdjacency)
        XCTAssertEqual(model.pickingCacheBuildCount, 1)
        XCTAssertEqual(model.sculptSpatialIndexBuildCount, 1)
        XCTAssertEqual(try ProjectCodec.decode(model.projectData()).formatVersion, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))
    }

    @MainActor
    func testRecoveredMeshUploadsOnceThenSkipsUnchangedFrame() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let project = ForgeProject(mesh: try PrimitiveMeshBuilder.cube(size: 12), camera: CameraState())
        let snapshot = ProjectAutosaveSnapshot(
            project: project, sourceGeneration: MutationGeneration(), capturedAt: Date(),
            sessionID: environment.sessionID, projectName: "Recovered")
        _ = try environment.storage.write(snapshot)
        let model = WorkspaceModel(autosaveCoordinator: ProjectAutosaveCoordinator(storage: environment.storage))
        await model.inspectRecoveryOnLaunch()
        await model.recoverAutosave()

        let profiler = PerformanceProfiler()
        let view = MTKView()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        profiler.reset(vertexCount: model.mesh.vertices.count, triangleCount: model.mesh.indices.count / 3)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
    }

    @MainActor
    func testDiscardAndLaterKeepWorkspaceAtomic() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        _ = try environment.storage.write(try makeSnapshot(name: "Pending", sessionID: environment.sessionID))
        let model = WorkspaceModel(autosaveCoordinator: ProjectAutosaveCoordinator(storage: environment.storage))
        let before = try model.projectData()
        await model.inspectRecoveryOnLaunch()
        XCTAssertTrue(model.isRecoveryPromptPresented)
        model.postponeRecovery()
        XCTAssertFalse(model.isRecoveryPromptPresented)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))
        XCTAssertEqual(try model.projectData(), before)
        model.presentRecovery()
        XCTAssertTrue(model.isRecoveryPromptPresented)
        await model.discardRecovery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))
        XCTAssertEqual(try model.projectData(), before)
    }

    @MainActor
    func testLifecycleFlushesImmediatelyWithoutRealTimeDebounceAndDefersActiveEdit() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let coordinator = ProjectAutosaveCoordinator(storage: environment.storage)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch()
        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        model.beginStroke()
        await model.handleLifecycleInactiveOrBackground()
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))
        XCTAssertTrue(model.isDirty)
        model.cancelStroke()
        await model.handleLifecycleInactiveOrBackground()
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.storage.recoveryURL.path))
        XCTAssertEqual(try environment.storage.inspect().project, try ProjectCodec.decode(model.projectData()))
        await model.handleLifecycleInactiveOrBackground()
        let successfulWriteCount = await coordinator.successfulWriteCount
        XCTAssertEqual(successfulWriteCount, 1)
    }

    @MainActor
    func testSingleSlotConflictBlocksProjectLoadAndPreservesBothWorkspaces() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let otherSnapshot = try makeSnapshot(name: "Other", sessionID: environment.sessionID)
        _ = try environment.storage.write(otherSnapshot)
        let model = WorkspaceModel(autosaveCoordinator: ProjectAutosaveCoordinator(storage: environment.storage))
        model.updateTranslation(SIMD3<Float>(9, 0, 0))
        let currentProject = try model.projectData()
        await model.inspectRecoveryOnLaunch()
        XCTAssertTrue(model.hasRecoveryConflict)
        let canLoad = await model.prepareForProjectLoad()
        XCTAssertFalse(canLoad)
        XCTAssertEqual(try model.projectData(), currentProject)
        XCTAssertEqual(try environment.storage.inspect().project, otherSnapshot.project)
        XCTAssertTrue(model.isRecoveryPromptPresented)
    }

    @MainActor
    func testAutosaveFailureKeepsWorkspaceHistoryDirtyAndPreviousRecovery() async throws {
        let environment = try makeStorageEnvironment()
        defer { environment.cleanup() }
        let existing = try makeSnapshot(name: "Existing", sessionID: environment.sessionID)
        _ = try environment.storage.write(existing)
        let originalRecovery = try Data(contentsOf: environment.storage.recoveryURL)
        let failingStorage = ProjectRecoveryStorage(
            directoryURL: environment.directory,
            beforeReplacement: { throw TestFailure.injected })
        let model = WorkspaceModel(autosaveCoordinator: ProjectAutosaveCoordinator(storage: failingStorage))
        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        let beforeProject = try model.projectData()
        let beforeUndo = model.undoCount
        let beforeRuntime = model.mesh.runtime
        let beforeDiagnostics = try model.analyzeCurrentMesh()
        let beforeProfiler = model.profiler?.snapshot()
        let didAutosave = await model.requestImmediateAutosave()
        XCTAssertFalse(didAutosave)
        XCTAssertEqual(try model.projectData(), beforeProject)
        XCTAssertEqual(model.undoCount, beforeUndo)
        XCTAssertEqual(model.mesh.runtime, beforeRuntime)
        XCTAssertEqual(model.currentMeshDiagnosticsReport, beforeDiagnostics)
        XCTAssertEqual(model.profiler?.snapshot(), beforeProfiler)
        XCTAssertTrue(model.isDirty)
        if case .failed = model.saveState {} else { XCTFail("Expected failed autosave state") }
        XCTAssertEqual(try Data(contentsOf: environment.storage.recoveryURL), originalRecovery)
    }

    func testRecoveryWrapperPreservesFormatVersionOneForTransformedAndSubdividedMeshes() throws {
        var subdivided = EditableMesh.icosphere(subdivisions: 0)
        subdivided = try MeshSubdivision.subdivideOnce(subdivided)
        let imported = try STLImporter.importMesh(
            from: BinarySTLExporter.data(for: try PrimitiveMeshBuilder.cube(size: 20))).mesh
        let cleaned = try MeshCleanup.clean(
            mesh: cleanupSourceMesh(),
            options: MeshCleanupOptions(removeIsolatedVertices: true)).mesh
        let projects = [
            ForgeProject(mesh: subdivided, camera: CameraState()),
            ForgeProject(mesh: imported, camera: CameraState()),
            ForgeProject(mesh: cleaned, camera: CameraState()),
            ForgeProject(mesh: try PrimitiveMeshBuilder.cube(size: 20), camera: CameraState(),
                         transform: ObjectTransform(translation: SIMD3<Float>(1, 2, 3),
                                                    scale: SIMD3<Float>(2, 3, 4)))
        ]
        for project in projects {
            let snapshot = ProjectAutosaveSnapshot(project: project, sourceGeneration: MutationGeneration(),
                                                   capturedAt: Date(), sessionID: UUID(), projectName: "Project")
            let recovered = try ProjectRecoveryCodec.decode(ProjectRecoveryCodec.encode(snapshot))
            XCTAssertEqual(recovered.project.formatVersion, 1)
            XCTAssertEqual(recovered.project, project)
        }
    }

    private func makeSnapshot(name: String, sessionID: UUID = UUID(), capturedAt: Date = Date(),
                              translation: SIMD3<Float> = .zero) throws -> ProjectAutosaveSnapshot {
        let project = ForgeProject(mesh: try PrimitiveMeshBuilder.cube(size: 20),
                                   camera: CameraState(),
                                   transform: ObjectTransform(translation: translation))
        return ProjectAutosaveSnapshot(project: project, sourceGeneration: MutationGeneration(),
                                       capturedAt: capturedAt, sessionID: sessionID, projectName: name)
    }

    private func makeStorageEnvironment() throws -> StorageEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Forge3DRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionID = UUID()
        return StorageEnvironment(directory: directory,
                                  storage: ProjectRecoveryStorage(directoryURL: directory),
                                  sessionID: sessionID)
    }

    private func cleanupSourceMesh() -> EditableMesh {
        EditableMesh(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(9, 9, 9)]
                .map { MeshVertex(position: $0, normal: SIMD3<Float>(0, 0, 1)) },
            indices: [0, 1, 2]
        )
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Asynchronous condition did not complete")
    }
}

private struct StorageEnvironment {
    let directory: URL
    let storage: ProjectRecoveryStorage
    let sessionID: UUID
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private enum TestFailure: Error { case injected }

private actor ManualAutosaveDelayScheduler: AutosaveDelayScheduler {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var waiterCount: Int { waiters.count }

    func wait(nanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in waiters.append(continuation) }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: ()) }
    }
}

private actor AutosaveResultRecorder {
    private(set) var successCount = 0
    private(set) var failureCount = 0

    func receive(_ result: AutosaveScheduleResult) {
        switch result {
        case .started: break
        case .success: successCount += 1
        case .failure: failureCount += 1
        }
    }
}
