import XCTest
import MetalKit
import simd
@testable import Forge3D

final class MeshCleanupTests: XCTestCase {
    func testEstimateRejectsNoOptionsAndSelectedItemsWithoutTargets() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertThrowsError(try MeshCleanup.estimate(mesh: cube, options: .none)) {
            XCTAssertEqual($0 as? MeshCleanupError, .noOptionsSelected)
        }
        XCTAssertThrowsError(try MeshCleanup.estimate(
            mesh: cube, options: MeshCleanupOptions(removeIsolatedVertices: true))) {
            XCTAssertEqual($0 as? MeshCleanupError, .noApplicableCleanup)
        }
    }

    func testCombinedEstimateCountsResultMemoryAndDeterminism() throws {
        let mesh = combinedMesh(), options = allOptions
        let first = try MeshCleanup.estimate(mesh: mesh, options: options)
        let second = try MeshCleanup.estimate(mesh: mesh, options: options)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.originalVertexCount, 8)
        XCTAssertEqual(first.originalTriangleCount, 4)
        XCTAssertEqual(first.removableDegenerateTriangleCount, 1)
        XCTAssertEqual(first.removableDuplicateTriangleCount, 1)
        XCTAssertEqual(first.removableIsolatedVertexCount, 1)
        XCTAssertEqual(first.newlyUnreferencedVertexCount, 3)
        XCTAssertEqual(first.resultingVertexCount, 4)
        XCTAssertEqual(first.resultingTriangleCount, 2)
        XCTAssertGreaterThan(first.estimatedWorkingByteCount, 0)
        XCTAssertLessThanOrEqual(first.estimatedWorkingByteCount, MeshCleanup.maximumWorkingBytes)
    }

    func testWorkingMemoryAndArithmeticOverflowGuards() throws {
        XCTAssertThrowsError(try MeshCleanup.validateWorkingByteCount(MeshCleanup.maximumWorkingBytes + 1)) {
            XCTAssertEqual($0 as? MeshCleanupError, .workingMemoryLimitExceeded)
        }
        XCTAssertThrowsError(try MeshCleanup.estimatedWorkingBytes(
            originalVertices: Int.max, originalIndices: Int.max,
            resultingVertices: Int.max, resultingIndices: Int.max)) {
            XCTAssertEqual($0 as? MeshCleanupError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try MeshCleanup.validateWorkingByteCount(-1)) {
            XCTAssertEqual($0 as? MeshCleanupError, .arithmeticOverflow)
        }
    }

    func testDegenerateRemovalMatchesDiagnosticsForRepeatedCollinearAndScaleRelativeTinyTriangles() throws {
        for source in [repeatedIndexMesh(), collinearMesh(), scaleRelativeTinyMesh()] {
            let sourceCopy = source
            XCTAssertEqual(MeshTopologyDiagnostics.analyze(source).degenerateTriangleCount, 1)
            let result = try MeshCleanup.clean(
                mesh: source, options: MeshCleanupOptions(removeDegenerateTriangles: true))
            XCTAssertEqual(source, sourceCopy)
            XCTAssertEqual(result.removedDegenerateTriangleCount, 1)
            XCTAssertEqual(result.resultingTriangleCount, 1)
            XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).degenerateTriangleCount, 0)
        }
    }

    func testDegenerateCleanupKeepsNormalTriangleOrderAndWinding() throws {
        let source = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0),
             SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1)],
            [0, 1, 2, 3, 4, 5, 4, 6, 5]
        )
        let result = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeDegenerateTriangles: true))
        XCTAssertEqual(result.mesh.indices, [0, 1, 2, 1, 3, 2])
        XCTAssertEqual(result.mesh.vertices.map(\.position), Array(source.vertices[3...6]).map(\.position))
    }

    func testRemovingEveryTriangleIsRejectedWithoutChangingSource() {
        let source = makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)], [0, 1, 2])
        let copy = source
        XCTAssertThrowsError(try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeDegenerateTriangles: true))) {
            XCTAssertEqual($0 as? MeshCleanupError, .emptyResult)
        }
        XCTAssertEqual(source, copy)
        XCTAssertEqual(source.runtime, copy.runtime)
    }

    func testDuplicateVariantsKeepFirstOccurrenceAndRemoveLaterTriangles() throws {
        let variants: [[UInt32]] = [[0, 1, 2], [1, 2, 0], [2, 1, 0]]
        for second in variants {
            let source = duplicateMesh(second: second)
            let result = try MeshCleanup.clean(
                mesh: source, options: MeshCleanupOptions(removeDuplicateTriangles: true))
            XCTAssertEqual(result.removedDuplicateTriangleCount, 1)
            XCTAssertEqual(result.mesh.indices, [0, 1, 2, 0, 2, 3])
            XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).duplicateTriangleCount, 0)
        }
    }

    func testDuplicateCleanupIsDeterministicAndKeepsDistinctTriangles() throws {
        let source = duplicateMesh(second: [2, 0, 1])
        let first = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeDuplicateTriangles: true))
        let second = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeDuplicateTriangles: true))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.resultingTriangleCount, 2)
        XCTAssertTrue(first.mesh.indices.contains(3))
    }

    func testIsolatedVertexCompactionPreservesRelativeOrderAndRemapsIndices() throws {
        let positions = [SIMD3<Float>(9, 9, 9), SIMD3(8, 8, 8), SIMD3(0, 0, 0),
                         SIMD3(0, 1, 0), SIMD3(1, 0, 0)]
        let source = makeMesh(positions, [2, 4, 3])
        let result = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeIsolatedVertices: true))
        XCTAssertEqual(result.removedIsolatedVertexCount, 2)
        XCTAssertEqual(result.removedUnreferencedVertexCount, 0)
        XCTAssertEqual(result.mesh.vertices.map(\.position), [positions[2], positions[3], positions[4]])
        XCTAssertEqual(result.mesh.indices, [0, 2, 1])
        XCTAssertTrue(result.mesh.indices.allSatisfy { Int($0) < result.mesh.vertices.count })
    }

    func testTriangleRemovalCompactsOnlyNewlyUnreferencedVerticesWhenIsolatedOptionIsOff() throws {
        let source = combinedMesh()
        let result = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeDegenerateTriangles: true))
        XCTAssertEqual(result.removedUnreferencedVertexCount, 3)
        XCTAssertEqual(result.removedIsolatedVertexCount, 0)
        XCTAssertTrue(result.mesh.vertices.contains { $0.position == SIMD3<Float>(9, 9, 9) })
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).isolatedVertexCount, 1)
    }

    func testCombinedCleanupRemovesSelectedIssuesAndRebuildsFiniteNormalizedNormals() throws {
        let source = combinedMesh()
        let sourceRuntime = source.runtime
        let result = try MeshCleanup.clean(mesh: source, options: allOptions)
        let topology = MeshTopologyDiagnostics.analyze(result.mesh)
        XCTAssertEqual(topology.degenerateTriangleCount, 0)
        XCTAssertEqual(topology.duplicateTriangleCount, 0)
        XCTAssertEqual(topology.isolatedVertexCount, 0)
        XCTAssertEqual(result.mesh.vertices.count, 4)
        XCTAssertEqual(result.mesh.indices.count / 3, 2)
        XCTAssertTrue(result.mesh.hasCachedAdjacency)
        XCTAssertNotEqual(result.mesh.runtime.topologyID, sourceRuntime.topologyID)
        XCTAssertTrue(result.mesh.vertices.allSatisfy {
            $0.position.allFinite && $0.normal.allFinite && abs(simd_length($0.normal) - 1) < 0.000_1
        })
    }

    func testUnselectedIssuesRemainUnmodified() throws {
        let source = combinedMesh()
        let duplicateOnly = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeDuplicateTriangles: true))
        let duplicateTopology = MeshTopologyDiagnostics.analyze(duplicateOnly.mesh)
        XCTAssertEqual(duplicateTopology.duplicateTriangleCount, 0)
        XCTAssertEqual(duplicateTopology.degenerateTriangleCount, 1)
        XCTAssertEqual(duplicateTopology.isolatedVertexCount, 1)

        let isolatedOnly = try MeshCleanup.clean(
            mesh: source, options: MeshCleanupOptions(removeIsolatedVertices: true))
        let isolatedTopology = MeshTopologyDiagnostics.analyze(isolatedOnly.mesh)
        XCTAssertEqual(isolatedTopology.isolatedVertexCount, 0)
        XCTAssertEqual(isolatedTopology.degenerateTriangleCount, 1)
        XCTAssertEqual(isolatedTopology.duplicateTriangleCount, 1)
        XCTAssertEqual(isolatedOnly.mesh.indices, source.indices)
    }

    func testCleanupDoesNotRepairNonManifoldOrWindingConflicts() throws {
        let nonManifold = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0),
             SIMD3(0, 0, 1), SIMD3(9, 9, 9)],
            [0, 1, 2, 1, 0, 3, 0, 1, 4]
        )
        let beforeNonManifold = MeshTopologyDiagnostics.analyze(nonManifold)
        let cleanedNonManifold = try MeshCleanup.clean(
            mesh: nonManifold, options: MeshCleanupOptions(removeIsolatedVertices: true)).mesh
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(cleanedNonManifold).nonManifoldEdgeCount,
                       beforeNonManifold.nonManifoldEdgeCount)
        XCTAssertEqual(cleanedNonManifold.indices, nonManifold.indices)

        let winding = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(9, 9, 9)],
            [0, 1, 2, 0, 1, 3]
        )
        let beforeWinding = MeshTopologyDiagnostics.analyze(winding)
        let cleanedWinding = try MeshCleanup.clean(
            mesh: winding, options: MeshCleanupOptions(removeIsolatedVertices: true)).mesh
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(cleanedWinding).inconsistentWindingEdgeCount,
                       beforeWinding.inconsistentWindingEdgeCount)
        XCTAssertEqual(cleanedWinding.indices, winding.indices)
    }

    func testInvalidIndexAndNonFiniteInputAreRejectedWithoutSourceMutation() {
        let invalid = makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 9])
        let invalidCopy = invalid
        XCTAssertThrowsError(try MeshCleanup.estimate(
            mesh: invalid, options: MeshCleanupOptions(removeDegenerateTriangles: true))) {
            XCTAssertEqual($0 as? MeshCleanupError, .invalidMesh)
        }
        XCTAssertEqual(invalid, invalidCopy)

        let nonFinite = EditableMesh(
            vertices: [MeshVertex(position: SIMD3<Float>(.nan, 0, 0), normal: SIMD3(0, 0, 1)),
                       MeshVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1)),
                       MeshVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1))],
            indices: [0, 1, 2]
        )
        XCTAssertThrowsError(try MeshCleanup.estimate(
            mesh: nonFinite, options: MeshCleanupOptions(removeDegenerateTriangles: true))) {
            XCTAssertEqual($0 as? MeshCleanupError, .nonFiniteValue)
        }
    }

    @MainActor
    func testWorkspacePreviewApplyPreservesToolsTransformCameraAndBuildsRuntimeCaches() throws {
        let model = WorkspaceModel()
        model.mesh = combinedMesh()
        model.camera = CameraState(yaw: 0.8, pitch: -0.2, distance: 42, target: SIMD3(1, 2, 3))
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(4, 5, 6),
                                              scale: SIMD3<Float>(2, 3, 4)))
        model.brush = .crease
        model.brushSettings = BrushSettings(radius: 4.5, strength: 0.3)
        model.symmetry = SculptSymmetry(x: true, z: true)
        model.setGizmoMode(.scale)
        model.setTranslationGizmoVisible(false)
        model.hoverLocation = CGPoint(x: 20, y: 30)
        _ = try model.analyzeCurrentMesh()
        let beforeMesh = model.mesh, beforeRuntime = model.mesh.runtime
        let beforeTransform = model.objectTransform, beforeCamera = model.camera
        let beforeUndo = model.undoCount, overlayRevision = model.meshDiagnosticsOverlayRevision
        try model.prepareForMeshCleanup()
        let preview = try model.previewMeshCleanup(options: allOptions)
        let result = try model.applyMeshCleanup(preview: preview)

        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertNotEqual(model.mesh.runtime.topologyID, beforeRuntime.topologyID)
        XCTAssertEqual(model.objectTransform, beforeTransform)
        XCTAssertEqual(model.camera, beforeCamera)
        XCTAssertEqual(model.brush, .crease)
        XCTAssertEqual(model.brushSettings.radius, 4.5)
        XCTAssertEqual(model.brushSettings.strength, 0.3)
        XCTAssertEqual(model.symmetry, SculptSymmetry(x: true, z: true))
        XCTAssertEqual(model.gizmoMode, .scale)
        XCTAssertFalse(model.showsTranslationGizmo)
        XCTAssertNil(model.hoverLocation)
        XCTAssertEqual(model.undoCount, beforeUndo + 1)
        XCTAssertEqual(model.profiler?.snapshot().vertexCount, result.resultingVertexCount)
        XCTAssertEqual(model.profiler?.snapshot().triangleCount, result.resultingTriangleCount)
        XCTAssertEqual(model.pickingCacheBuildCount, 1)
        XCTAssertEqual(model.sculptSpatialIndexBuildCount, 1)
        XCTAssertTrue(model.mesh.hasCachedAdjacency)
        XCTAssertTrue(model.isMeshDiagnosticsStale)
        XCTAssertGreaterThan(model.meshDiagnosticsOverlayRevision, overlayRevision)
        XCTAssertEqual(model.lastMeshCleanupSummary, result.summary)
        XCTAssertTrue(model.status.contains("Cleanup complete"))
        XCTAssertNotEqual(model.mesh, beforeMesh)
    }

    @MainActor
    func testWorkspaceCleanupIsOneUndoRedoCommandAndNewEditInvalidatesRedo() throws {
        let model = WorkspaceModel(); model.mesh = combinedMesh()
        model.camera = CameraState(yaw: 0.5, pitch: 0.2, distance: 20, target: .zero)
        model.updateTranslation(SIMD3<Float>(3, 4, 5))
        _ = try model.analyzeCurrentMesh()
        let originalMesh = model.mesh, originalRuntime = model.mesh.runtime
        let originalTransform = model.objectTransform, originalCamera = model.camera
        let undoBefore = model.undoCount
        let preview = try model.previewMeshCleanup(options: allOptions)
        let result = try model.applyMeshCleanup(preview: preview)
        let cleanedRuntime = model.mesh.runtime
        XCTAssertEqual(model.undoCount, undoBefore + 1)

        model.undo()
        XCTAssertEqual(model.mesh, originalMesh)
        XCTAssertEqual(model.mesh.runtime, originalRuntime)
        XCTAssertEqual(model.objectTransform, originalTransform)
        XCTAssertEqual(model.camera, originalCamera)
        XCTAssertTrue(model.canRedo)
        XCTAssertTrue(model.isMeshDiagnosticsStale)

        model.redo()
        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertEqual(model.mesh.runtime, cleanedRuntime)
        XCTAssertEqual(model.objectTransform, originalTransform)
        XCTAssertEqual(model.camera, originalCamera)
        model.undo()
        model.updateScale(SIMD3<Float>(repeating: 2))
        XCTAssertFalse(model.canRedo)
    }

    @MainActor
    func testStalePreviewAndPreviewFailuresLeaveWorkspaceCompletelyUnchanged() throws {
        let model = WorkspaceModel(); model.mesh = combinedMesh()
        _ = try model.analyzeCurrentMesh()
        let preview = try model.previewMeshCleanup(options: allOptions)
        _ = model.mesh.updatePositions([0: model.mesh.vertices[0].position + SIMD3<Float>(0, 0, 0.01)])
        let beforeStaleApply = try observation(model)
        XCTAssertThrowsError(try model.applyMeshCleanup(preview: preview)) {
            XCTAssertEqual($0 as? MeshCleanupError, .stalePreview)
        }
        XCTAssertEqual(try observation(model), beforeStaleApply)

        let beforeNoOptions = try observation(model)
        XCTAssertThrowsError(try model.previewMeshCleanup(options: .none)) {
            XCTAssertEqual($0 as? MeshCleanupError, .noOptionsSelected)
        }
        XCTAssertEqual(try observation(model), beforeNoOptions)
        XCTAssertFalse(model.isMeshCleanupRunning)
    }

    @MainActor
    func testCleanupPreparationCancelsStrokeGizmoAndCommitsPanelBeforeAtomicPreview() throws {
        let model = WorkspaceModel(); model.mesh = combinedMesh()
        model.beginStroke()
        XCTAssertThrowsError(try model.previewMeshCleanup(options: allOptions)) {
            XCTAssertEqual($0 as? MeshCleanupError, .activeEdit)
        }
        try model.prepareForMeshCleanup()
        XCTAssertFalse(model.isStrokeActive)

        model.setGizmoMode(.translate)
        let ray = Ray(origin: SIMD3<Float>(0.3, 0.3, 50), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray,
                                                       cameraDirection: SIMD3<Float>(0, 0, -1)))
        try model.prepareForMeshCleanup()
        XCTAssertFalse(model.isGizmoDragging)

        model.beginTransformPanelTransaction()
        model.updateTranslation(SIMD3<Float>(2, 3, 4))
        XCTAssertTrue(model.isTransformPanelEditing)
        try model.prepareForMeshCleanup()
        XCTAssertFalse(model.isTransformPanelEditing)
        XCTAssertNoThrow(try model.previewMeshCleanup(options: allOptions))
    }

    @MainActor
    func testCleanupDiagnosticsReanalysisClearsSelectedIssuesAndKeepsRemainingBoundaryWarning() throws {
        let model = WorkspaceModel(); model.mesh = combinedMesh()
        let originalReport = try model.analyzeCurrentMesh()
        XCTAssertEqual(originalReport.topology.connectedComponentCount, 2)
        let result = try model.applyMeshCleanup(preview: model.previewMeshCleanup(options: allOptions))
        XCTAssertTrue(model.isMeshDiagnosticsStale)
        XCTAssertNotNil(model.lastMeshCleanupSummary)
        let report = try model.analyzeCurrentMesh()
        XCTAssertEqual(report.topology.degenerateTriangleCount, 0)
        XCTAssertEqual(report.topology.duplicateTriangleCount, 0)
        XCTAssertEqual(report.topology.isolatedVertexCount, 0)
        XCTAssertEqual(report.triangleCount, result.resultingTriangleCount)
        XCTAssertEqual(report.topology.connectedComponentCount, 1)
        XCTAssertGreaterThan(report.topology.boundaryEdgeCount, 0)
        XCTAssertFalse(model.isMeshDiagnosticsStale)
        XCTAssertNil(model.lastMeshCleanupSummary)
    }

    @MainActor
    func testCleanedMeshPersistsInFormatVersionOneAndExportsExpectedTriangleCount() throws {
        let model = WorkspaceModel(); model.mesh = combinedMesh()
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(10, 20, 30),
                                              rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(15, 25, 35)),
                                              scale: SIMD3<Float>(2, 3, 4)))
        let preview = try model.previewMeshCleanup(options: allOptions)
        let result = try model.applyMeshCleanup(preview: preview)
        let projectData = try model.projectData()
        let project = try ProjectCodec.decode(projectData)
        XCTAssertEqual(project.formatVersion, 1)
        XCTAssertEqual(project.mesh, result.mesh)
        XCTAssertEqual(project.transform, model.objectTransform)
        XCTAssertFalse(String(decoding: projectData, as: UTF8.self).localizedCaseInsensitiveContains("cleanup"))

        let loaded = WorkspaceModel(); loaded.load(data: projectData)
        XCTAssertEqual(loaded.mesh, result.mesh)
        XCTAssertEqual(loaded.objectTransform, model.objectTransform)
        XCTAssertFalse(loaded.canUndo)
        XCTAssertNil(loaded.lastMeshCleanupSummary)

        let meshBeforeExport = model.mesh, runtimeBeforeExport = model.mesh.runtime
        let stl = try model.stlData()
        XCTAssertEqual(binarySTLTriangleCount(stl), UInt32(result.resultingTriangleCount))
        XCTAssertEqual(model.mesh, meshBeforeExport)
        XCTAssertEqual(model.mesh.runtime, runtimeBeforeExport)
    }

    func testCleanedTopologyUploadsVertexAndIndexOnceThenSkipsUnchangedFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let cleaned = try MeshCleanup.clean(mesh: combinedMesh(), options: allOptions).mesh
        let profiler = PerformanceProfiler(), view = MTKView()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        renderer.update(mesh: try PrimitiveMeshBuilder.cube(size: 2))
        profiler.reset(vertexCount: cleaned.vertices.count, triangleCount: cleaned.indices.count / 3)
        renderer.update(mesh: cleaned)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: cleaned)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
    }

    func testCleanupDeterministicPerformanceScenarioHasNoFixedThreshold() {
        let source = combinedMesh()
        measure(metrics: [XCTClockMetric()]) {
            do {
                let result = try MeshCleanup.clean(mesh: source, options: allOptions)
                XCTAssertEqual(result.resultingTriangleCount, 2)
            } catch { XCTFail("Cleanup failed: \(error)") }
        }
    }

    private var allOptions: MeshCleanupOptions {
        MeshCleanupOptions(removeDegenerateTriangles: true,
                           removeDuplicateTriangles: true,
                           removeIsolatedVertices: true)
    }

    private func combinedMesh() -> EditableMesh {
        makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
             SIMD3(2, 0, 0), SIMD3(3, 0, 0), SIMD3(4, 0, 0), SIMD3(9, 9, 9)],
            [0, 1, 2, 1, 2, 0, 4, 5, 6, 0, 2, 3]
        )
    }

    private func duplicateMesh(second: [UInt32]) -> EditableMesh {
        makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                 [0, 1, 2] + second + [0, 2, 3])
    }

    private func repeatedIndexMesh() -> EditableMesh {
        makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(5, 5, 5),
                  SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1)],
                 [0, 0, 1, 3, 4, 5])
    }

    private func collinearMesh() -> EditableMesh {
        makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0),
                  SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1)],
                 [0, 1, 2, 3, 4, 5])
    }

    private func scaleRelativeTinyMesh() -> EditableMesh {
        makeMesh([SIMD3(0, 0, 0), SIMD3(0.000_01, 0, 0), SIMD3(0, 0.000_01, 0),
                  SIMD3(1_000_000, 0, 0), SIMD3(1_000_000, 10, 0), SIMD3(1_000_000, 0, 10)],
                 [0, 1, 2, 3, 4, 5])
    }

    private func makeMesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        EditableMesh(vertices: positions.map { MeshVertex(position: $0, normal: SIMD3<Float>(0, 0, 1)) },
                     indices: indices)
    }

    private func binarySTLTriangleCount(_ data: Data) -> UInt32 {
        guard data.count >= 84 else { return 0 }
        return UInt32(data[80]) | UInt32(data[81]) << 8 | UInt32(data[82]) << 16 | UInt32(data[83]) << 24
    }

    @MainActor
    private func observation(_ model: WorkspaceModel) throws -> WorkspaceObservation {
        WorkspaceObservation(mesh: model.mesh, runtime: model.mesh.runtime,
                             transform: model.objectTransform, camera: model.camera,
                             undoCount: model.undoCount, redoCount: model.redoCount,
                             canUndo: model.canUndo, canRedo: model.canRedo,
                             profiler: model.profiler?.snapshot(), diagnostics: model.meshDiagnosticsReport,
                             overlayRevision: model.meshDiagnosticsOverlayRevision,
                             cleanupSummary: model.lastMeshCleanupSummary,
                             projectData: try? model.projectData())
    }
}

private struct WorkspaceObservation: Equatable {
    let mesh: EditableMesh
    let runtime: MeshRuntimeState
    let transform: ObjectTransform
    let camera: CameraState
    let undoCount: Int
    let redoCount: Int
    let canUndo: Bool
    let canRedo: Bool
    let profiler: PerformanceSnapshot?
    let diagnostics: MeshDiagnosticsReport?
    let overlayRevision: UInt64
    let cleanupSummary: MeshCleanupSummary?
    let projectData: Data?
}
