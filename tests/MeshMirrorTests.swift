import MetalKit
import SwiftUI
import XCTest
import simd
@testable import Forge3D

final class MeshMirrorTests: XCTestCase {
    func testDefaultOptionsUseLocalXZeroPlane() {
        XCTAssertEqual(MeshMirrorOptions().axis, .x)
    }

    func testOpenHalfMeshWeldsSeamIntoClosedResult() throws {
        let source = try openHalfBox()
        let result = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(result.estimate.openComponentCount, 1)
        XCTAssertEqual(result.estimate.closedComponentCount, 0)
        XCTAssertEqual(result.estimate.seamLoopCount, 1)
        XCTAssertEqual(result.estimate.boundaryEdgeCount, 4)
        XCTAssertEqual(result.estimate.seamVertexCount, 4)
        XCTAssertEqual(result.estimate.maximumSeamSnapDistance, 0)
        XCTAssertEqual(result.estimate.resultingVertexCount, 12)
        XCTAssertEqual(result.estimate.resultingTriangleCount, 20)
        XCTAssertEqual(result.estimate.resultingComponentCount, 1)
        assertHealthyClosed(result.mesh, components: 1)
    }

    func testClosedComponentCreatesDetachedMirroredShell() throws {
        let source = try shiftedCube(offset: SIMD3<Float>(3, 0, 0))
        let result = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(result.estimate.closedComponentCount, 1)
        XCTAssertEqual(result.estimate.openComponentCount, 0)
        XCTAssertEqual(result.estimate.boundaryEdgeCount, 0)
        XCTAssertEqual(result.estimate.seamVertexCount, 0)
        XCTAssertEqual(result.mesh.vertices.count, source.vertices.count * 2)
        XCTAssertEqual(result.mesh.indices.count, source.indices.count * 2)
        assertHealthyClosed(result.mesh, components: 2)
        XCTAssertTrue(result.mesh.vertices.prefix(source.vertices.count).allSatisfy { $0.position.x > 0 })
        XCTAssertTrue(result.mesh.vertices.suffix(source.vertices.count).allSatisfy { $0.position.x < 0 })
    }

    func testMixedOpenAndClosedComponentsHaveExpectedResultComponentCount() throws {
        let source = combine([
            try openHalfBox(yOffset: -4),
            try shiftedCube(offset: SIMD3<Float>(4, 4, 0)),
        ])
        let result = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(result.estimate.sourceComponentCount, 2)
        XCTAssertEqual(result.estimate.openComponentCount, 1)
        XCTAssertEqual(result.estimate.closedComponentCount, 1)
        XCTAssertEqual(result.estimate.resultingComponentCount, 3)
        assertHealthyClosed(result.mesh, components: 3)
    }

    func testAllAxesAndBothSourceSidesProduceSymmetricClosedMeshes() throws {
        for axis in MirrorAxis.allCases {
            for sign: Float in [1, -1] {
                let source = try orientedOpenHalfBox(axis: axis, sign: sign)
                let result = try MeshMirror.mirror(
                    mesh: source, transform: .identity, options: MeshMirrorOptions(axis: axis))
                XCTAssertEqual(
                    result.estimate.sourceSide,
                    sign > 0 ? .positive : .negative)
                let component = axisComponent(axis)
                XCTAssertEqual(
                    result.mesh.bounds.minimum[component],
                    -result.mesh.bounds.maximum[component],
                    accuracy: 0.000_001)
                assertHealthyClosed(result.mesh, components: 1)
            }
        }
    }

    func testSourceTrianglesStayFirstAndMirroredTrianglesReverseWinding() throws {
        let source = try openHalfBox()
        let result = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(Array(result.mesh.indices.prefix(source.indices.count)), source.indices)
        let sourceCount = source.indices.count
        for faceID in 0..<(source.indices.count / 3) {
            let sourceOffset = faceID * 3
            let mirrorOffset = sourceCount + sourceOffset
            let original = [
                source.indices[sourceOffset],
                source.indices[sourceOffset + 1],
                source.indices[sourceOffset + 2],
            ]
            let mirrored = [
                result.mesh.indices[mirrorOffset],
                result.mesh.indices[mirrorOffset + 1],
                result.mesh.indices[mirrorOffset + 2],
            ]
            let reflectedPositions = mirrored.map { result.mesh.vertices[Int($0)].position }
            XCTAssertEqual(reflectedPositions[0], reflect(source.vertices[Int(original[0])].position, axis: .x))
            XCTAssertEqual(reflectedPositions[1], reflect(source.vertices[Int(original[2])].position, axis: .x))
            XCTAssertEqual(reflectedPositions[2], reflect(source.vertices[Int(original[1])].position, axis: .x))
        }
    }

    func testSeamWithinToleranceSnapsExactlyToZero() throws {
        let source = try openHalfBox(seamCoordinate: 0.000_005)
        let result = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertGreaterThan(result.estimate.snappedVertexCount, 0)
        XCTAssertEqual(result.estimate.maximumSeamSnapDistance, 0.000_005, accuracy: 0.000_000_1)
        XCTAssertLessThanOrEqual(
            result.estimate.maximumSeamSnapDistance,
            result.estimate.seamTolerance)
        XCTAssertEqual(result.mesh.vertices.filter { $0.position.x == 0 }.count, 4)
        assertHealthyClosed(result.mesh, components: 1)
    }

    func testSnapCollisionBetweenDistinctVerticesIsRejected() throws {
        let first = try openHalfBox(seamCoordinate: 0, yOffset: 0)
        let second = try openHalfBox(seamCoordinate: 0.000_005, yOffset: 0)
        let source = combine([first, second])
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .seamSnapCollision)
        }
    }

    func testMeshCrossingPlaneIsRejectedWithoutCutting() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .crossesMirrorPlane)
        }
    }

    func testDisconnectedComponentsOnOppositeSidesAreRejectedAsMixedSides() throws {
        let source = combine([
            try shiftedCube(offset: SIMD3<Float>(3, -3, 0)),
            try shiftedCube(offset: SIMD3<Float>(-3, 3, 0)),
        ])
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .mixedSourceSides)
        }
    }

    func testClosedComponentTouchingPlaneIsRejected() throws {
        let source = try shiftedCube(offset: SIMD3<Float>(1, 0, 0))
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .closedComponentTouchesPlane)
        }
    }

    func testPlaneOnlyMeshIsClassifiedPrecisely() throws {
        var plane = EditableMesh(
            vertices: [
                MeshVertex(position: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(1, 0, 0)),
                MeshVertex(position: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(1, 0, 0)),
                MeshVertex(position: SIMD3<Float>(0, 0, 1), normal: SIMD3<Float>(1, 0, 0)),
            ],
            indices: [0, 1, 2])
        plane.recalculateNormals()
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: plane, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .noOffPlaneVertices)
        }
    }

    func testInteriorSeamEdgeIsClassifiedPrecisely() throws {
        let interiorSeam = interiorSeamEdgeMesh()
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: interiorSeam, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .seamInteriorEdge)
        }
    }

    func testOpenBoundaryAwayFromPlaneIsRejected() throws {
        let source = try openCube(offset: SIMD3<Float>(4, 0, 0))
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .openBoundaryOffPlane)
        }
    }

    func testDegenerateDuplicateNonManifoldAndNonFiniteSourcesAreRejected() throws {
        let healthy = try openHalfBox()
        var degenerateIndices = healthy.indices
        degenerateIndices.replaceSubrange(0..<3, with: [0, 0, 1])
        let degenerate = EditableMesh(vertices: healthy.vertices, indices: degenerateIndices)
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: degenerate, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .degenerateTriangle)
        }

        let duplicate = EditableMesh(
            vertices: healthy.vertices,
            indices: healthy.indices + Array(healthy.indices.prefix(3)))
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: duplicate, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .duplicateTriangle)
        }

        let nonManifold = nonManifoldMesh()
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: nonManifold, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .nonManifoldEdge)
        }

        var invalidVertices = healthy.vertices
        invalidVertices[0].position.x = .nan
        let nonFinite = EditableMesh(vertices: invalidVertices, indices: healthy.indices)
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: nonFinite, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .nonFiniteValue)
        }

        var windingIndices = healthy.indices
        windingIndices.swapAt(1, 2)
        let winding = EditableMesh(vertices: healthy.vertices, indices: windingIndices)
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: winding, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .windingConflict)
        }
    }

    func testInvalidEmptyAndIsolatedSourcesHaveExactErrors() throws {
        let empty = EditableMesh(vertices: [], indices: [])
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: empty, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .invalidMesh)
        }

        let healthy = try openHalfBox()
        let isolated = EditableMesh(
            vertices: healthy.vertices + [
                MeshVertex(position: SIMD3<Float>(5, 5, 5), normal: SIMD3<Float>(1, 0, 0)),
            ],
            indices: healthy.indices)
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: isolated, transform: .identity, options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .isolatedVertex)
        }
    }

    func testSeamTriangleInteriorVertexAndInvalidLoopHaveExactErrors() throws {
        let seamTriangle = try seamTriangleMesh()
        let invalidLoop = try seamBowTieMesh()
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: seamTriangle, transform: .identity,
            options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .seamTriangle)
        }
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: seamInteriorVertexMesh(), transform: .identity,
            options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .seamInteriorVertex)
        }
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: invalidLoop, transform: .identity,
            options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .invalidSeamLoop)
        }
    }

    func testSnapInducedCollapseAndDuplicateHaveDedicatedErrors() throws {
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: snapCollapseMesh(), transform: .identity,
            options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .seamSnapWouldCollapseTriangle)
        }
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: snapDuplicateMesh(), transform: .identity,
            options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .seamSnapWouldCreateDuplicateTriangle)
        }
    }

    func testComponentAnalysisVisitsEachUniqueEdgeOncePerLinearPass() throws {
        let closed = try (0..<24).map { index in
            try shiftedCube(offset: SIMD3<Float>(4, Float(index * 5), 0))
        }
        let open = try (0..<24).map { index in
            try openHalfBox(yOffset: Float(index * 5 + 200))
        }
        for source in [combine(closed), combine(open), combine(closed + open)] {
            let statistics = try MeshMirror.analysisStatistics(
                mesh: source, transform: .identity,
                options: MeshMirrorOptions(axis: .x))
            XCTAssertEqual(statistics.edgeGroupingVisitCount, statistics.uniqueEdgeCount)
            XCTAssertEqual(statistics.componentEdgeVisitCount, statistics.uniqueEdgeCount)
        }
    }

    func testManyComponentsKeepCountsOrderingAndFingerprintDeterministic() throws {
        let closed = try (0..<16).map { index in
            try shiftedCube(offset: SIMD3<Float>(4, Float(index * 5), 0))
        }
        let open = try (0..<16).map { index in
            try openHalfBox(yOffset: Float(index * 5 + 200))
        }
        let source = combine(closed + open)
        let first = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        let second = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(first.estimate.closedComponentCount, 16)
        XCTAssertEqual(first.estimate.openComponentCount, 16)
        XCTAssertEqual(first.estimate.resultingComponentCount, 48)
        XCTAssertEqual(first.estimate.boundaryEdgeCount, 16 * 4)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
        XCTAssertEqual(first.mesh.indices, second.mesh.indices)
        XCTAssertEqual(Array(first.mesh.indices.prefix(source.indices.count)), source.indices)
    }

    func testPreviewSourceKeyIncludesBoundaryAndMaximumSnapMetrics() throws {
        let source = try openHalfBox(seamCoordinate: 0.000_005)
        let preview = try MeshMirror.makePreview(
            mesh: source,
            transform: .identity,
            options: MeshMirrorOptions(axis: .x),
            meshChangeVersion: TopologyEditChangeVersion(),
            transformChangeVersion: TopologyEditChangeVersion())
        XCTAssertEqual(preview.estimate.boundaryEdgeCount, 4)
        XCTAssertEqual(preview.source.boundaryEdgeCount, preview.estimate.boundaryEdgeCount)
        XCTAssertEqual(
            preview.source.maximumSeamSnapDistance,
            preview.estimate.maximumSeamSnapDistance)
        XCTAssertGreaterThan(preview.source.maximumSeamSnapDistance, 0)
    }

    func testSeamToleranceAndMaximumSnapAreSafeAcrossAxesAndScales() throws {
        for axis in MirrorAxis.allCases {
            for sign: Float in [1, -1] {
                let source = try orientedOpenHalfBox(
                    axis: axis, sign: sign, seamCoordinate: 0.000_005)
                let estimate = try MeshMirror.estimate(
                    mesh: source, transform: .identity,
                    options: MeshMirrorOptions(axis: axis))
                XCTAssertTrue(estimate.seamTolerance.isFinite)
                XCTAssertGreaterThanOrEqual(estimate.seamTolerance, 0.000_01)
                XCTAssertEqual(
                    estimate.maximumSeamSnapDistance,
                    0.000_005,
                    accuracy: 0.000_000_1)
                XCTAssertLessThanOrEqual(
                    estimate.maximumSeamSnapDistance,
                    estimate.seamTolerance)
            }
        }

        var crossAxisHuge = try openHalfBox()
        var hugeVertices = crossAxisHuge.vertices
        for vertexID in hugeVertices.indices {
            hugeVertices[vertexID].position.y *= 100_000_000
            hugeVertices[vertexID].position.z *= 100_000_000
        }
        crossAxisHuge = mesh(
            positions: hugeVertices.map(\.position),
            indices: crossAxisHuge.indices)
        let crossAxisEstimate = try MeshMirror.estimate(
            mesh: crossAxisHuge, transform: .identity,
            options: MeshMirrorOptions(axis: .x))
        XCTAssertLessThanOrEqual(crossAxisEstimate.seamTolerance, 0.000_201)

        let farFromOrigin = try shiftedCube(offset: SIMD3<Float>(1_000_000, 0, 0))
        let farEstimate = try MeshMirror.estimate(
            mesh: farFromOrigin, transform: .identity,
            options: MeshMirrorOptions(axis: .x))
        XCTAssertTrue(farEstimate.seamTolerance.isFinite)
        XCTAssertLessThanOrEqual(farEstimate.seamTolerance, 0.000_201)
        XCTAssertEqual(farEstimate.maximumSeamSnapDistance, 0)

        var tiny = try openHalfBox()
        tiny = mesh(
            positions: tiny.vertices.map { $0.position * 0.000_001 },
            indices: tiny.indices)
        XCTAssertThrowsError(try MeshMirror.estimate(
            mesh: tiny, transform: .identity,
            options: MeshMirrorOptions(axis: .x))) {
            XCTAssertEqual($0 as? MeshMirrorError, .noOffPlaneVertices)
        }
    }

    func testResultAndFingerprintAreDeterministic() throws {
        let source = try openHalfBox()
        let first = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        let second = try MeshMirror.mirror(
            mesh: source, transform: .identity, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(first.mesh.vertices, second.mesh.vertices)
        XCTAssertEqual(first.mesh.indices, second.mesh.indices)
        XCTAssertEqual(first.estimate, second.estimate)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
        XCTAssertNotEqual(first.mesh.runtime.topologyID, second.mesh.runtime.topologyID)
    }

    func testSourceFaceReorderingPreservesDefinedSourceAndMirrorOrdering() throws {
        let source = try openHalfBox()
        let faces = stride(from: 0, to: source.indices.count, by: 3).map {
            Array(source.indices[$0..<($0 + 3)])
        }
        var reordered = EditableMesh(
            vertices: source.vertices,
            indices: faces.reversed().flatMap { $0 })
        reordered.recalculateNormals()
        _ = reordered.adjacency()
        let first = try MeshMirror.mirror(
            mesh: reordered, transform: .identity,
            options: MeshMirrorOptions(axis: .x))
        let second = try MeshMirror.mirror(
            mesh: reordered, transform: .identity,
            options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(Array(first.mesh.indices.prefix(reordered.indices.count)), reordered.indices)
        XCTAssertEqual(first.mesh.indices, second.mesh.indices)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
    }

    func testPreviewWorldBoundsUseCurrentTransformWithoutBakingIt() throws {
        let source = try openHalfBox()
        let transform = ObjectTransform(
            translation: SIMD3<Float>(100, -50, 25),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(17, 31, -43)),
            scale: SIMD3<Float>(0.5, 3, 7))
        let result = try MeshMirror.mirror(
            mesh: source, transform: transform, options: MeshMirrorOptions(axis: .x))
        XCTAssertEqual(result.estimate.resultWorldBounds, worldBounds(result.mesh, transform))
        XCTAssertEqual(Array(result.mesh.vertices.prefix(source.vertices.count)).map(\.position),
                       source.vertices.map(\.position))
    }

    func testWorkingMemoryArithmeticAndLimitsAreChecked() throws {
        XCTAssertThrowsError(try MeshMirror.estimatedWorkingBytes(
            sourceVertices: .max,
            sourceTriangles: 1,
            uniqueEdges: 1,
            resultingVertices: 1,
            resultingTriangles: 1)) {
            XCTAssertEqual($0 as? MeshMirrorError, .arithmeticOverflow)
        }
        XCTAssertEqual(MeshMirror.maximumVertices, 2_000_000)
        XCTAssertEqual(MeshMirror.maximumTriangles, 4_000_000)
        XCTAssertEqual(MeshMirror.maximumWorkingBytes, 768 * 1_024 * 1_024)
    }

    @MainActor
    func testWorkspaceApplyIsOneCommandAndPreservesNonTopologyState() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        let transform = ObjectTransform(
            translation: SIMD3<Float>(4, -2, 8),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 20, 30)),
            scale: SIMD3<Float>(2, 3, 4))
        model.updateTransform(transform)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.toggle)
        model.brush = .crease
        model.symmetry = SculptSymmetry(x: true, y: false, z: true)
        let camera = model.camera
        let undoCount = model.undoCount
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        let result = try model.applyMeshMirror(preview: preview)
        XCTAssertEqual(model.undoCount, undoCount + 1)
        XCTAssertEqual(model.objectTransform, transform.sanitized())
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.interactionMode, .faceSelect)
        XCTAssertEqual(model.faceSelectionOperation, .toggle)
        XCTAssertEqual(model.brush, .crease)
        XCTAssertEqual(model.symmetry, SculptSymmetry(x: true, y: false, z: true))
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.meshMirrorPreview)
        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertTrue(model.pickingCacheHasIndexForTesting)
        XCTAssertFalse(model.isMeshMirrorSnapshotSafeForTesting)
    }

    @MainActor
    func testUndoRedoRestoreSourceAndResultWithoutPreviewOrSelection() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        let source = model.mesh
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        let result = try model.applyMeshMirror(preview: preview).mesh
        model.undo()
        XCTAssertEqual(model.mesh, source)
        XCTAssertNil(model.meshMirrorPreview)
        XCTAssertEqual(model.selectedFaceCount, 0)
        model.redo()
        XCTAssertEqual(model.mesh, result)
        XCTAssertNil(model.meshMirrorPreview)
        XCTAssertEqual(model.selectedFaceCount, 0)
    }

    @MainActor
    func testFailedBVHPreparationLeavesWorkspaceAndHistoryAtomic() throws {
        let cache = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        let model = WorkspaceModel(pickingCache: cache)
        model.mesh = try openHalfBox()
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        let source = model.mesh
        let transform = model.objectTransform
        let camera = model.camera
        let selection = model.faceSelection
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        XCTAssertThrowsError(try model.applyMeshMirror(preview: preview))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertFalse(model.isMeshMirrorSnapshotSafeForTesting)
    }

    @MainActor
    func testPreviewStalesForMeshTransformAxisAndNonRewindingRestoration() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        let originalTransform = model.objectTransform
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3)))
        model.updateTransform(originalTransform)
        XCTAssertTrue(model.isMeshMirrorPreviewStale)
        XCTAssertThrowsError(try model.applyMeshMirror(preview: preview)) {
            XCTAssertEqual($0 as? MeshMirrorError, .stalePreview)
        }

        try model.prepareForMeshMirror()
        let current = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        XCTAssertFalse(current.source.matches(
            mesh: model.mesh,
            transform: model.objectTransform,
            meshChangeVersion: current.source.meshChangeVersion,
            transformChangeVersion: current.source.transformChangeVersion,
            options: MeshMirrorOptions(axis: .y)))
        _ = model.mesh.updatePositions([
            1: model.mesh.vertices[1].position + SIMD3<Float>(0.01, 0, 0),
        ])
        XCTAssertTrue(model.isMeshMirrorPreviewStale)
    }

    @MainActor
    func testCameraToolsAndFaceSelectionDoNotStaleMirrorPreview() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        model.setInteractionMode(.faceSelect)
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        model.camera = CameraState(
            yaw: 0.7, pitch: -0.2, distance: 40,
            target: SIMD3<Float>(1, 2, 3))
        model.brush = .crease
        model.symmetry = SculptSymmetry(x: true, y: true, z: false)
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        XCTAssertTrue(model.isMeshMirrorPreviewCurrent(preview))
    }

    @MainActor
    func testFailedRecalculationAndCancelDoNotLeaveApplicablePreview() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        try model.prepareForMeshMirror()
        let original = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        XCTAssertTrue(model.isMeshMirrorPreviewCurrent(original))
        XCTAssertThrowsError(try model.previewMeshMirror(options: MeshMirrorOptions(axis: .y)))
        XCTAssertNil(model.meshMirrorPreview)
        XCTAssertFalse(model.isMeshMirrorPreviewCurrent(original))
        model.discardMeshMirrorPreview()
        XCTAssertNil(model.meshMirrorPreview)
    }

    @MainActor
    func testPreviewCancelAndFailureDoNotChangeProjectHistoryOrBytes() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        let source = model.mesh
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        try model.prepareForMeshMirror()
        _ = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        model.discardMeshMirrorPreview()
        XCTAssertThrowsError(try model.previewMeshMirror(options: MeshMirrorOptions(axis: .y)))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
    }

    @MainActor
    func testSnapValidationFailuresLeaveWorkspaceHistoryAndProjectBytesUnchanged() throws {
        for (source, expected) in [
            (snapCollapseMesh(), MeshMirrorError.seamSnapWouldCollapseTriangle),
            (snapDuplicateMesh(), MeshMirrorError.seamSnapWouldCreateDuplicateTriangle),
        ] {
            let model = WorkspaceModel()
            model.mesh = source
            let transform = model.objectTransform
            let camera = model.camera
            let selection = model.faceSelection
            let history = (model.undoCount, model.redoCount)
            let generation = model.projectMutationGeneration
            let bytes = try model.projectData()
            try model.prepareForMeshMirror()
            XCTAssertThrowsError(try model.previewMeshMirror(
                options: MeshMirrorOptions(axis: .x))) {
                XCTAssertEqual($0 as? MeshMirrorError, expected)
            }
            XCTAssertEqual(model.mesh, source)
            XCTAssertEqual(model.objectTransform, transform)
            XCTAssertEqual(model.camera, camera)
            XCTAssertEqual(model.faceSelection, selection)
            XCTAssertEqual(model.undoCount, history.0)
            XCTAssertEqual(model.redoCount, history.1)
            XCTAssertEqual(model.projectMutationGeneration, generation)
            XCTAssertEqual(try model.projectData(), bytes)
            XCTAssertNil(model.meshMirrorPreview)
            XCTAssertFalse(model.isMeshMirrorSnapshotSafeForTesting)
        }
    }

    @MainActor
    func testApplyUndoRedoAutosaveOrderingUsesCompleteMeshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshMirrorAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: MeshMirrorImmediateScheduler(),
            debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = try openHalfBox()
        let before = model.mesh
        var generation = model.projectMutationGeneration
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        let after = try model.applyMeshMirror(preview: preview).mesh
        generation.advance()
        XCTAssertEqual(model.projectMutationGeneration, generation)
        await waitForWriteCount(1, coordinator: coordinator)
        let appliedRecovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(appliedRecovery.project.mesh, after)
        model.undo()
        generation.advance()
        await waitForWriteCount(2, coordinator: coordinator)
        let undoneRecovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(undoneRecovery.project.mesh, before)
        model.redo()
        generation.advance()
        await waitForWriteCount(3, coordinator: coordinator)
        let redoneRecovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(redoneRecovery.project.mesh, after)
        let writeCount = await coordinator.successfulWriteCount
        XCTAssertEqual(writeCount, 3)
        XCTAssertFalse(model.isMeshMirrorSnapshotSafeForTesting)
    }

    @MainActor
    func testPersistenceAndSTLExportContainOnlyOrdinaryResultMesh() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        _ = try model.applyMeshMirror(preview: preview)
        let meshBeforeExport = model.mesh
        let runtimeBeforeExport = model.mesh.runtime
        let historyBeforeExport = (model.undoCount, model.redoCount)
        let project = try model.projectData()
        let text = String(decoding: project, as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\":1"))
        XCTAssertFalse(text.contains("meshMirror"))
        XCTAssertFalse(text.contains("seamTolerance"))
        try model.prepareForSTLExport()
        let stl = try model.stlData()
        XCTAssertEqual(stl.count, 84 + model.mesh.indices.count / 3 * 50)
        XCTAssertEqual(model.mesh, meshBeforeExport)
        XCTAssertEqual(model.mesh.runtime, runtimeBeforeExport)
        XCTAssertEqual(model.undoCount, historyBeforeExport.0)
        XCTAssertEqual(model.redoCount, historyBeforeExport.1)
    }

    @MainActor
    func testMirrorSheetFitsCompactWidthsAndLargeDynamicType() throws {
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        for width in [CGFloat(320), 744, 1_024] {
            let sheet = UIHostingController(rootView: MeshMirrorView(model: model)
                .environment(\.dynamicTypeSize, .accessibility3))
            let size = sheet.sizeThatFits(in: CGSize(width: width, height: 1_800))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertLessThanOrEqual(size.width, width + 1)
        }
    }

    func testMirrorSheetExplainsToleranceAndDisplaysBoundaryAndSnapMetrics() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("src/UI/MeshMirrorView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("Boundary edges"))
        XCTAssertTrue(source.contains("Maximum seam snap"))
        XCTAssertTrue(source.contains("Accepted seam vertices snap to the exact zero plane."))
        XCTAssertTrue(source.contains("Vertices outside it are not welded"))
        XCTAssertFalse(source.contains("weld only exact plane seams"))
    }

    @MainActor
    func testSuccessfulInstallUploadsFreshTopologyOnceThenSkipsUnchangedFrame() throws {
        #if targetEnvironment(simulator)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        let model = WorkspaceModel()
        model.mesh = try openHalfBox()
        renderer.update(mesh: model.mesh)
        profiler.reset(
            vertexCount: model.mesh.vertices.count,
            triangleCount: model.mesh.indices.count / 3)
        try model.prepareForMeshMirror()
        let preview = try model.previewMeshMirror(options: MeshMirrorOptions(axis: .x))
        _ = try model.applyMeshMirror(preview: preview)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        #endif
    }

    private func openHalfBox(
        seamCoordinate: Float = 0,
        yOffset: Float = 0
    ) throws -> EditableMesh {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        var vertices = cube.vertices
        for index in vertices.indices {
            vertices[index].position.x += 1 + seamCoordinate
            vertices[index].position.y += yOffset
        }
        var indices = cube.indices
        indices.removeSubrange(12..<18)
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func interiorSeamEdgeMesh() -> EditableMesh {
        mesh(positions: [
            SIMD3<Float>(0, -1, -1), SIMD3<Float>(0, -1, 1),
            SIMD3<Float>(0, 1, 1), SIMD3<Float>(0, 1, -1),
            SIMD3<Float>(1, 0, 0.5), SIMD3<Float>(1, 0, -0.5),
        ], indices: [
            0, 1, 4, 1, 2, 4, 2, 0, 4,
            0, 2, 5, 2, 3, 5, 3, 0, 5,
        ])
    }

    private func seamInteriorVertexMesh() -> EditableMesh {
        mesh(positions: [
            SIMD3<Float>(0, -2, -2), SIMD3<Float>(0, -2, 2),
            SIMD3<Float>(0, 2, 2), SIMD3<Float>(0, 2, -2),
            SIMD3<Float>(1, -1, -1), SIMD3<Float>(1, -1, 1),
            SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, -1),
            SIMD3<Float>(0, 0, 0),
        ], indices: [
            0, 1, 5, 0, 5, 4,
            1, 2, 6, 1, 6, 5,
            2, 3, 7, 2, 7, 6,
            3, 0, 4, 3, 4, 7,
            4, 5, 8, 5, 6, 8, 6, 7, 8, 7, 4, 8,
        ])
    }

    private func seamTriangleMesh() throws -> EditableMesh {
        let closed = try shiftedCube(offset: SIMD3<Float>(4, -10, 0))
        let plane = mesh(positions: [
            SIMD3<Float>(0, 10, 0),
            SIMD3<Float>(0, 12, 0),
            SIMD3<Float>(0, 10, 2),
        ], indices: [0, 1, 2])
        return combine([closed, plane])
    }

    private func seamBowTieMesh() throws -> EditableMesh {
        let first = try openHalfBox(yOffset: 0)
        let second = try openHalfBox(yOffset: 6)
        let firstSeam = try XCTUnwrap(first.vertices.firstIndex { $0.position.x == 0 })
        let secondSeam = try XCTUnwrap(second.vertices.firstIndex { $0.position.x == 0 })
        var vertices = first.vertices
        var remap = Array(repeating: UInt32.zero, count: second.vertices.count)
        for vertexID in second.vertices.indices {
            if vertexID == secondSeam {
                remap[vertexID] = UInt32(firstSeam)
            } else {
                remap[vertexID] = UInt32(vertices.count)
                vertices.append(second.vertices[vertexID])
            }
        }
        let indices = first.indices + second.indices.map { remap[Int($0)] }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func snapCollapseMesh() -> EditableMesh {
        mesh(positions: [
            SIMD3<Float>(0.000_005, -1, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(2, 1, 0),
        ], indices: [0, 1, 2])
    }

    private func snapDuplicateMesh() -> EditableMesh {
        mesh(positions: [
            SIMD3<Float>(0.000_005, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 1, 0),
            SIMD3<Float>(-0.000_005, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 1, 0),
        ], indices: [0, 1, 2, 3, 4, 5])
    }

    private func nonManifoldMesh() -> EditableMesh {
        mesh(positions: [
            SIMD3<Float>(1, -1, 0), SIMD3<Float>(1, 1, 0),
            SIMD3<Float>(2, 0, 1), SIMD3<Float>(2, 0, -1),
            SIMD3<Float>(2, 2, 0),
        ], indices: [0, 1, 2, 1, 0, 3, 0, 1, 4])
    }

    private func mesh(positions: [SIMD3<Float>], indices: [UInt32]) -> EditableMesh {
        var result = EditableMesh(
            vertices: positions.map {
                MeshVertex(position: $0, normal: SIMD3<Float>(1, 0, 0))
            },
            indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func openCube(offset: SIMD3<Float>) throws -> EditableMesh {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        var vertices = cube.vertices
        for index in vertices.indices { vertices[index].position += offset }
        var indices = cube.indices
        indices.removeSubrange(0..<6)
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func shiftedCube(offset: SIMD3<Float>) throws -> EditableMesh {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        var vertices = cube.vertices
        for index in vertices.indices { vertices[index].position += offset }
        var result = EditableMesh(vertices: vertices, indices: cube.indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func orientedOpenHalfBox(
        axis: MirrorAxis,
        sign: Float,
        seamCoordinate: Float = 0
    ) throws -> EditableMesh {
        let source = try openHalfBox(seamCoordinate: seamCoordinate)
        var vertices = source.vertices
        for index in vertices.indices {
            let p = vertices[index].position
            switch axis {
            case .x: vertices[index].position = SIMD3<Float>(p.x * sign, p.y, p.z)
            case .y: vertices[index].position = SIMD3<Float>(p.y, p.x * sign, p.z)
            case .z: vertices[index].position = SIMD3<Float>(p.y, p.z, p.x * sign)
            }
        }
        var indices = source.indices
        if sign < 0 {
            for offset in stride(from: 0, to: indices.count, by: 3) {
                indices.swapAt(offset + 1, offset + 2)
            }
        }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func combine(_ meshes: [EditableMesh]) -> EditableMesh {
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        for mesh in meshes {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: mesh.vertices)
            indices.append(contentsOf: mesh.indices.map { $0 + base })
        }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func reflect(_ position: SIMD3<Float>, axis: MirrorAxis) -> SIMD3<Float> {
        switch axis {
        case .x: SIMD3<Float>(-position.x, position.y, position.z)
        case .y: SIMD3<Float>(position.x, -position.y, position.z)
        case .z: SIMD3<Float>(position.x, position.y, -position.z)
        }
    }

    private func axisComponent(_ axis: MirrorAxis) -> Int {
        switch axis { case .x: 0; case .y: 1; case .z: 2 }
    }

    private func assertHealthyClosed(
        _ mesh: EditableMesh,
        components: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let report = MeshTopologyDiagnostics.analyze(mesh)
        XCTAssertEqual(report.boundaryEdgeCount, 0, file: file, line: line)
        XCTAssertEqual(report.nonManifoldEdgeCount, 0, file: file, line: line)
        XCTAssertEqual(report.inconsistentWindingEdgeCount, 0, file: file, line: line)
        XCTAssertEqual(report.degenerateTriangleCount, 0, file: file, line: line)
        XCTAssertEqual(report.duplicateTriangleCount, 0, file: file, line: line)
        XCTAssertEqual(report.connectedComponentCount, components, file: file, line: line)
        XCTAssertTrue(mesh.vertices.allSatisfy {
            $0.position.allFinite && $0.normal.allFinite
                && abs(simd_length($0.normal) - 1) <= 0.001
        }, file: file, line: line)
    }

    private func worldBounds(
        _ mesh: EditableMesh,
        _ transform: ObjectTransform
    ) -> AxisAlignedBoundingBox {
        var bounds = AxisAlignedBoundingBox()
        for vertex in mesh.vertices {
            bounds.include(transform.worldPosition(fromLocal: vertex.position))
        }
        return bounds
    }

    private func waitForWriteCount(
        _ expected: Int,
        coordinator: ProjectAutosaveCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if await coordinator.successfulWriteCount == expected { return }
            await Task.yield()
        }
        let actual = await coordinator.successfulWriteCount
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private struct MeshMirrorImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
