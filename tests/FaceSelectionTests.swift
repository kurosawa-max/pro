import Foundation
import MetalKit
import XCTest
import simd
@testable import Forge3D

final class FaceSelectionTests: XCTestCase {
    func testEmptySingleSetClearToggleAndSelectedCount() throws {
        var selection = try makeSelection(triangleCount: 3)
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertEqual(selection.selectedFaceIDs(), [])
        XCTAssertFalse(selection.contains(0))

        XCTAssertTrue(try selection.set(1, selected: true))
        XCTAssertTrue(selection.contains(1))
        XCTAssertEqual(selection.selectedCount, 1)
        XCTAssertTrue(try selection.toggle(1))
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertTrue(try selection.toggle(2))
        XCTAssertEqual(selection.selectedFaceIDs(), [2])
        XCTAssertTrue(selection.clear())
        XCTAssertEqual(selection.selectedFaceIDs(), [])
    }

    func testNoOpAddRemoveReplaceAndClearDoNotAdvanceRevision() throws {
        var selection = try makeSelection(triangleCount: 3)
        let emptyVersion = selection.version
        XCTAssertFalse(try selection.set(1, selected: false))
        XCTAssertFalse(selection.clear())
        XCTAssertEqual(selection.version, emptyVersion)

        XCTAssertTrue(try selection.set(1, selected: true))
        let selectedVersion = selection.version
        XCTAssertFalse(try selection.set(1, selected: true))
        XCTAssertFalse(try selection.replace(with: 1))
        XCTAssertEqual(selection.version, selectedVersion)
        XCTAssertTrue(try selection.replace(with: 2))
        XCTAssertNotEqual(selection.version, selectedVersion)
    }

    func testSelectAllInvertAndTailMaskAtWordBoundaries() throws {
        for triangleCount in [0, 1, 63, 64, 65, 129] {
            var selection = try makeSelection(triangleCount: triangleCount)
            if triangleCount == 0 {
                XCTAssertFalse(selection.selectAll())
                XCTAssertFalse(selection.invert())
                continue
            }
            XCTAssertTrue(selection.selectAll())
            XCTAssertEqual(selection.selectedCount, triangleCount)
            XCTAssertEqual(selection.selectedFaceIDs(), Array(0..<triangleCount))
            XCTAssertFalse(selection.selectAll())
            XCTAssertTrue(selection.invert())
            XCTAssertEqual(selection.selectedCount, 0)
            XCTAssertEqual(selection.selectedFaceIDs(), [])
            XCTAssertTrue(selection.invert())
            XCTAssertEqual(selection.selectedFaceIDs(), Array(0..<triangleCount))
        }
    }

    func testLargeCountAllocationLimitsAndInvalidFaceIDs() throws {
        let selection = try makeSelection(triangleCount: FaceSelection.maximumTriangleCount)
        XCTAssertEqual(selection.triangleCount, FaceSelection.maximumTriangleCount)
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertThrowsError(try makeSelection(triangleCount: -1))
        XCTAssertThrowsError(try makeSelection(triangleCount: FaceSelection.maximumTriangleCount + 1))

        var small = try makeSelection(triangleCount: 2)
        XCTAssertThrowsError(try small.set(-1, selected: true))
        XCTAssertThrowsError(try small.set(2, selected: true))
        XCTAssertFalse(small.contains(-1))
        XCTAssertFalse(small.contains(2))
    }

    func testSelectionEqualityAndUnionAreDeterministic() throws {
        let topologyID = UUID()
        var first = try FaceSelection(sourceTopologyID: topologyID, sourceTopologyRevision: 7,
                                      triangleCount: 6)
        var second = try FaceSelection(sourceTopologyID: topologyID, sourceTopologyRevision: 7,
                                       triangleCount: 6)
        XCTAssertEqual(first, second)
        XCTAssertTrue(try first.formUnion([5, 1, 5, 3]))
        XCTAssertTrue(try second.formUnion([1, 3, 5]))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selectedFaceIDs(), [1, 3, 5])
        let version = first.version
        XCTAssertFalse(try first.formUnion([1, 3]))
        XCTAssertEqual(first.version, version)
    }

    func testSelectedIndicesFollowTriangleOrderAndRejectStaleTopology() throws {
        let mesh = twoTriangleMesh()
        var selection = try self.selection(for: mesh)
        _ = try selection.formUnion([1, 0])
        XCTAssertEqual(try selection.selectedIndices(from: mesh), mesh.indices)

        let other = EditableMesh(vertices: mesh.vertices, indices: mesh.indices)
        XCTAssertThrowsError(try selection.selectedIndices(from: other))
    }

    func testPickingReturnsNearestTriangleIndexAndPreservesCullingPolicy() throws {
        let mesh = stackedTriangleMesh()
        let ray = Ray(origin: SIMD3<Float>(0, 0, 2), direction: SIMD3<Float>(0, 0, -1))
        let hit = try XCTUnwrap(MeshPicker.hit(ray: ray, mesh: mesh))
        XCTAssertEqual(hit.triangleIndex, 0)
        XCTAssertEqual(hit.triangleStart, 0)

        let cache = MeshBVHCache()
        guard case .hit(let indexed) = MeshPicker.indexedHit(ray: ray, mesh: mesh, cache: cache) else {
            return XCTFail("Expected indexed hit")
        }
        XCTAssertEqual(indexed.triangleIndex, 0)
        let backRay = Ray(origin: SIMD3<Float>(0, 0, -2), direction: SIMD3<Float>(0, 0, 1))
        guard case .hit = MeshPicker.indexedHit(ray: backRay, mesh: mesh, culling: .none, cache: cache) else {
            return XCTFail("Expected double-sided hit")
        }
        guard case .miss = MeshPicker.indexedHit(ray: backRay, mesh: mesh, culling: .back, cache: cache) else {
            return XCTFail("Expected back-face miss")
        }
    }

    func testIndexedPickingRejectsInvalidRayAndInvalidMeshWithoutLinearFallback() {
        let mesh = twoTriangleMesh()
        let cache = MeshBVHCache()
        for ray in [
            Ray(origin: SIMD3<Float>(.nan, 0, 1), direction: SIMD3<Float>(0, 0, -1)),
            Ray(origin: SIMD3<Float>(0, 0, 1), direction: .zero),
            Ray(origin: SIMD3<Float>(0, 0, 1), direction: SIMD3<Float>(.infinity, 0, 0)),
        ] {
            guard case .unavailable = MeshPicker.indexedHit(ray: ray, mesh: mesh, cache: cache) else {
                return XCTFail("Expected unavailable result")
            }
        }
        let invalid = EditableMesh(vertices: mesh.vertices, indices: [0, 1, 99])
        guard case .unavailable = MeshPicker.indexedHit(
            ray: Ray(origin: SIMD3<Float>(0, 0, 1), direction: SIMD3<Float>(0, 0, -1)),
            mesh: invalid, cache: MeshBVHCache()) else {
            return XCTFail("Expected invalid topology to remain unavailable")
        }
    }

    @MainActor
    func testWorkspacePickingUsesObjectTransformForNonUniformScaleAndRotation() throws {
        let model = faceSelectionModel(mesh: EditableMesh.icosphere(subdivisions: 0))
        let transform = ObjectTransform(
            translation: SIMD3<Float>(4, -2, 6),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(25, 40, -15)),
            scale: SIMD3<Float>(2, 0.5, 3))
        model.updateTransform(transform)
        let localRay = Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1))
        let expected = try XCTUnwrap(MeshPicker.hit(ray: localRay, mesh: model.mesh)).triangleIndex
        let worldRay = Ray(origin: transform.worldPosition(fromLocal: localRay.origin),
                           direction: transform.worldDirection(fromLocal: localRay.direction))
        XCTAssertTrue(model.selectFace(fromWorldRay: worldRay))
        XCTAssertTrue(model.faceSelection.contains(expected))
        XCTAssertEqual(model.selectedFaceCount, 1)
    }

    @MainActor
    func testReplaceAddRemoveToggleAndBlankPolicies() {
        let model = faceSelectionModel(mesh: twoTriangleMesh())
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), [0])
        XCTAssertTrue(model.applyFaceSelectionHit(nil))
        XCTAssertEqual(model.selectedFaceCount, 0)

        model.setFaceSelectionOperation(.add)
        XCTAssertFalse(model.applyFaceSelectionHit(nil))
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        let addVersion = model.faceSelection.version
        XCTAssertFalse(model.applyFaceSelectionHit(0))
        XCTAssertEqual(model.faceSelection.version, addVersion)

        model.setFaceSelectionOperation(.remove)
        XCTAssertFalse(model.applyFaceSelectionHit(nil))
        XCTAssertFalse(model.applyFaceSelectionHit(1))
        XCTAssertTrue(model.applyFaceSelectionHit(0))

        model.setFaceSelectionOperation(.toggle)
        XCTAssertFalse(model.applyFaceSelectionHit(nil))
        XCTAssertTrue(model.applyFaceSelectionHit(1))
        XCTAssertTrue(model.applyFaceSelectionHit(1))
        XCTAssertEqual(model.selectedFaceCount, 0)
    }

    func testPencilTapTrackerAcceptsSmallQuickTap() {
        var tracker = FaceSelectionTapTracker()
        tracker.begin(sample(location: CGPoint(x: 20, y: 30), timestamp: 1))
        tracker.update(sample(location: CGPoint(x: 25, y: 33), timestamp: 1.1))
        let point = tracker.finish(sample(location: CGPoint(x: 26, y: 34), timestamp: 1.2),
                                   viewport: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(point, CGPoint(x: 26, y: 34))
        XCTAssertFalse(tracker.isTracking)
    }

    func testPencilTapTrackerRejectsDragDurationCancellationAndOutsideViewport() {
        var tracker = FaceSelectionTapTracker()
        tracker.begin(sample(location: .zero, timestamp: 1))
        XCTAssertNil(tracker.finish(sample(location: CGPoint(x: 20, y: 0), timestamp: 1.1),
                                    viewport: CGRect(x: -50, y: -50, width: 100, height: 100)))
        tracker.begin(sample(location: .zero, timestamp: 1))
        XCTAssertNil(tracker.finish(sample(location: .zero, timestamp: 2),
                                    viewport: CGRect(x: -1, y: -1, width: 2, height: 2)))
        tracker.begin(sample(location: .zero, timestamp: 1))
        tracker.cancel()
        XCTAssertNil(tracker.finish(sample(location: .zero, timestamp: 1.1),
                                    viewport: CGRect(x: -1, y: -1, width: 2, height: 2)))
        tracker.begin(sample(location: CGPoint(x: 5, y: 5), timestamp: 1))
        XCTAssertNil(tracker.finish(sample(location: CGPoint(x: 101, y: 5), timestamp: 1.1),
                                    viewport: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    configuration: FaceSelectionTapConfiguration(maximumMovement: 200,
                                                                                 maximumDuration: 1)))
    }

    func testConnectedUsesSharedEdgesButNotVertexOnlyContact() throws {
        let mesh = connectivityMesh()
        XCTAssertEqual(try FaceSelectionConnectivity.connectedFaceIDs(mesh: mesh, seeds: [0]), [0, 1])
        XCTAssertEqual(try FaceSelectionConnectivity.connectedFaceIDs(mesh: mesh, seeds: [2]), [2])
        XCTAssertEqual(try FaceSelectionConnectivity.connectedFaceIDs(mesh: mesh, seeds: [2, 0]), [0, 1, 2])
    }

    func testConnectedIncludesEveryFaceOnNonManifoldEdge() throws {
        let vertices = [
            vertex(0, 0, 0), vertex(1, 0, 0), vertex(0, 1, 0),
            vertex(0, -1, 0), vertex(0, 0, 1),
        ]
        let mesh = EditableMesh(vertices: vertices, indices: [0, 1, 2, 1, 0, 3, 0, 1, 4])
        XCTAssertEqual(try FaceSelectionConnectivity.connectedFaceIDs(mesh: mesh, seeds: [1]), [0, 1, 2])
    }

    func testConnectedDuplicateTrianglePolicyIsDeterministic() throws {
        let vertices = [vertex(0, 0, 0), vertex(1, 0, 0), vertex(0, 1, 0)]
        let mesh = EditableMesh(vertices: vertices, indices: [0, 1, 2, 2, 1, 0])
        let first = try FaceSelectionConnectivity.connectedFaceIDs(mesh: mesh, seeds: [0])
        let second = try FaceSelectionConnectivity.connectedFaceIDs(mesh: mesh, seeds: [0])
        XCTAssertEqual(first, [0, 1])
        XCTAssertEqual(first, second)
    }

    func testConnectedRejectsInvalidIndicesRepeatedIndicesAndLimitOverflow() {
        let vertices = [vertex(0, 0, 0), vertex(1, 0, 0), vertex(0, 1, 0)]
        XCTAssertThrowsError(try FaceSelectionConnectivity.connectedFaceIDs(
            mesh: EditableMesh(vertices: vertices, indices: [0, 1, 9]), seeds: [0]))
        XCTAssertThrowsError(try FaceSelectionConnectivity.connectedFaceIDs(
            mesh: EditableMesh(vertices: vertices, indices: [0, 0, 1]), seeds: [0]))

        let excessiveIndexCount = (FaceSelectionConnectivity.maximumTriangleCount + 1) * 3
        let excessive = EditableMesh(vertices: vertices,
                                     indices: Array(repeating: UInt32(0), count: excessiveIndexCount))
        XCTAssertThrowsError(try FaceSelectionConnectivity.connectedFaceIDs(mesh: excessive, seeds: [0]))
    }

    func testConnectedLargeLinearCaseHasDeterministicLinearResult() throws {
        let triangleCount = 10_000
        let vertices = (0..<(triangleCount + 2)).map { index in
            vertex(Float(index), Float(index & 1), Float((index % 3) == 0 ? 1 : 0))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(triangleCount * 3)
        for face in 0..<triangleCount {
            indices.append(UInt32(face))
            indices.append(UInt32(face + 1))
            indices.append(UInt32(face + 2))
        }
        let result = try FaceSelectionConnectivity.connectedFaceIDs(
            mesh: EditableMesh(vertices: vertices, indices: indices), seeds: [0])
        XCTAssertEqual(result.count, triangleCount)
        XCTAssertEqual(result.first, 0)
        XCTAssertEqual(result.last, triangleCount - 1)
    }

    @MainActor
    func testModeSwitchSuppressesSculptAndKeepsGizmoPriorityAvailable() {
        let model = WorkspaceModel()
        let generation = model.projectMutationGeneration
        let runtime = model.mesh.runtime
        let history = (model.undoCount, model.redoCount)
        model.setInteractionMode(.faceSelect)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.mesh.runtime, runtime)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        model.beginStroke()
        XCTAssertFalse(model.isStrokeActive)
        let ray = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray,
                                                       cameraDirection: SIMD3<Float>(0, 0, -1)))
        XCTAssertTrue(model.isGizmoDragging)
        model.setInteractionMode(.sculpt)
        XCTAssertFalse(model.isGizmoDragging)
        model.beginStroke()
        XCTAssertTrue(model.isStrokeActive)
        model.setInteractionMode(.faceSelect)
        XCTAssertFalse(model.isStrokeActive)
    }

    @MainActor
    func testVertexOnlySculptTransformCameraSaveAndDiagnosticsPreserveSelection() throws {
        let model = faceSelectionModel()
        _ = model.applyFaceSelectionHit(0)
        let selected = model.faceSelection.selectedFaceIDs()
        let topologyID = model.mesh.runtime.topologyID
        let topologyRevision = model.mesh.runtime.topologyRevision

        model.setInteractionMode(.sculpt)
        model.beginStroke()
        model.updateStroke(sample: sample(location: .zero, timestamp: 1),
                           ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)))
        model.endStroke()
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)
        model.undo()
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)
        model.redo()
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)

        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)
        model.undo()
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)
        model.redo()
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)

        let beforeCamera = model.camera
        model.camera.yaw += 0.2
        model.commitCameraChange(from: beforeCamera)
        _ = try model.prepareExplicitSave()
        _ = try model.analyzeCurrentMesh()
        XCTAssertEqual(model.faceSelection.selectedFaceIDs(), selected)
        XCTAssertEqual(model.mesh.runtime.topologyID, topologyID)
        XCTAssertEqual(model.mesh.runtime.topologyRevision, topologyRevision)
    }

    @MainActor
    func testPrimitiveAndTopologyUndoRedoAlwaysClearSelection() throws {
        let model = faceSelectionModel()
        _ = model.applyFaceSelectionHit(0)
        var parameters = PrimitiveParameters(kind: .cube)
        parameters.size = 20
        try model.createPrimitive(parameters: parameters)
        XCTAssertEqual(model.selectedFaceCount, 0)

        _ = model.applyFaceSelectionHit(0)
        model.undo()
        XCTAssertEqual(model.selectedFaceCount, 0)
        _ = model.applyFaceSelectionHit(0)
        model.redo()
        XCTAssertEqual(model.selectedFaceCount, 0)
    }

    @MainActor
    func testSubdivisionImportCleanupAndLoadClearSelection() throws {
        let subdivision = faceSelectionModel(mesh: EditableMesh.icosphere(subdivisions: 0))
        _ = subdivision.applyFaceSelectionHit(0)
        try subdivision.subdivideMeshOnce()
        XCTAssertEqual(subdivision.selectedFaceCount, 0)

        let imported = faceSelectionModel()
        _ = imported.applyFaceSelectionHit(0)
        let stl = try BinarySTLExporter.data(for: EditableMesh.icosphere(subdivisions: 0))
        try imported.importSTL(data: stl)
        XCTAssertEqual(imported.selectedFaceCount, 0)

        let cleanup = faceSelectionModel(mesh: cleanupMesh())
        _ = cleanup.applyFaceSelectionHit(0)
        try cleanup.prepareForMeshCleanup()
        let preview = try cleanup.previewMeshCleanup(
            options: MeshCleanupOptions(removeDuplicateTriangles: true))
        _ = try cleanup.applyMeshCleanup(preview: preview)
        XCTAssertEqual(cleanup.selectedFaceCount, 0)

        let loaded = faceSelectionModel()
        _ = loaded.applyFaceSelectionHit(0)
        let project = ForgeProject(mesh: EditableMesh.icosphere(subdivisions: 0), camera: CameraState())
        try loaded.loadProject(data: ProjectCodec.encode(project))
        XCTAssertEqual(loaded.selectedFaceCount, 0)
    }

    @MainActor
    func testRecoveryClearsSelectionAndDoesNotPersistIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Forge3DFaceSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ProjectRecoveryStorage(directoryURL: directory)
        let snapshot = ProjectAutosaveSnapshot(
            project: ForgeProject(mesh: try PrimitiveMeshBuilder.cube(size: 20), camera: CameraState()),
            sourceGeneration: MutationGeneration(), capturedAt: Date(), sessionID: UUID(),
            projectName: "Recovered Mesh")
        _ = try storage.write(snapshot)
        let model = WorkspaceModel(autosaveCoordinator: ProjectAutosaveCoordinator(storage: storage))
        model.setInteractionMode(.faceSelect)
        _ = model.applyFaceSelectionHit(0)
        XCTAssertEqual(model.selectedFaceCount, 1)
        await model.inspectRecoveryOnLaunch()
        await model.recoverAutosave()
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertEqual(try ProjectCodec.decode(model.projectData()).formatVersion, 1)
    }

    @MainActor
    func testSelectionOperationsLeaveDirtyHistoryGenerationAndProjectBytesUnchanged() async throws {
        let coordinator = ProjectAutosaveCoordinator()
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch()
        model.setInteractionMode(.faceSelect)
        let beforeData = try model.projectData()
        let beforeGeneration = model.projectMutationGeneration
        let beforeSaveState = model.saveState
        let beforeRuntime = model.mesh.runtime
        let beforeHistory = (model.undoCount, model.redoCount, model.canUndo, model.canRedo)
        let beforeTransform = model.objectTransform
        let beforeCamera = model.camera

        _ = model.applyFaceSelectionHit(0)
        model.setFaceSelectionOperation(.add)
        _ = model.applyFaceSelectionHit(1)
        model.setFaceSelectionOperation(.remove)
        _ = model.applyFaceSelectionHit(0)
        model.setFaceSelectionOperation(.toggle)
        _ = model.applyFaceSelectionHit(2)
        model.clearFaceSelection()
        model.selectAllFaces()
        model.invertFaceSelection()
        _ = model.applyFaceSelectionHit(0)
        model.selectConnectedFaces()
        for _ in 0..<1_000 where model.isFaceSelectionProcessing { await Task.yield() }
        _ = try model.makeAutosaveSnapshot()

        XCTAssertEqual(try model.projectData(), beforeData)
        XCTAssertEqual(model.projectMutationGeneration, beforeGeneration)
        XCTAssertEqual(model.saveState, beforeSaveState)
        XCTAssertEqual(model.mesh.runtime, beforeRuntime)
        XCTAssertEqual(model.undoCount, beforeHistory.0)
        XCTAssertEqual(model.redoCount, beforeHistory.1)
        XCTAssertEqual(model.canUndo, beforeHistory.2)
        XCTAssertEqual(model.canRedo, beforeHistory.3)
        XCTAssertEqual(model.objectTransform, beforeTransform)
        XCTAssertEqual(model.camera, beforeCamera)
        XCTAssertFalse(model.isDirty)
        let autosaveWriteCount = await coordinator.successfulWriteCount
        XCTAssertEqual(autosaveWriteCount, 0)
    }

    @MainActor
    func testBenchmarkDisablesFaceSelectionAndCommands() async {
        #if DEBUG
        let model = faceSelectionModel()
        _ = model.applyFaceSelectionHit(0)
        model.runAllBenchmarks()
        XCTAssertTrue(model.isBenchmarkRunning)
        XCTAssertFalse(model.isFaceSelectionInteractionEnabled)
        let selected = model.selectedFaceCount
        XCTAssertFalse(model.applyFaceSelectionHit(1))
        XCTAssertEqual(model.selectedFaceCount, selected)
        model.cancelBenchmarks()
        for _ in 0..<1_000 where model.isBenchmarkRunning { await Task.yield() }
        XCTAssertFalse(model.isBenchmarkRunning)
        #endif
    }

    func testOverlayCacheKeyLayoutAndDrawOrder() throws {
        let mesh = twoTriangleMesh()
        var selection = try self.selection(for: mesh)
        let key0 = FaceSelectionOverlayCacheKey(meshTopologyID: mesh.runtime.topologyID,
                                                meshTopologyRevision: mesh.runtime.topologyRevision,
                                                selectionTopologyID: selection.sourceTopologyID,
                                                selectionTopologyRevision: selection.sourceTopologyRevision,
                                                triangleCount: selection.triangleCount,
                                                selectionVersion: selection.version)
        XCTAssertTrue(FaceSelectionOverlayRenderer.requiresUpload(previous: nil, current: key0))
        XCTAssertFalse(FaceSelectionOverlayRenderer.requiresUpload(previous: key0, current: key0))
        _ = try selection.set(0, selected: true)
        let key1 = FaceSelectionOverlayCacheKey(meshTopologyID: mesh.runtime.topologyID,
                                                meshTopologyRevision: mesh.runtime.topologyRevision,
                                                selectionTopologyID: selection.sourceTopologyID,
                                                selectionTopologyRevision: selection.sourceTopologyRevision,
                                                triangleCount: selection.triangleCount,
                                                selectionVersion: selection.version)
        XCTAssertTrue(FaceSelectionOverlayRenderer.requiresUpload(previous: key0, current: key1))
        XCTAssertEqual(MemoryLayout<FaceSelectionOverlayUniforms>.stride, 128)
        XCTAssertEqual(MetalRenderer.drawOrder, [.mesh, .faceSelection, .diagnostics, .gizmo])
    }

    func testRendererUploadsSelectionOnlyWhenSelectionOrTopologyChanges() throws {
        #if DEBUG
        var mesh = EditableMesh.icosphere(subdivisions: 0)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: MTKView(), profiler: profiler))
        renderer.update(mesh: mesh)
        profiler.reset(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        var selection = try self.selection(for: mesh)
        _ = try selection.set(0, selected: true)
        renderer.updateFaceSelection(mesh: mesh, selection: selection)
        XCTAssertEqual(renderer.faceSelectionOverlayUploadCount, 1)
        XCTAssertEqual(renderer.faceSelectionOverlayIndexCount, 3)

        renderer.updateFaceSelection(mesh: mesh, selection: selection)
        renderer.camera.yaw += 0.2
        renderer.objectTransform = ObjectTransform(translation: SIMD3<Float>(1, 2, 3))
        renderer.updateFaceSelection(mesh: mesh, selection: selection)
        XCTAssertEqual(renderer.faceSelectionOverlayUploadCount, 1)

        _ = mesh.updatePositions([0: mesh.vertices[0].position * 0.98])
        renderer.update(mesh: mesh)
        renderer.updateFaceSelection(mesh: mesh, selection: selection)
        XCTAssertEqual(renderer.faceSelectionOverlayUploadCount, 1)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 0)

        _ = try selection.set(1, selected: true)
        renderer.updateFaceSelection(mesh: mesh, selection: selection)
        XCTAssertEqual(renderer.faceSelectionOverlayUploadCount, 2)
        XCTAssertEqual(renderer.faceSelectionOverlayIndexCount, 6)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 0)

        let replacement = EditableMesh.icosphere(subdivisions: 1)
        var replacementSelection = try self.selection(for: replacement)
        _ = try replacementSelection.set(0, selected: true)
        renderer.update(mesh: replacement)
        renderer.updateFaceSelection(mesh: replacement, selection: replacementSelection)
        XCTAssertEqual(renderer.faceSelectionOverlayUploadCount, 3)
        XCTAssertEqual(renderer.faceSelectionOverlayIndexCount, 3)

        let empty = try self.selection(for: replacement)
        renderer.updateFaceSelection(mesh: replacement, selection: empty)
        XCTAssertEqual(renderer.faceSelectionOverlayIndexCount, 0)
        #endif
    }

    func testProjectAndRecoveryPayloadContainNoSelectionState() throws {
        let mesh = EditableMesh.icosphere(subdivisions: 0)
        var selection = try self.selection(for: mesh)
        _ = selection.selectAll()
        let project = ForgeProject(mesh: mesh, camera: CameraState())
        let before = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(before).formatVersion, 1)
        XCTAssertEqual(try ProjectCodec.encode(project), before)
        XCTAssertEqual(selection.selectedCount, mesh.indices.count / 3)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("faceSelection"))
    }

    private func makeSelection(triangleCount: Int) throws -> FaceSelection {
        try FaceSelection(sourceTopologyID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                          sourceTopologyRevision: 1, triangleCount: triangleCount)
    }

    private func selection(for mesh: EditableMesh) throws -> FaceSelection {
        try FaceSelection(sourceTopologyID: mesh.runtime.topologyID,
                          sourceTopologyRevision: mesh.runtime.topologyRevision,
                          triangleCount: mesh.indices.count / 3)
    }

    @MainActor
    private func faceSelectionModel(mesh: EditableMesh = EditableMesh.icosphere()) -> WorkspaceModel {
        let model = WorkspaceModel()
        if model.mesh.runtime.topologyID != mesh.runtime.topologyID { model.mesh = mesh }
        model.setInteractionMode(.faceSelect)
        return model
    }

    private func sample(location: CGPoint, timestamp: TimeInterval) -> PencilSample {
        PencilSample(location: location, force: 1, maximumForce: 1,
                     altitude: .pi / 2, azimuth: 0, timestamp: timestamp)
    }

    private func vertex(_ x: Float, _ y: Float, _ z: Float) -> MeshVertex {
        MeshVertex(position: SIMD3<Float>(x, y, z), normal: SIMD3<Float>(0, 0, 1))
    }

    private func twoTriangleMesh() -> EditableMesh {
        EditableMesh(
            vertices: [vertex(-1, -1, 0), vertex(1, -1, 0), vertex(1, 1, 0), vertex(-1, 1, 0)],
            indices: [0, 1, 2, 0, 2, 3])
    }

    private func stackedTriangleMesh() -> EditableMesh {
        EditableMesh(
            vertices: [
                vertex(-1, -1, 0), vertex(1, -1, 0), vertex(0, 1, 0),
                vertex(-1, -1, -1), vertex(1, -1, -1), vertex(0, 1, -1),
            ],
            indices: [0, 1, 2, 3, 4, 5])
    }

    private func connectivityMesh() -> EditableMesh {
        EditableMesh(
            vertices: [
                vertex(0, 0, 0), vertex(1, 0, 0), vertex(0, 1, 0), vertex(1, 1, 0),
                vertex(-1, 0, 0), vertex(-1, 1, 0),
            ],
            indices: [0, 1, 2, 2, 1, 3, 0, 4, 5])
    }

    private func cleanupMesh() -> EditableMesh {
        EditableMesh(
            vertices: [vertex(0, 0, 0), vertex(1, 0, 0), vertex(1, 1, 0), vertex(0, 1, 0)],
            indices: [0, 1, 2, 0, 1, 2, 0, 2, 3])
    }
}
