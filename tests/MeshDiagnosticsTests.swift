import XCTest
import simd
@testable import Forge3D

final class MeshDiagnosticsTests: XCTestCase {
    func testSingleTriangleHasThreeBoundaryEdges() {
        let report = analyze(triangleMesh())
        XCTAssertEqual(report.topology.uniqueEdgeCount, 3)
        XCTAssertEqual(report.topology.boundaryEdgeCount, 3)
        XCTAssertEqual(report.topology.manifoldEdgeCount, 0)
        XCTAssertFalse(report.topology.isClosed)
    }

    func testTwoTrianglesClassifySharedManifoldEdge() {
        let mesh = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0)],
            [0, 1, 2, 1, 0, 3]
        )
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        XCTAssertEqual(topology.uniqueEdgeCount, 5)
        XCTAssertEqual(topology.boundaryEdgeCount, 4)
        XCTAssertEqual(topology.manifoldEdgeCount, 1)
        XCTAssertEqual(topology.inconsistentWindingEdgeCount, 0)
    }

    func testClosedTetrahedronAndCubeAreClosedManifolds() throws {
        let tetra = makeMesh(
            [SIMD3(1, 1, 1), SIMD3(-1, -1, 1), SIMD3(-1, 1, -1), SIMD3(1, -1, -1)],
            [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        )
        let tetraReport = analyze(tetra)
        XCTAssertTrue(tetraReport.topology.isClosed)
        XCTAssertEqual(tetraReport.topology.boundaryEdgeCount, 0)
        XCTAssertEqual(tetraReport.topology.manifoldEdgeCount, 6)
        let cubeReport = analyze(try PrimitiveMeshBuilder.cube(size: 2))
        XCTAssertTrue(cubeReport.topology.isClosed)
        XCTAssertEqual(cubeReport.topology.uniqueEdgeCount, 18)
    }

    func testThreeTrianglesSharingEdgeAreNonManifold() {
        let mesh = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)],
            [0, 1, 2, 1, 0, 3, 0, 1, 4]
        )
        let report = analyze(mesh)
        XCTAssertEqual(report.topology.nonManifoldEdgeCount, 1)
        XCTAssertFalse(report.topology.isManifold)
        XCTAssertEqual(report.severity, .error)
    }

    func testEdgeClassificationIsDeterministic() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(mesh), MeshTopologyDiagnostics.analyze(mesh))
        XCTAssertEqual(analyze(mesh), analyze(mesh))
    }

    func testSameDirectionSharedEdgeIsWindingConflict() {
        let mesh = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0)],
            [0, 1, 2, 0, 1, 3]
        )
        let report = analyze(mesh)
        XCTAssertEqual(report.topology.inconsistentWindingEdgeCount, 1)
        XCTAssertFalse(report.topology.hasConsistentOrientation)
        XCTAssertEqual(report.overlay.windingConflicts.count, 1)
    }

    func testOppositeWindingDuplicateIsDetectedWithoutWindingConflict() {
        let mesh = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            [0, 1, 2, 2, 1, 0]
        )
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        XCTAssertEqual(topology.duplicateTriangleCount, 1)
        XCTAssertEqual(topology.inconsistentWindingEdgeCount, 0)
    }

    func testOutwardAndInwardCubeHaveOppositeSignedVolume() throws {
        let outward = try PrimitiveMeshBuilder.cube(size: 2)
        let inward = reversedWinding(outward)
        let outside = analyze(outward), inside = analyze(inward)
        XCTAssertEqual(abs(outside.localMetrics.signedVolumeMM3), 8, accuracy: 0.000_01)
        XCTAssertEqual(inside.localMetrics.signedVolumeMM3, -outside.localMetrics.signedVolumeMM3,
                       accuracy: 0.000_01)
        XCTAssertTrue(inside.issues.contains { $0.kind == .inwardOrientation })
        XCTAssertEqual(inside.severity, .warning)
    }

    func testRepeatedIndexAndCollinearTrianglesAreDegenerate() {
        let repeated = analyze(makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 0, 2]))
        XCTAssertEqual(repeated.topology.degenerateTriangleCount, 1)
        let collinear = analyze(makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)], [0, 1, 2]))
        XCTAssertEqual(collinear.topology.degenerateTriangleCount, 1)
        XCTAssertEqual(collinear.overlay.degenerateTrianglePoints.count, 1)
    }

    func testScaleRelativeTinyTriangleIsDegenerate() {
        let mesh = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(0.000_01, 0, 0), SIMD3(0, 0.000_01, 0), SIMD3(1_000_000, 0, 0)],
            [0, 1, 2]
        )
        XCTAssertEqual(analyze(mesh).topology.degenerateTriangleCount, 1)
    }

    func testNaNInfinityAndInvalidIndicesAreFatalIssues() {
        let nan = makeMesh([SIMD3(.nan, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2])
        XCTAssertEqual(analyze(nan).topology.nonFiniteVertexCount, 1)
        let infinity = makeMesh([SIMD3(.infinity, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2])
        XCTAssertEqual(analyze(infinity).severity, .error)
        let invalid = makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 9])
        let invalidReport = analyze(invalid)
        XCTAssertEqual(invalidReport.topology.invalidIndexTriangleCount, 1)
        XCTAssertFalse(invalidReport.canSubdivide)
        XCTAssertFalse(invalidReport.canExportSTL)
    }

    func testNonFiniteTransformIsReportedWithoutMutatingInput() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        var transform = ObjectTransform.identity
        transform.translation.x = .nan
        let report = MeshDiagnostics.analyze(mesh: mesh, transform: transform)
        XCTAssertEqual(report.severity, .error)
        XCTAssertTrue(report.issues.contains { $0.kind == .nonFiniteValue })
        XCTAssertFalse(report.canExportSTL)
    }

    func testDuplicateTriangleVariantsAndDistinctTriangle() {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        XCTAssertEqual(analyze(makeMesh(positions, [0, 1, 2, 0, 1, 2])).topology.duplicateTriangleCount, 1)
        XCTAssertEqual(analyze(makeMesh(positions, [0, 1, 2, 1, 2, 0])).topology.duplicateTriangleCount, 1)
        XCTAssertEqual(analyze(makeMesh(positions, [0, 1, 2, 2, 1, 0])).topology.duplicateTriangleCount, 1)
        XCTAssertEqual(analyze(makeMesh(positions, [0, 1, 2, 0, 3, 1])).topology.duplicateTriangleCount, 0)
    }

    func testIsolatedVertexCountsZeroOneAndMultiple() {
        XCTAssertEqual(analyze(triangleMesh()).topology.isolatedVertexCount, 0)
        let one = makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(2, 2, 2)], [0, 1, 2])
        XCTAssertEqual(analyze(one).topology.isolatedVertexCount, 1)
        let multiple = makeMesh(one.vertices.map(\.position) + [SIMD3(3, 3, 3)], [0, 1, 2])
        XCTAssertEqual(analyze(multiple).topology.isolatedVertexCount, 2)
        XCTAssertEqual(analyze(multiple).overlay.isolatedVertexPoints.count, 2)
    }

    func testReferencingPreviouslyIsolatedVertexChangesCountInNewMesh() {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        XCTAssertEqual(analyze(makeMesh(positions, [0, 1, 2])).topology.isolatedVertexCount, 1)
        XCTAssertEqual(analyze(makeMesh(positions, [0, 1, 2, 0, 3, 1])).topology.isolatedVertexCount, 0)
    }

    func testConnectedComponentsUseSharedEdgesNotVertexOnlyContact() {
        let disconnected = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
             SIMD3(3, 0, 0), SIMD3(4, 0, 0), SIMD3(3, 1, 0)],
            [0, 1, 2, 3, 4, 5]
        )
        XCTAssertEqual(analyze(disconnected).topology.connectedComponentCount, 2)
        let edgeConnected = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)],
            [0, 1, 2, 2, 1, 3]
        )
        XCTAssertEqual(analyze(edgeConnected).topology.connectedComponentCount, 1)
        let vertexOnly = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, -1, 0)],
            [0, 1, 2, 0, 3, 4]
        )
        XCTAssertEqual(analyze(vertexOnly).topology.connectedComponentCount, 2)
        XCTAssertEqual(analyze(vertexOnly).topology.componentTriangleCounts, [1, 1])
    }

    func testTriangleAndCubeSurfaceArea() throws {
        XCTAssertEqual(analyze(triangleMesh()).localMetrics.surfaceAreaMM2, 0.5, accuracy: 0.000_001)
        let cube = analyze(try PrimitiveMeshBuilder.cube(size: 2))
        XCTAssertEqual(cube.localMetrics.surfaceAreaMM2, 24, accuracy: 0.000_01)
        XCTAssertEqual(cube.localMetrics.absoluteVolumeMM3, 8, accuracy: 0.000_01)
    }

    func testOpenMeshVolumeIsUnavailable() {
        let report = analyze(triangleMesh())
        XCTAssertFalse(report.volumeIsReliable)
        XCTAssertNil(report.worldMetrics.signedVolumeMM3)
    }

    func testNonUniformScaleWorldAreaAndVolume() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(scale: SIMD3<Float>(2, 3, 4))
        let report = MeshDiagnostics.analyze(mesh: mesh, transform: transform)
        XCTAssertEqual(report.worldMetrics.surfaceAreaMM2, 208, accuracy: 0.001)
        XCTAssertEqual(report.worldMetrics.absoluteVolumeMM3 ?? -1, 192, accuracy: 0.001)
        XCTAssertEqual(report.worldMetrics.dimensionsMM, SIMD3<Float>(4, 6, 8))
    }

    func testTranslationAndRotationDoNotChangeVolume() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let baseline = analyze(mesh).worldMetrics.absoluteVolumeMM3
        let transform = ObjectTransform(translation: SIMD3<Float>(10, -4, 2),
                                        rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(35, 20, 70)))
        XCTAssertEqual(MeshDiagnostics.analyze(mesh: mesh, transform: transform).worldMetrics.absoluteVolumeMM3,
                       baseline)
    }

    func testWorldBoundsUseExistingEightCornerConvention() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(translation: SIMD3<Float>(3, 4, 5),
                                        rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(0, 45, 0)),
                                        scale: SIMD3<Float>(2, 3, 4))
        let report = MeshDiagnostics.analyze(mesh: mesh, transform: transform)
        let dimensions = try XCTUnwrap(ObjectDimensions.make(mesh: mesh, transform: transform))
        XCTAssertEqual(report.worldMetrics.bounds, dimensions.worldBounds)
    }

    func testHealthyOpenIsolatedAndErrorSeverities() throws {
        XCTAssertEqual(analyze(try PrimitiveMeshBuilder.cube(size: 2)).severity, .healthy)
        XCTAssertEqual(analyze(triangleMesh()).severity, .warning)
        let isolated = makeMesh(triangleMesh().vertices.map(\.position) + [SIMD3(2, 2, 2)], [0, 1, 2])
        XCTAssertEqual(analyze(isolated).severity, .warning)
        let degenerate = makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)], [0, 1, 2])
        XCTAssertEqual(analyze(degenerate).severity, .error)
    }

    func testCapabilitiesMatchSubdivisionAndSTLPolicies() throws {
        let cube = analyze(try PrimitiveMeshBuilder.cube(size: 2))
        XCTAssertTrue(cube.canSubdivide)
        XCTAssertTrue(cube.canExportSTL)
        XCTAssertNotNil(cube.subdivision.estimate)
        let open = analyze(triangleMesh())
        XCTAssertTrue(open.canSubdivide)
        XCTAssertTrue(open.canExportSTL)
        XCTAssertTrue(open.stlExport.hasPrintabilityWarning)
    }

    func testNonManifoldMeshCanExportUnderExistingExporterButCannotSubdivide() {
        let mesh = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)],
            [0, 1, 2, 1, 0, 3, 0, 1, 4]
        )
        let report = analyze(mesh)
        XCTAssertFalse(report.canSubdivide)
        XCTAssertTrue(report.canExportSTL)
        XCTAssertTrue(report.stlExport.hasPrintabilityWarning)
    }

    func testDiagnosticsCacheReusesUnchangedMesh() throws {
        let cache = MeshDiagnosticsCache(), mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let first = cache.report(mesh: mesh, transform: .identity)
        let second = cache.report(mesh: mesh, transform: .identity)
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.analysisCount, 1)
        XCTAssertEqual(cache.reuseCount, 1)
    }

    func testDiagnosticsCacheInvalidatesForSculptRevisionTransformAndTopology() throws {
        let cache = MeshDiagnosticsCache()
        var mesh = try PrimitiveMeshBuilder.cube(size: 2)
        _ = cache.report(mesh: mesh, transform: .identity)
        _ = mesh.updatePositions([0: mesh.vertices[0].position + SIMD3<Float>(0.01, 0, 0)])
        _ = cache.report(mesh: mesh, transform: .identity)
        _ = cache.report(mesh: mesh, transform: ObjectTransform(translation: SIMD3<Float>(1, 0, 0)))
        let replacement = try PrimitiveMeshBuilder.cube(size: 2)
        _ = cache.report(mesh: replacement, transform: .identity)
        XCTAssertEqual(cache.analysisCount, 4)
    }

    @MainActor func testWorkspaceAnalysisIsReadOnlyAndHistoryNeutral() throws {
        let model = WorkspaceModel()
        let beforeMesh = model.mesh, beforeRuntime = model.mesh.runtime
        let beforeTransform = model.objectTransform, beforeCamera = model.camera
        let undo = model.undoCount, redo = model.redoCount
        let report = try model.analyzeCurrentMesh()
        XCTAssertEqual(model.mesh, beforeMesh)
        XCTAssertEqual(model.mesh.runtime, beforeRuntime)
        XCTAssertEqual(model.objectTransform, beforeTransform)
        XCTAssertEqual(model.camera, beforeCamera)
        XCTAssertEqual(model.undoCount, undo)
        XCTAssertEqual(model.redoCount, redo)
        XCTAssertEqual(model.currentMeshDiagnosticsReport, report)
    }

    @MainActor func testWorkspaceReportBecomesStaleAfterTransformUndoAndSculptRevision() throws {
        let model = WorkspaceModel()
        _ = try model.analyzeCurrentMesh()
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 0, 0)))
        XCTAssertTrue(model.isMeshDiagnosticsStale)
        XCTAssertNil(model.currentMeshDiagnosticsReport)
        model.undo()
        XCTAssertFalse(model.isMeshDiagnosticsStale)
        XCTAssertNotNil(model.currentMeshDiagnosticsReport)
        _ = model.mesh.updatePositions([0: model.mesh.vertices[0].position + SIMD3<Float>(0.001, 0, 0)])
        XCTAssertTrue(model.isMeshDiagnosticsStale)
    }

    @MainActor func testWorkspaceLoadClearsDiagnosticsAndProjectDoesNotPersistIt() throws {
        let model = WorkspaceModel()
        _ = try model.analyzeCurrentMesh()
        model.meshDiagnosticsOverlayOptions.boundaryEdges = false
        let data = try model.projectData()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Diagnostics"))
        model.load(data: data)
        XCTAssertNil(model.meshDiagnosticsReport)
        XCTAssertEqual(try ProjectCodec.decode(data).formatVersion, 1)
    }

    @MainActor func testWorkspaceRejectsAnalysisDuringActiveStroke() {
        let model = WorkspaceModel()
        model.beginStroke()
        XCTAssertThrowsError(try model.analyzeCurrentMesh()) { error in
            XCTAssertEqual(error as? WorkspaceError, .activeDiagnosticsEdit)
        }
        model.cancelStroke()
    }

    func testOverlayBuildsBoundaryNonManifoldWindingDegenerateAndIsolatedRepresentatives() {
        XCTAssertEqual(analyze(triangleMesh()).overlay.boundaryEdges.count, 3)
        let nonManifold = makeMesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)],
            [0, 1, 2, 1, 0, 3, 0, 1, 4]
        )
        XCTAssertEqual(analyze(nonManifold).overlay.nonManifoldEdges.count, 1)
        let degenerate = makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3, 3, 3)], [0, 1, 2])
        let overlay = analyze(degenerate).overlay
        XCTAssertEqual(overlay.degenerateTrianglePoints.count, 1)
        XCTAssertEqual(overlay.isolatedVertexPoints.count, 1)
    }

    func testOverlayCategoryFilterAndVisibility() {
        let source = MeshDiagnosticsOverlayData(
            boundaryEdges: [MeshDiagnosticSegment(start: .zero, end: SIMD3<Float>(1, 0, 0))],
            nonManifoldEdges: [MeshDiagnosticSegment(start: .zero, end: SIMD3<Float>(0, 1, 0))],
            windingConflicts: [], degenerateTrianglePoints: [.zero],
            isolatedVertexPoints: [SIMD3<Float>(repeating: 1)]
        )
        var options = MeshDiagnosticsOverlayOptions()
        options.boundaryEdges = false
        options.degenerateTriangles = false
        let filtered = source.filtered(by: options)
        XCTAssertTrue(filtered.boundaryEdges.isEmpty)
        XCTAssertTrue(filtered.degenerateTrianglePoints.isEmpty)
        XCTAssertEqual(filtered.nonManifoldEdges.count, 1)
        options.isVisible = false
        XCTAssertTrue(source.filtered(by: options).isEmpty)
    }

    func testOverlayRepresentativeLimitAndHealthyMeshEmptyOverlay() throws {
        let positions = (0..<1_005).map { SIMD3<Float>(Float($0), 2, 3) }
            + [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        let mesh = makeMesh(positions, [1_005, 1_006, 1_007])
        let report = analyze(mesh)
        XCTAssertEqual(report.topology.isolatedVertexCount, 1_005)
        XCTAssertEqual(report.overlay.isolatedVertexPoints.count, MeshTopologyDiagnostics.representativeLimit)
        XCTAssertTrue(analyze(try PrimitiveMeshBuilder.cube(size: 2)).overlay.isEmpty)
    }

    func testOverlayUsesObjectLocalPointsAndModelTransform() {
        let local = analyze(triangleMesh()).overlay.boundaryEdges[0]
        let transform = ObjectTransform(translation: SIMD3<Float>(5, 6, 7), scale: SIMD3<Float>(2, 3, 4))
        let worldStart = transform.worldPosition(fromLocal: local.start)
        XCTAssertEqual(worldStart, transform.worldPosition(fromLocal: local.start))
        XCTAssertNotEqual(worldStart, local.start)
    }

    func testOverlayUploadRevisionAndMetalLayouts() {
        XCTAssertTrue(MeshDiagnosticsOverlayRenderer.requiresUpload(previousRevision: nil, newRevision: 1))
        XCTAssertFalse(MeshDiagnosticsOverlayRenderer.requiresUpload(previousRevision: 1, newRevision: 1))
        XCTAssertTrue(MeshDiagnosticsOverlayRenderer.requiresUpload(previousRevision: 1, newRevision: 2))
        XCTAssertEqual(MemoryLayout<DiagnosticsOverlayVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<DiagnosticsOverlayUniforms>.stride, 144)
    }

    func testBenchmarkContainsAllDiagnosticsCasesAndUniqueEdgeContext() {
        let names = BenchmarkCase.allCases.map(\.rawValue)
        XCTAssertTrue(names.contains("Diagnostics topology"))
        XCTAssertTrue(names.contains("Diagnostics geometry metrics"))
        XCTAssertTrue(names.contains("Diagnostics world metrics"))
        XCTAssertTrue(names.contains("Diagnostics overlay generation"))
        for preset in BenchmarkPreset.allCases {
            let mesh = preset.makeMesh()
            XCTAssertGreaterThan(MeshTopologyDiagnostics.analyze(mesh).uniqueEdgeCount, 0)
        }
    }

    func testDiagnosticsReportIsNotCodableProjectState() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        _ = analyze(mesh)
        let project = ForgeProject(mesh: mesh, camera: CameraState(), transform: .identity)
        let data = try ProjectCodec.encode(project)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("boundaryEdgeCount"))
        XCTAssertFalse(json.contains("meshDiagnostics"))
        XCTAssertEqual(try ProjectCodec.decode(data).formatVersion, 1)
    }

    private func analyze(_ mesh: EditableMesh) -> MeshDiagnosticsReport {
        MeshDiagnostics.analyze(mesh: mesh, transform: .identity)
    }

    private func triangleMesh() -> EditableMesh {
        makeMesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2])
    }

    private func makeMesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        EditableMesh(vertices: positions.map { MeshVertex(position: $0, normal: SIMD3<Float>(0, 0, 1)) },
                     indices: indices)
    }

    private func reversedWinding(_ mesh: EditableMesh) -> EditableMesh {
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            indices.append(contentsOf: [mesh.indices[offset], mesh.indices[offset + 2], mesh.indices[offset + 1]])
        }
        return EditableMesh(vertices: mesh.vertices, indices: indices)
    }
}
