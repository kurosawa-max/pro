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

    func testMultiFaceSplitMergeRoundTripWithTransformAndRemoteComponent() throws {
        let first = tetrahedron()
        let source = twoTetrahedra()
        let split = try MeshExactSeamEdit.edit(
            mesh: source,
            transform: transformed(),
            selection: try selected(source, [0, 1]),
            operation: .splitRegion
        )
        XCTAssertEqual(split.mesh.indices.count, source.indices.count)
        XCTAssertEqual(split.estimate.resultingComponentCount,
                       split.estimate.sourceComponentCount + 1)
        XCTAssertEqual(split.estimate.resultingBoundaryEdgeCount,
                       split.estimate.sourceBoundaryEdgeCount + 2 * split.estimate.seamEdgeCount)
        XCTAssertEqual(
            Array(split.mesh.vertices.prefix(source.vertices.count)).map(\.position),
            source.vertices.map(\.position)
        )
        XCTAssertEqual(Array(split.mesh.indices[(first.indices.count)...]),
                       Array(source.indices[(first.indices.count)...]))

        let merge = try MeshExactSeamEdit.edit(
            mesh: split.mesh,
            transform: transformed(),
            selection: try selected(split.mesh, [0, 1]),
            operation: .mergeExactSeam
        )
        XCTAssertEqual(merge.mesh.vertices.map(\.position), source.vertices.map(\.position))
        XCTAssertEqual(merge.mesh.indices, source.indices)
        XCTAssertEqual(merge.mesh.bounds, source.bounds)
    }

    func testSplitRejectsVertexOnlyContactWithOutsideComponentExactly() throws {
        let source = tetrahedronSharingVertexWithRemoteComponent()
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source,
            transform: .identity,
            selection: try selected(source, [0]),
            operation: .splitRegion
        )) {
            XCTAssertEqual($0 as? MeshSeamEditError, .vertexOnlyContact)
        }
    }

    func testMergeRejectsThirdExactPositionVertexAsAmbiguous() throws {
        let source = tetrahedron()
        let split = try MeshExactSeamEdit.edit(
            mesh: source,
            transform: .identity,
            selection: try selected(source, [0]),
            operation: .splitRegion
        )
        let augmented = appendRemoteTetrahedron(
            to: split.mesh,
            firstPosition: source.vertices[0].position
        )
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: augmented,
            transform: .identity,
            selection: try selected(augmented, [0]),
            operation: .mergeExactSeam
        )) {
            XCTAssertEqual($0 as? MeshSeamEditError, .ambiguousCounterpart)
        }
    }

    func testConservativePreflightRejectsBeforeDiagnosticsAndIncidence() throws {
        let source = tetrahedron()
        let exactLimit = try MeshExactSeamEdit.conservativeMemoryEstimate(
            vertexCount: source.vertices.count,
            indexCount: source.indices.count,
            operation: .splitRegion
        )
        let instrumentation = MeshSeamMemoryInstrumentation()
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source,
            transform: .identity,
            selection: try selected(source, [0]),
            operation: .splitRegion,
            memoryLimit: exactLimit - 1,
            memoryInstrumentation: instrumentation
        )) {
            XCTAssertEqual($0 as? MeshSeamEditError, .workingMemoryLimitExceeded)
        }
        XCTAssertEqual(instrumentation.preflightCount, 1)
        XCTAssertEqual(instrumentation.sourceDiagnosticsCount, 0)
        XCTAssertEqual(instrumentation.sourceIncidenceCount, 0)
        XCTAssertEqual(instrumentation.resultFanScanCount, 0)

        let accepted = MeshSeamMemoryInstrumentation()
        XCTAssertNoThrow(try MeshExactSeamEdit.edit(
            mesh: source,
            transform: .identity,
            selection: try selected(source, [0]),
            operation: .splitRegion,
            memoryLimit: exactLimit,
            memoryInstrumentation: accepted
        ))
        XCTAssertEqual(accepted.preflightCount, 1)
        XCTAssertEqual(accepted.sourceDiagnosticsCount, 1)
        XCTAssertEqual(accepted.sourceIncidenceCount, 1)
        XCTAssertEqual(accepted.resultFanScanCount, 1)
    }

    func testRefinedEstimateMatchesPreviewForSplitAndMerge() throws {
        let source = tetrahedron()
        let split = try MeshExactSeamEdit.edit(
            mesh: source,
            transform: .identity,
            selection: try selected(source, [0]),
            operation: .splitRegion
        )
        let splitExpected = try MeshExactSeamEdit.refinedMemoryEstimate(
            sourceVertexCount: source.vertices.count,
            sourceIndexCount: source.indices.count,
            resultVertexCount: split.mesh.vertices.count,
            seamVertexCount: split.estimate.seamVertexCount,
            seamEdgeCount: split.estimate.seamEdgeCount,
            operation: .splitRegion
        )
        XCTAssertEqual(split.estimate.estimatedWorkingByteCount, splitExpected)

        let merge = try MeshExactSeamEdit.edit(
            mesh: split.mesh,
            transform: .identity,
            selection: try selected(split.mesh, [0]),
            operation: .mergeExactSeam
        )
        let mergeExpected = try MeshExactSeamEdit.refinedMemoryEstimate(
            sourceVertexCount: split.mesh.vertices.count,
            sourceIndexCount: split.mesh.indices.count,
            resultVertexCount: merge.mesh.vertices.count,
            seamVertexCount: merge.estimate.seamVertexCount,
            seamEdgeCount: merge.estimate.seamEdgeCount,
            operation: .mergeExactSeam
        )
        XCTAssertEqual(merge.estimate.estimatedWorkingByteCount, mergeExpected)
        XCTAssertNotEqual(splitExpected, mergeExpected)
        XCTAssertThrowsError(try MeshExactSeamEdit.conservativeMemoryEstimate(
            vertexCount: Int.max,
            indexCount: 3,
            operation: .splitRegion
        )) {
            XCTAssertEqual($0 as? MeshSeamEditError, .arithmeticOverflow)
        }
    }

    func testMergeRejectsSelectedComponentInteriorVertexOnlyContact() throws {
        let split = try splitOctahedronTop()
        let shared = appendRemoteTetrahedronSharingVertex(
            to: split.mesh, sharedVertexID: 0)
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: shared,
            transform: .identity,
            selection: try selected(shared, [0, 1, 2, 3]),
            operation: .mergeExactSeam
        )) {
            XCTAssertEqual($0 as? MeshSeamEditError, .vertexOnlyContact)
        }
    }

    func testMergeRejectsCounterpartComponentInteriorVertexOnlyContact() throws {
        let split = try splitOctahedronTop()
        let shared = appendRemoteTetrahedronSharingVertex(
            to: split.mesh, sharedVertexID: 1)
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: shared,
            transform: .identity,
            selection: try selected(shared, [0, 1, 2, 3]),
            operation: .mergeExactSeam
        )) {
            XCTAssertEqual($0 as? MeshSeamEditError, .vertexOnlyContact)
        }
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
            operation: .splitRegion)) {
            XCTAssertEqual($0 as? MeshSeamEditError, .multipleHostComponents)
        }
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: source, transform: .identity, selection: try selected(source, [0, 1, 2, 3]),
            operation: .splitRegion)) { XCTAssertEqual($0 as? MeshSeamEditError, .wholeComponentSelected) }

        let open = mesh(
            [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)],
            [0, 1, 2, 0, 2, 3])
        XCTAssertThrowsError(try MeshExactSeamEdit.edit(
            mesh: open, transform: .identity, selection: try selected(open, [0]),
            operation: .splitRegion)) {
            XCTAssertEqual($0 as? MeshSeamEditError, .selectedRegionTouchesOpenBoundary)
        }
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

    func testWorkspaceRequestIdentityRejectsOldSuccessFailureAndOperationChange() throws {
        let model = WorkspaceModel()
        model.mesh = tetrahedron()
        model.setInteractionMode(.faceSelect)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        try model.prepareForMeshSeamEdit()

        let requestA = UUID()
        try model.beginMeshSeamEditPreviewRequest(requestA)
        let candidateA = try model.makeMeshSeamEditPreviewCandidate(
            operation: .splitRegion, requestID: requestA)
        model.discardMeshSeamEditPreview(requestID: requestA)
        let requestB = UUID()
        try model.beginMeshSeamEditPreviewRequest(requestB)
        XCTAssertFalse(model.completeMeshSeamEditPreviewRequest(
            requestID: requestA, candidate: candidateA))
        XCTAssertNil(model.meshSeamEditPreview)
        XCTAssertTrue(model.isMeshSeamEditRunning)

        let candidateB = try model.makeMeshSeamEditPreviewCandidate(
            operation: .splitRegion, requestID: requestB)
        XCTAssertTrue(model.completeMeshSeamEditPreviewRequest(
            requestID: requestB, candidate: candidateB))
        XCTAssertFalse(model.isMeshSeamEditRunning)
        XCTAssertEqual(model.meshSeamEditPreview, candidateB)

        model.discardMeshSeamEditPreview()
        XCTAssertNil(model.meshSeamEditPreview)
        XCTAssertThrowsError(try model.applyMeshSeamEdit(preview: candidateB)) {
            XCTAssertEqual($0 as? MeshSeamEditError, .stalePreview)
        }
        XCTAssertFalse(model.isMeshSeamEditRunning)
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

    private func tetrahedronSharingVertexWithRemoteComponent() -> EditableMesh {
        let source = tetrahedron()
        let positions = source.vertices.map(\.position) + [
            SIMD3<Float>(8, 0, 0),
            SIMD3<Float>(9, 1, 0),
            SIMD3<Float>(9, 0, 1)
        ]
        let remote: [UInt32] = [
            0, 4, 5,
            0, 6, 4,
            0, 5, 6,
            4, 6, 5
        ]
        return mesh(positions, source.indices + remote)
    }

    private func appendRemoteTetrahedron(
        to source: EditableMesh,
        firstPosition: SIMD3<Float>
    ) -> EditableMesh {
        let base = UInt32(source.vertices.count)
        var positions: [SIMD3<Float>] = source.vertices.map(\.position)
        positions.append(firstPosition)
        positions.append(firstPosition + SIMD3<Float>(7, 1, 0))
        positions.append(firstPosition + SIMD3<Float>(7, 0, 1))
        positions.append(firstPosition + SIMD3<Float>(8, 1, 1))
        let remote: [UInt32] = [
            base, base + 2, base + 1,
            base, base + 1, base + 3,
            base, base + 3, base + 2,
            base + 1, base + 2, base + 3
        ]
        return mesh(positions, source.indices + remote)
    }

    private func splitOctahedronTop() throws -> MeshSeamEditResult {
        let source = mesh(
            [
                SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0),
                SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, -1)
            ],
            [
                0, 3, 2, 0, 4, 3, 0, 5, 4, 0, 2, 5,
                1, 2, 3, 1, 3, 4, 1, 4, 5, 1, 5, 2
            ]
        )
        return try MeshExactSeamEdit.edit(
            mesh: source,
            transform: .identity,
            selection: try selected(source, [0, 1, 2, 3]),
            operation: .splitRegion
        )
    }

    private func appendRemoteTetrahedronSharingVertex(
        to source: EditableMesh,
        sharedVertexID: UInt32
    ) -> EditableMesh {
        var positions = source.vertices.map(\.position)
        let base = UInt32(positions.count)
        let anchor = source.vertices[Int(sharedVertexID)].position
        positions.append(anchor + SIMD3<Float>(8, 0, 0))
        positions.append(anchor + SIMD3<Float>(8, 1, 0))
        positions.append(anchor + SIMD3<Float>(8, 0, 1))
        let remote: [UInt32] = [
            sharedVertexID, base + 1, base,
            sharedVertexID, base, base + 2,
            sharedVertexID, base + 2, base + 1,
            base, base + 1, base + 2
        ]
        return mesh(positions, source.indices + remote)
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
