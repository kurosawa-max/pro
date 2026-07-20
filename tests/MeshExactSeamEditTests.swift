import XCTest
import simd
@testable import Forge3D

@MainActor
final class MeshExactSeamEditTests: XCTestCase {
    func testSplitSingleFacePreservesGeometryAndDeterministicOrdering() throws {
        let source = tetrahedron()
        let selection = try selected(source, [0])
        let result = try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: selection,
            operation: .splitRegion)

        XCTAssertEqual(result.estimate.seamVertexCount, 3)
        XCTAssertEqual(result.estimate.seamEdgeCount, 3)
        XCTAssertEqual(result.mesh.vertices.count, source.vertices.count + 3)
        XCTAssertEqual(result.mesh.indices.count, source.indices.count)
        XCTAssertEqual(
            Array(result.mesh.vertices.prefix(source.vertices.count)).map(\.position),
            source.vertices.map(\.position)
        )
        XCTAssertEqual(Array(result.mesh.indices[3...]), Array(source.indices[3...]))
        XCTAssertEqual(Array(result.mesh.indices[0...2]), [4, 6, 5])
        XCTAssertEqual(result.estimate.sourceComponentCount, 1)
        XCTAssertEqual(result.estimate.resultingComponentCount, 2)
        XCTAssertEqual(result.estimate.sourceBoundaryEdgeCount, 0)
        XCTAssertEqual(result.estimate.resultingBoundaryEdgeCount, 6)
        XCTAssertEqual(result.estimate.sourceBounds, result.estimate.resultBounds)
        assertSameTrianglePositions(source, result.mesh)
    }

    func testSplitThenMergeRestoresOriginalGeometryAndTopology() throws {
        let source = tetrahedron()
        let split = try MeshExactSeamEdit.edit(
            mesh: source, transform: transformed(), selection: try selected(source, [0]),
            operation: .splitRegion)
        let merge = try MeshExactSeamEdit.edit(
            mesh: split.mesh, transform: transformed(), selection: try selected(split.mesh, [0]),
            operation: .mergeExactSeam)

        XCTAssertEqual(merge.mesh.vertices.map(\.position), source.vertices.map(\.position))
        XCTAssertEqual(merge.mesh.indices, source.indices)
        XCTAssertEqual(merge.estimate.resultingComponentCount, 1)
        XCTAssertEqual(merge.estimate.resultingBoundaryEdgeCount, 0)
        XCTAssertEqual(merge.estimate.resultBounds, source.bounds)
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(merge.mesh),
                       MeshTopologyDiagnostics.analyze(source))
    }

    func testMergeUsesCounterpartVerticesAndCompactsInSourceOrder() throws {
        let source = tetrahedron()
        let split = try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, [0]),
            operation: .splitRegion)
        let merge = try MeshExactSeamEdit.edit(
            mesh: split.mesh, transform: .identity, selection: try selected(split.mesh, [0]),
            operation: .mergeExactSeam)
        XCTAssertEqual(merge.mesh.vertices.count, source.vertices.count)
        XCTAssertEqual(merge.mesh.vertices.map(\.position), source.vertices.map(\.position))
        XCTAssertEqual(merge.mesh.indices, source.indices)
    }

    func testSignedZeroPairsExactly() throws {
        var source = tetrahedron()
        let positions = source.vertices.map(\.position)
        source = mesh(positions.map { SIMD3<Float>($0.x == 0 ? -0.0 : $0.x, $0.y, $0.z) }, source.indices)
        let split = try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, [0]),
            operation: .splitRegion)
        XCTAssertNoThrow(try MeshExactSeamEdit.edit(
            mesh: split.mesh, transform: .identity, selection: try selected(split.mesh, [0]),
            operation: .mergeExactSeam))
    }

    func testSplitRejectsEmptyDisconnectedWholeAndOpenBoundarySelections() throws {
        let source = tetrahedron()
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, []),
            operation: .splitRegion)) { XCTAssertEqual($0 as? MeshSeamEditError, .emptySelection) }
        let detached = twoTetrahedra()
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: detached, transform: .identity, selection: try selected(detached, [0, 4]),
            operation: .splitRegion))
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, [0, 1, 2, 3]),
            operation: .splitRegion)) { XCTAssertEqual($0 as? MeshSeamEditError, .wholeComponentSelected) }

        let open = mesh(
            [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)],
            [0, 1, 2, 0, 2, 3])
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: open, transform: .identity, selection: try selected(open, [0]),
            operation: .splitRegion))
    }

    func testMergeRequiresCompleteComponentAndRejectsMissingCounterpart() throws {
        let source = tetrahedron()
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, [0]),
            operation: .mergeExactSeam)) {
            XCTAssertEqual($0 as? MeshSeamEditError, .selectedFacesMustEqualComponent)
        }
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity,
            selection: try selected(source, [0, 1, 2, 3]),
            operation: .mergeExactSeam))
    }

    func testPreviewSourceIdentityTracksSelectionOperationTransformAndMesh() throws {
        let source = tetrahedron()
        var selection = try selected(source, [0])
        let meshVersion = TopologyEditChangeVersion()
        let transformVersion = TopologyEditChangeVersion()
        let preview = try MeshExactSeamEdit.makePreview(
            mesh: source, transform: .identity, selection: selection,
            operation: .splitRegion, meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion)
        XCTAssertTrue(preview.source.matchesRuntimeIdentity(
            mesh: source, transform: .identity, selection: selection,
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            operation: .splitRegion))
        _ = try selection.set(1, selected: true)
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: source, transform: .identity, selection: selection,
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            operation: .splitRegion))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: source, transform: .identity, selection: try selected(source, [0]),
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            operation: .mergeExactSeam))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: source, transform: transformed(), selection: try selected(source, [0]),
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            operation: .splitRegion))
    }

    func testRequestCoordinatorOldRequestCannotPublishOrReleaseNewBusyState() {
        var coordinator = TopologyPreviewRequestCoordinator()
        let first = coordinator.begin()
        let second = coordinator.begin()
        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertFalse(coordinator.finish(first))
        XCTAssertTrue(coordinator.isCalculating)
        XCTAssertTrue(coordinator.finish(second))
        XCTAssertFalse(coordinator.isCalculating)
    }

    func testWorkspaceSplitIsOneUndoCommandAndUndoRedoClearRuntimeSelection() throws {
        let model = WorkspaceModel()
        model.mesh = tetrahedron()
        model.setInteractionMode(.faceSelect)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        try model.prepareForMeshSeamEdit()
        let requestID = UUID()
        try model.beginMeshSeamEditPreviewRequest(requestID)
        let preview = try model.makeMeshSeamEditPreviewCandidate(
            operation: .splitRegion, requestID: requestID)
        XCTAssertTrue(model.completeMeshSeamEditPreviewRequest(
            requestID: requestID, candidate: preview))
        let source = model.mesh
        _ = try model.applyMeshSeamEdit(preview: preview)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.meshSeamEditPreview)
        model.undo()
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.selectedFaceCount, 0)
        model.redo()
        XCTAssertNotEqual(model.mesh, source)
        XCTAssertEqual(model.selectedFaceCount, 0)
    }

    func testWorkspaceStaleApplyAndFailureRemainAtomic() throws {
        let model = WorkspaceModel()
        model.mesh = tetrahedron()
        model.setInteractionMode(.faceSelect)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        try model.prepareForMeshSeamEdit()
        let requestID = UUID()
        try model.beginMeshSeamEditPreviewRequest(requestID)
        let preview = try model.makeMeshSeamEditPreviewCandidate(
            operation: .splitRegion, requestID: requestID)
        XCTAssertTrue(model.completeMeshSeamEditPreviewRequest(
            requestID: requestID, candidate: preview))
        let source = model.mesh
        XCTAssertTrue(model.applyFaceSelectionHit(1))
        XCTAssertThrowsError(try model.applyMeshSeamEdit(preview: preview)) {
            XCTAssertEqual($0 as? MeshSeamEditError, .stalePreview)
        }
        XCTAssertEqual(model.mesh, source)
        XCTAssertFalse(model.isMeshSeamEditRunning)
    }

    func testFormatVersionAndOrdinaryMeshPersistenceRemainUnchanged() throws {
        let source = tetrahedron()
        let result = try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, [0]),
            operation: .splitRegion)
        let project = ForgeProject(mesh: result.mesh, camera: CameraState(), transform: .identity)
        let data = try ProjectCodec.encode(project)
        let decoded = try ProjectCodec.decode(data)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.mesh, result.mesh)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("seam"))
        XCTAssertFalse(text.contains("splitRegion"))
    }

    func testUIContainsCompactAccessibleSafetyContract() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("src/UI/MeshExactSeamEditView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("Form"))
        XCTAssertTrue(source.contains("accessibilityHint"))
        XCTAssertTrue(source.contains("open, coincident seam"))
        XCTAssertTrue(source.contains("bit-exact"))
        XCTAssertTrue(source.contains("isBusy"))
    }

    private func tetrahedron() -> EditableMesh {
        mesh(
            [SIMD3<Float>(1, 1, 1), SIMD3<Float>(-1, -1, 1),
             SIMD3<Float>(-1, 1, -1), SIMD3<Float>(1, -1, -1)],
            [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3])
    }

    private func twoTetrahedra() -> EditableMesh {
        let first = tetrahedron()
        let shifted = first.vertices.map { $0.position + SIMD3<Float>(5, 0, 0) }
        return mesh(first.vertices.map(\.position) + shifted,
                    first.indices + first.indices.map { $0 + 4 })
    }

    private func transformed() -> ObjectTransform {
        ObjectTransform(translation: SIMD3<Float>(12, -7, 3),
                        rotation: simd_quatf(
                            angle: .pi / 5,
                            axis: simd_normalize(SIMD3<Float>(1, 2, 3))).vector,
                        scale: SIMD3<Float>(2, 0.5, 3))
    }

    private func selected(_ mesh: EditableMesh, _ faces: [Int]) throws -> FaceSelection {
        var selection = try FaceSelection(
            sourceTopologyID: mesh.runtime.topologyID,
            sourceTopologyRevision: mesh.runtime.topologyRevision,
            triangleCount: mesh.indices.count / 3)
        _ = try selection.formUnion(faces)
        return selection
    }

    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var value = EditableMesh(
            vertices: positions.map { MeshVertex(position: $0, normal: SIMD3<Float>(0, 1, 0)) },
            indices: indices)
        value.recalculateNormals(recordChange: false)
        _ = value.adjacency()
        return value
    }

    private func assertSameTrianglePositions(
        _ source: EditableMesh, _ result: EditableMesh,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for face in 0..<(source.indices.count / 3) {
            let sourcePoints = (0..<3).map {
                source.vertices[Int(source.indices[face * 3 + $0])].position
            }
            let resultPoints = (0..<3).map {
                result.vertices[Int(result.indices[face * 3 + $0])].position
            }
            XCTAssertEqual(resultPoints, sourcePoints, file: file, line: line)
        }
    }
}
