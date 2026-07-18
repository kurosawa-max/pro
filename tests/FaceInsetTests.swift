import SwiftUI
import XCTest
import simd
@testable import Forge3D

final class FaceInsetTests: XCTestCase {
    func testSquareEstimateAndResultHaveExactCountsAndValidTopology() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        let estimate = try FaceInset.estimate(
            mesh: cube, selection: selected, transform: .identity, options: options(0.5))
        XCTAssertEqual(estimate.originalVertexCount, 8)
        XCTAssertEqual(estimate.originalTriangleCount, 12)
        XCTAssertEqual(estimate.selectedFaceCount, 2)
        XCTAssertEqual(estimate.componentCount, 1)
        XCTAssertEqual(estimate.boundaryLoopCount, 1)
        XCTAssertEqual(estimate.boundaryEdgeCount, 4)
        XCTAssertEqual(estimate.selectedUniqueVertexCount, 4)
        XCTAssertEqual(estimate.interiorVertexCount, 0)
        XCTAssertEqual(estimate.resultingVertexCount, 12)
        XCTAssertEqual(estimate.resultingTriangleCount, 20)
        XCTAssertEqual(estimate.addedInsetVertexCount, 4)
        XCTAssertEqual(estimate.addedRingTriangleCount, 8)
        XCTAssertEqual(estimate.originalAreaSquareMillimeters, 4, accuracy: 0.000_001)
        XCTAssertEqual(estimate.insetAreaSquareMillimeters, 1, accuracy: 0.000_001)

        let result = try FaceInset.inset(
            mesh: cube, selection: selected, transform: .identity, options: options(0.5))
        let topology = MeshTopologyDiagnostics.analyze(result.mesh)
        XCTAssertEqual(topology.degenerateTriangleCount, 0)
        XCTAssertEqual(topology.duplicateTriangleCount, 0)
        XCTAssertEqual(topology.boundaryEdgeCount, 0)
        XCTAssertEqual(topology.nonManifoldEdgeCount, 0)
        XCTAssertEqual(topology.inconsistentWindingEdgeCount, 0)
        XCTAssertTrue(result.mesh.hasCachedAdjacency)
        XCTAssertNotEqual(result.mesh.runtime.topologyID, cube.runtime.topologyID)
        XCTAssertTrue(result.mesh.vertices.suffix(4).allSatisfy {
            abs(abs($0.position.x) - 0.5) < 0.000_01
                && abs(abs($0.position.z) - 0.5) < 0.000_01
                && abs($0.position.y - 1) < 0.000_01
        })
    }

    func testTriangleOffsetUsesConstantWidthAndPreservesWinding() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let result = try FaceInset.inset(
            mesh: source, selection: try selection(source, faces: [10]),
            transform: .identity, options: options(0.25))
        XCTAssertEqual(result.mesh.indices.count / 3, 18)
        XCTAssertEqual(result.estimate.boundaryEdgeCount, 3)
        XCTAssertTrue(result.mesh.vertices.allSatisfy {
            $0.position.allFinite && $0.normal.allFinite && abs(simd_length($0.normal) - 1) < 0.000_1
        })
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).boundaryEdgeCount, 0)
    }

    func testDeterministicBasisIsOrthonormalAndStableForAxisTies() throws {
        for normal in [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0),
                       SIMD3<Double>(0, 0, 1), simd_normalize(SIMD3<Double>(1, 1, 1))] {
            let first = try FaceInset.deterministicBasis(normal: normal)
            let second = try FaceInset.deterministicBasis(normal: normal)
            XCTAssertEqual(first, second)
            XCTAssertEqual(simd_length(first.u), 1, accuracy: 1.0e-12)
            XCTAssertEqual(simd_length(first.v), 1, accuracy: 1.0e-12)
            XCTAssertEqual(simd_dot(first.u, first.v), 0, accuracy: 1.0e-12)
            assertVector(simd_cross(first.u, first.v), first.normal)
        }
    }

    func testPolygonOffsetRejectsConcaveSelfIntersectingCollapseAndExcessiveWidth() throws {
        let square = points([(0, 0), (4, 0), (4, 4), (0, 4)])
        let inset = try FaceInset.insetPolygon(square, distance: 1)
        XCTAssertEqual(inset, points([(1, 1), (3, 1), (3, 3), (1, 3)]))
        XCTAssertThrowsError(try FaceInset.insetPolygon(square, distance: 2))
        XCTAssertThrowsError(try FaceInset.validateStrictlyConvexSimplePolygon(
            points([(0, 0), (3, 0), (1, 1), (3, 3), (0, 3)]))) {
            XCTAssertEqual($0 as? FaceInsetError, .nonConvexBoundary)
        }
        XCTAssertThrowsError(try FaceInset.validateStrictlyConvexSimplePolygon(
            points([(0, 0), (3, 3), (0, 3), (3, 0)])))
    }

    func testPolygonOffsetPreservesConstantWidthForConvexAnglesAndScales() throws {
        let cases: [([FaceInsetPoint2D], Double)] = [
            (points([(0, 0), (8, 0), (3, 6)]), 0.25),
            (points([(0, 0), (12, 0), (12, 3), (0, 3)]), 0.001),
            (points([(0, 0), (6, 0), (5, 4), (1, 5)]), 0.5),
            (points([(0, 0), (1_000_000, 0), (750_000, 800_000), (10_000, 500_000)]), 1_000),
        ]
        for (source, distance) in cases {
            let inset = try FaceInset.insetPolygon(source, distance: distance)
            try FaceInset.validateInsetEdgeDistances(
                source: source, inset: inset, distance: distance,
                tolerance: max(FaceInset.signedArea(source) * 1.0e-12, 1.0e-9))
            XCTAssertLessThan(FaceInset.signedArea(inset), FaceInset.signedArea(source))
        }
    }

    func testWorldMillimeterInsetHandlesRotationTranslationAndNonUniformScale() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(
            translation: SIMD3<Float>(10, -7, 4),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(15, 25, 40)),
            scale: SIMD3<Float>(2, 3, 4))
        let result = try FaceInset.inset(
            mesh: cube, selection: try selection(cube, faces: [10, 11]),
            transform: transform, options: options(1))
        let sourceWorld = [2, 3, 6, 7].map { transform.worldPosition(fromLocal: cube.vertices[$0].position) }
        let insetWorld = result.mesh.vertices.suffix(4).map { transform.worldPosition(fromLocal: $0.position) }
        for point in insetWorld {
            let distance = sourceWorld.map { simd_length(point - $0) }.min()!
            XCTAssertGreaterThan(distance, 0)
            XCTAssertTrue(point.allFinite)
        }
        XCTAssertEqual(result.estimate.originalAreaSquareMillimeters, 32, accuracy: 0.001)
        XCTAssertEqual(result.estimate.insetAreaSquareMillimeters, 12, accuracy: 0.001)
    }

    func testWorldMillimeterEdgesRemainParallelAndExactlyOffsetAfterFloatRoundTrip() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 20)
        let transforms = [
            ObjectTransform.identity,
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(25, -35, 17)),
                            scale: SIMD3<Float>(2, 3, 5)),
            ObjectTransform(translation: SIMD3<Float>(200, -350, 125),
                            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(-40, 15, 70)),
                            scale: SIMD3<Float>(0.2, 10, 50)),
            ObjectTransform(translation: SIMD3<Float>(100_000, -80_000, 60_000),
                            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(9, 31, -22)),
                            scale: SIMD3<Float>(0.5, 4, 12)),
        ]
        for transform in transforms {
            let result = try FaceInset.inset(
                mesh: source, selection: try selection(source, faces: [10, 11]),
                transform: transform, options: options(0.5))
            assertWorldInsetEdges(
                source: source, result: result.mesh, transform: transform,
                distance: 0.5)
        }
    }

    func testPreviewBoundsMatchActualResultAfterWorldLocalFloatRoundTrip() throws {
        let scenarios: [(Float, ObjectTransform, Double)] = [
            (20, .identity, 0.001),
            (20, ObjectTransform(rotation: ObjectTransform.rotation(
                degrees: SIMD3<Float>(37, -18, 63))), 0.001),
            (20, ObjectTransform(translation: SIMD3<Float>(75_000, -40_000, 25_000),
                                 rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(11, 29, -47)),
                                 scale: SIMD3<Float>(0.25, 6, 30)), 0.001),
            (1_000, ObjectTransform(rotation: ObjectTransform.rotation(
                degrees: SIMD3<Float>(5, 12, 19)), scale: SIMD3<Float>(1.5, 0.75, 2)), 0.001),
            (0.1, ObjectTransform(rotation: ObjectTransform.rotation(
                degrees: SIMD3<Float>(13, 7, -9)), scale: SIMD3<Float>(2, 3, 4)), 0.001),
        ]
        for (size, transform, distance) in scenarios {
            let source = try PrimitiveMeshBuilder.cube(size: size)
            let result = try FaceInset.inset(
                mesh: source, selection: try selection(source, faces: [10, 11]),
                transform: transform, options: options(distance))
            let actual = worldBounds(of: result.mesh, transform: transform)
            let maximum = result.estimate.resultBounds.maximum
            let minimum = result.estimate.resultBounds.minimum
            let magnitude = max(
                max(abs(maximum.x), max(abs(maximum.y), abs(maximum.z))),
                max(abs(minimum.x), max(abs(minimum.y), abs(minimum.z))))
            let tolerance = max(magnitude * Float.ulpOfOne * 8, 0.000_01)
            assertVector(actual.minimum, result.estimate.resultBounds.minimum, accuracy: tolerance)
            assertVector(actual.maximum, result.estimate.resultBounds.maximum, accuracy: tolerance)
        }
    }

    func testInnerTriangulationAcceptsMultipleInteriorVerticesAndOrderingChanges() throws {
        let points: [UInt32: FaceInsetPoint2D] = [
            0: .init(x: 0, y: 0), 1: .init(x: 4, y: 0),
            2: .init(x: 4, y: 4), 3: .init(x: 0, y: 4),
            4: .init(x: 1.5, y: 1.5), 5: .init(x: 2.5, y: 2.5),
        ]
        let triangles: [[UInt32]] = [
            [0, 1, 4], [1, 2, 5], [1, 5, 4],
            [2, 3, 5], [3, 0, 4], [3, 4, 5],
        ]
        XCTAssertNoThrow(try FaceInset.validateInnerTriangulation(
            triangles: triangles, pointsByVertex: points, areaEpsilon: 1.0e-12))
        XCTAssertNoThrow(try FaceInset.validateInnerTriangulation(
            triangles: Array(triangles.reversed()), pointsByVertex: points, areaEpsilon: 1.0e-12))
    }

    func testInnerTriangulationRejectsCrossingOverlapAndSameSideFoldOver() throws {
        let crossingPoints: [UInt32: FaceInsetPoint2D] = [
            0: .init(x: 0, y: 0), 1: .init(x: 3, y: 0), 2: .init(x: 0, y: 3),
            3: .init(x: 1, y: 0.5), 4: .init(x: 3, y: 0.5), 5: .init(x: 1, y: 2.5),
        ]
        XCTAssertThrowsError(try FaceInset.validateInnerTriangulation(
            triangles: [[0, 1, 2], [3, 4, 5]],
            pointsByVertex: crossingPoints, areaEpsilon: 1.0e-12)) {
            XCTAssertEqual($0 as? FaceInsetError, .innerTriangulationIntersection)
        }

        let foldPoints: [UInt32: FaceInsetPoint2D] = [
            0: .init(x: 0, y: 0), 1: .init(x: 4, y: 0),
            2: .init(x: 1, y: 2), 3: .init(x: 3, y: 1),
        ]
        XCTAssertThrowsError(try FaceInset.validateInnerTriangulation(
            triangles: [[0, 1, 2], [0, 1, 3]],
            pointsByVertex: foldPoints, areaEpsilon: 1.0e-12)) {
            XCTAssertEqual($0 as? FaceInsetError, .innerTriangulationIntersection)
        }
    }

    func testInnerTriangulationPairLimitFailsBeforeUnsafeQuadraticWork() throws {
        let points: [UInt32: FaceInsetPoint2D] = [
            0: .init(x: 0, y: 0), 1: .init(x: 1, y: 0), 2: .init(x: 0, y: 1),
        ]
        let triangles = Array(repeating: [UInt32(0), 1, 2], count: 5_000)
        XCTAssertThrowsError(try FaceInset.validateInnerTriangulation(
            triangles: triangles, pointsByVertex: points, areaEpsilon: 1.0e-12)) {
            XCTAssertEqual($0 as? FaceInsetError, .innerTriangulationLimitExceeded)
        }
    }

    func testInteriorVertexIsDuplicatedWithoutMovementWhenInsideInset() throws {
        let source = try cubeWithSubdividedTop(size: 4)
        let selected = try selection(source, faces: [10, 11, 12, 13])
        let result = try FaceInset.inset(
            mesh: source, selection: selected, transform: .identity, options: options(0.5))
        XCTAssertEqual(result.estimate.interiorVertexCount, 1)
        XCTAssertEqual(result.estimate.addedInsetVertexCount, 5)
        XCTAssertEqual(result.mesh.vertices.filter { $0.position == SIMD3<Float>(0, 2, 0) }.count, 1)
        XCTAssertEqual(result.mesh.indices.count / 3, 22)
    }

    func testInteriorVertexOutsideInsetIsRejected() throws {
        let source = try cubeWithSubdividedTop(size: 4, centerXZ: SIMD2<Float>(1.8, 0))
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: source, selection: try selection(source, faces: [10, 11, 12, 13]),
            transform: .identity, options: options(0.5))) {
            XCTAssertEqual($0 as? FaceInsetError, .interiorVertexOutsideInset)
        }
    }

    func testMultipleAndVertexOnlyTouchingComponentsRemainDeterministic() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let opposite = try FaceInset.estimate(
            mesh: cube, selection: try selection(cube, faces: [8, 9, 10, 11]),
            transform: .identity, options: options(0.25))
        XCTAssertEqual(opposite.componentCount, 2)
        XCTAssertEqual(opposite.boundaryLoopCount, 2)
        XCTAssertEqual(opposite.boundaryEdgeCount, 8)
        let vertexOnly = try FaceInset.estimate(
            mesh: cube, selection: try selection(cube, faces: [0, 8]),
            transform: .identity, options: options(0.1))
        XCTAssertEqual(vertexOnly.componentCount, 2)
        XCTAssertEqual(vertexOnly.addedInsetVertexCount, 6)
    }

    func testMultipleComponentResultsRemainIndependentAndDeterministic() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 4)
        let oppositeSelection = try selection(cube, faces: [8, 9, 10, 11])
        let first = try FaceInset.inset(
            mesh: cube, selection: oppositeSelection,
            transform: .identity, options: options(0.25))
        let second = try FaceInset.inset(
            mesh: cube, selection: oppositeSelection,
            transform: .identity, options: options(0.25))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.estimate.componentCount, 2)
        XCTAssertEqual(first.estimate.boundaryLoopCount, 2)
        XCTAssertEqual(first.estimate.addedRingTriangleCount, 16)
        let diagnostics = MeshTopologyDiagnostics.analyze(first.mesh)
        XCTAssertEqual(diagnostics.degenerateTriangleCount, 0)
        XCTAssertEqual(diagnostics.duplicateTriangleCount, 0)
        XCTAssertEqual(diagnostics.boundaryEdgeCount, 0)
        XCTAssertEqual(diagnostics.nonManifoldEdgeCount, 0)
        XCTAssertEqual(diagnostics.inconsistentWindingEdgeCount, 0)

        let touchingSelection = try selection(cube, faces: [0, 8])
        let touching = try FaceInset.inset(
            mesh: cube, selection: touchingSelection,
            transform: .identity, options: options(0.1))
        XCTAssertEqual(touching.estimate.componentCount, 2)
        XCTAssertEqual(touching.estimate.addedInsetVertexCount, 6)
        XCTAssertEqual(touching.mesh.vertices.filter {
            $0.position == cube.vertices[0].position
        }.count, 1)
        let firstSharedVertexDuplicate = touching.mesh.vertices[8].position
        let secondSharedVertexDuplicate = touching.mesh.vertices[11].position
        XCTAssertNotEqual(firstSharedVertexDuplicate, secondSharedVertexDuplicate)
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(touching.mesh).duplicateTriangleCount, 0)
    }

    func testSelectedOpenBoundaryIsRejected() throws {
        let open = mesh([
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0), SIMD3<Float>(0, 3, 0)
        ], [0, 1, 2])
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: open, selection: try selection(open, faces: [0]),
            transform: .identity, options: options())) {
            XCTAssertEqual($0 as? FaceInsetError, .openSelectedEdge)
        }
    }

    func testNonPlanarConcaveHoleNonManifoldAndWindingSelectionsAreRejected() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: cube, selection: try selection(cube, faces: [0, 11]),
            transform: .identity, options: options())) {
            guard let error = $0 as? FaceInsetError else { return XCTFail("Expected FaceInsetError") }
            XCTAssertTrue([FaceInsetError.nonPlanarComponent, .nonConvexBoundary].contains(error))
        }
        XCTAssertThrowsError(try FaceInset.validateStrictlyConvexSimplePolygon(
            points([(0, 0), (3, 0), (1, 1), (3, 3), (0, 3)]))) {
            XCTAssertEqual($0 as? FaceInsetError, .nonConvexBoundary)
        }
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: cube, selection: try selection(cube, faces: Array(0..<8)),
            transform: .identity, options: options())) {
            XCTAssertEqual($0 as? FaceInsetError, .multipleBoundaryLoops)
        }
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: cube, selection: try selection(cube, faces: Array(0..<12)),
            transform: .identity, options: options()))
        let nonManifold = mesh([
            SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 2, 0), SIMD3(0, -2, 0), SIMD3(0, 0, 2)
        ], [0, 1, 2, 1, 0, 3, 0, 1, 4])
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: nonManifold, selection: try selection(nonManifold, faces: [0]),
            transform: .identity, options: options())) {
            XCTAssertEqual($0 as? FaceInsetError, .nonManifoldSelectedEdge)
        }
    }

    func testDistanceInvalidMeshAndLimitFailuresAreExplicit() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        for (distance, expected) in [
            (0.0, FaceInsetError.distanceTooSmall), (-1.0, .distanceTooSmall),
            (0.000_1, .distanceTooSmall), (Double.nan, .invalidDistance),
            (Double.infinity, .invalidDistance), (1_000.1, .distanceLimitExceeded)
        ] {
            XCTAssertThrowsError(try FaceInset.estimate(
                mesh: cube, selection: selected, transform: .identity, options: options(distance))) {
                XCTAssertEqual($0 as? FaceInsetError, expected)
            }
        }
        let invalid = EditableMesh(vertices: cube.vertices, indices: [0, 1, 999])
        XCTAssertThrowsError(try FaceInset.estimate(
            mesh: invalid, selection: try selection(invalid, faces: [0]),
            transform: .identity, options: options())) {
            XCTAssertEqual($0 as? FaceInsetError, .invalidMesh)
        }
        XCTAssertThrowsError(try FaceInset.estimatedWorkingBytes(
            originalVertices: .max, originalTriangles: .max, selectedFaces: .max,
            boundaryEdges: .max, resultingVertices: .max, resultingTriangles: .max)) {
            XCTAssertEqual($0 as? FaceInsetError, .arithmeticOverflow)
        }
    }

    func testPreviewIdentityDetectsMeshTransformSelectionAndOptionChanges() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        let meshVersion = TopologyEditChangeVersion(
            identity: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, value: 3)
        let transformVersion = TopologyEditChangeVersion(
            identity: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, value: 7)
        let preview = try FaceInset.makePreview(
            mesh: cube, selection: selected, transform: .identity, options: options(),
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion)
        XCTAssertTrue(preview.source.matches(
            mesh: cube, selection: selected, transform: .identity,
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            options: options()))
        var changed = meshVersion
        changed.advance()
        XCTAssertFalse(preview.source.matches(
            mesh: cube, selection: selected, transform: .identity,
            meshChangeVersion: changed, transformChangeVersion: transformVersion,
            options: options()))
        XCTAssertFalse(preview.source.matches(
            mesh: cube, selection: selected, transform: .identity,
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            options: options(0.5)))
    }

    func testResultOrderingAndFingerprintAreDeterministic() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        let first = try FaceInset.inset(mesh: cube, selection: selected, transform: .identity, options: options())
        let second = try FaceInset.inset(mesh: cube, selection: selected, transform: .identity, options: options())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
        XCTAssertEqual(Array(first.mesh.indices.prefix(30)), Array(cube.indices.prefix(30)))
    }

    @MainActor
    func testWorkspacePreviewCancelAndFailureAreAtomic() throws {
        let model = try configuredModel(faces: [10, 11])
        let source = model.mesh, transform = model.objectTransform, camera = model.camera
        let selection = model.faceSelection, history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration, bytes = try model.projectData()
        try model.prepareForFaceInset()
        _ = try model.previewFaceInset(options: options(0.5))
        model.discardFaceInsetPreview()
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertThrowsError(try model.previewFaceInset(options: options(2)))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(try model.projectData(), bytes)
    }

    @MainActor
    func testWorkspaceApplyCreatesOneUndoAndRedoRestoresBothSnapshots() throws {
        let model = try configuredModel(faces: [10, 11])
        let beforeMesh = model.mesh
        let transform = ObjectTransform(translation: SIMD3<Float>(4, 5, 6), scale: SIMD3<Float>(2, 3, 4))
        model.updateTransform(transform)
        model.camera = CameraState(yaw: 0.4, pitch: -0.2, distance: 12, target: SIMD3(1, 2, 3))
        let camera = model.camera
        let undoBefore = model.undoCount
        try model.prepareForFaceInset()
        let preview = try model.previewFaceInset(options: options(0.5))
        let result = try model.applyFaceInset(preview: preview)
        let afterMesh = result.mesh
        XCTAssertEqual(model.mesh, afterMesh)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertEqual(model.undoCount, undoBefore + 1)
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.faceInsetPreview)
        XCTAssertFalse(model.isFaceInsetSnapshotSafeForTesting)
        model.undo()
        XCTAssertEqual(model.mesh, beforeMesh)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.selectedFaceCount, 0)
        model.redo()
        XCTAssertEqual(model.mesh, afterMesh)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertFalse(model.isFaceInsetSnapshotSafeForTesting)
    }

    @MainActor
    func testPreviewCancelAndFailureDoNotScheduleAutosave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceInsetAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: FaceInsetImmediateScheduler(), debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(10))
        XCTAssertTrue(model.applyFaceSelectionHit(11))
        let beforeMesh = model.mesh
        let initialGeneration = model.projectMutationGeneration
        let initialBytes = try model.projectData()
        try model.prepareForFaceInset()
        _ = try model.previewFaceInset(options: options(0.25))
        model.discardFaceInsetPreview()
        XCTAssertThrowsError(try model.previewFaceInset(options: options(2)))
        for _ in 0..<100 { await Task.yield() }
        let writeCount = await coordinator.successfulWriteCount
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(model.projectMutationGeneration, initialGeneration)
        XCTAssertEqual(try model.projectData(), initialBytes)
        XCTAssertNil(model.faceInsetPreview)
    }

    @MainActor
    func testApplyUndoRedoAutosaveOrderingUsesOnlyCompletedSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceInsetAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: FaceInsetImmediateScheduler(), debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(10))
        XCTAssertTrue(model.applyFaceSelectionHit(11))
        let beforeMesh = model.mesh
        let initialGeneration = model.projectMutationGeneration
        try model.prepareForFaceInset()
        let preview = try model.previewFaceInset(options: options(0.25))
        let result = try model.applyFaceInset(preview: preview)
        var expectedGeneration = initialGeneration
        expectedGeneration.advance()
        XCTAssertEqual(model.projectMutationGeneration, expectedGeneration)
        XCTAssertFalse(model.isFaceInsetSnapshotSafeForTesting)
        await waitForWriteCount(1, coordinator: coordinator)
        var recovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(recovery.project.mesh, result.mesh)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, expectedGeneration)

        model.undo()
        expectedGeneration.advance()
        XCTAssertEqual(model.projectMutationGeneration, expectedGeneration)
        await waitForWriteCount(2, coordinator: coordinator)
        recovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(recovery.project.mesh, beforeMesh)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, expectedGeneration)

        model.redo()
        expectedGeneration.advance()
        XCTAssertEqual(model.projectMutationGeneration, expectedGeneration)
        await waitForWriteCount(3, coordinator: coordinator)
        recovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(recovery.project.mesh, result.mesh)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, expectedGeneration)
        let writeCount = await coordinator.successfulWriteCount
        XCTAssertEqual(writeCount, 3)
    }

    @MainActor
    func testBVHPreparationFailureLeavesWorkspaceAndHistoryAtomic() throws {
        let cache = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        let model = try configuredModel(faces: [10, 11], pickingCache: cache)
        try model.prepareForFaceInset()
        let preview = try model.previewFaceInset(options: options(0.5))
        let source = model.mesh, selection = model.faceSelection
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration, bytes = try model.projectData()
        XCTAssertThrowsError(try model.applyFaceInset(preview: preview))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertNotNil(model.faceInsetError)
        XCTAssertFalse(model.isFaceInsetSnapshotSafeForTesting)
    }

    @MainActor
    func testVertexOnlyChangeKeepsSelectionAndStalesPreviewWithoutTopologyMutation() throws {
        let model = try configuredModel(faces: [10, 11])
        let topologyID = model.mesh.runtime.topologyID
        let topologyRevision = model.mesh.runtime.topologyRevision
        try model.prepareForFaceInset()
        _ = try model.previewFaceInset(options: options(0.25))
        _ = model.mesh.updatePositions([0: model.mesh.vertices[0].position + SIMD3<Float>(0.01, 0, 0)])
        XCTAssertEqual(model.mesh.runtime.topologyID, topologyID)
        XCTAssertEqual(model.mesh.runtime.topologyRevision, topologyRevision)
        XCTAssertEqual(model.selectedFaceCount, 2)
        XCTAssertTrue(model.isFaceInsetPreviewStale)
    }

    @MainActor
    func testPreviewCannotBeReusedAfterSelectionOrTransformExactRestoration() throws {
        let selectionModel = try configuredModel(faces: [10, 11])
        try selectionModel.prepareForFaceInset()
        let selectionPreview = try selectionModel.previewFaceInset(options: options(0.25))
        XCTAssertTrue(selectionModel.applyFaceSelectionHit(8))
        selectionModel.setFaceSelectionOperation(.remove)
        XCTAssertTrue(selectionModel.applyFaceSelectionHit(8))
        XCTAssertTrue(selectionModel.isFaceInsetPreviewStale)
        XCTAssertThrowsError(try selectionModel.applyFaceInset(preview: selectionPreview)) {
            XCTAssertEqual($0 as? FaceInsetError, .stalePreview)
        }

        let transformModel = try configuredModel(faces: [10, 11])
        let originalTransform = transformModel.objectTransform
        try transformModel.prepareForFaceInset()
        let transformPreview = try transformModel.previewFaceInset(options: options(0.25))
        transformModel.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3)))
        transformModel.updateTransform(originalTransform)
        XCTAssertTrue(transformModel.isFaceInsetPreviewStale)
        XCTAssertThrowsError(try transformModel.applyFaceInset(preview: transformPreview)) {
            XCTAssertEqual($0 as? FaceInsetError, .stalePreview)
        }
    }

    @MainActor
    func testPersistenceAndUILayoutDoNotExposeInsetRuntimeState() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceInset()
        _ = try model.previewFaceInset(options: options(0.5))
        let text = String(decoding: try model.projectData(), as: UTF8.self)
        XCTAssertFalse(text.contains("faceInset"))
        XCTAssertTrue(text.contains("\"formatVersion\":1"))
        for width in [CGFloat(320), 744, 1_024] {
            let panel = UIHostingController(rootView: FaceSelectionPanel(model: model))
            let panelSize = panel.sizeThatFits(in: CGSize(width: width, height: 1_400))
            XCTAssertLessThanOrEqual(panelSize.width, width + 1)
            let sheet = UIHostingController(rootView: FaceInsetView(model: model)
                .environment(\.dynamicTypeSize, .accessibility3))
            let sheetSize = sheet.sizeThatFits(in: CGSize(width: width, height: 1_600))
            XCTAssertTrue(sheetSize.width.isFinite && sheetSize.height.isFinite)
            XCTAssertLessThanOrEqual(sheetSize.width, width + 1)
        }
    }

    private func options(_ distance: Double = 0.25) -> FaceInsetOptions {
        FaceInsetOptions(distanceMillimeters: distance)
    }
    private func points(_ values: [(Double, Double)]) -> [FaceInsetPoint2D] {
        values.map { FaceInsetPoint2D(x: $0.0, y: $0.1) }
    }
    private func assertWorldInsetEdges(
        source: EditableMesh, result: EditableMesh, transform: ObjectTransform,
        distance: Double, file: StaticString = #filePath, line: UInt = #line
    ) {
        let sortedSourceIDs = [2, 3, 6, 7]
        let loop = [2, 3, 7, 6]
        let innerVertices = Array(result.vertices.suffix(sortedSourceIDs.count))
        let innerBySource = Dictionary(uniqueKeysWithValues: zip(sortedSourceIDs, innerVertices).map {
            ($0.0, double(transform.worldPosition(fromLocal: $0.1.position)))
        })
        let sourceByID = Dictionary(uniqueKeysWithValues: loop.map {
            ($0, double(transform.worldPosition(fromLocal: source.vertices[$0].position)))
        })
        let magnitude = sourceByID.values.reduce(0.0) { partial, point in
            max(partial, max(abs(point.x), max(abs(point.y), abs(point.z))))
        }
        let tolerance = max(
            max(magnitude * Double(Float.ulpOfOne) * 12, distance * 1.0e-4), 1.0e-5)
        for index in loop.indices {
            let current = loop[index], next = loop[(index + 1) % loop.count]
            let sourceA = sourceByID[current]!, sourceB = sourceByID[next]!
            let innerA = innerBySource[current]!, innerB = innerBySource[next]!
            let sourceDirection = simd_normalize(sourceB - sourceA)
            let innerDirection = simd_normalize(innerB - innerA)
            XCTAssertEqual(simd_dot(sourceDirection, innerDirection), 1,
                           accuracy: tolerance / max(simd_length(sourceB - sourceA), 1),
                           file: file, line: line)
            let measured = simd_length(simd_cross(innerA - sourceA, sourceDirection))
            XCTAssertEqual(measured, distance, accuracy: tolerance, file: file, line: line)
        }
    }
    private func worldBounds(of mesh: EditableMesh, transform: ObjectTransform) -> AxisAlignedBoundingBox {
        var bounds = AxisAlignedBoundingBox()
        for vertex in mesh.vertices { bounds.include(transform.worldPosition(fromLocal: vertex.position)) }
        return bounds
    }
    private func double(_ value: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(value.x), Double(value.y), Double(value.z))
    }
    private func waitForWriteCount(
        _ expected: Int, coordinator: ProjectAutosaveCoordinator,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if await coordinator.successfulWriteCount == expected { return }
            await Task.yield()
        }
        let actual = await coordinator.successfulWriteCount
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func selection(_ mesh: EditableMesh, faces: [Int]) throws -> FaceSelection {
        var value = try FaceSelection(sourceTopologyID: mesh.runtime.topologyID,
                                      sourceTopologyRevision: mesh.runtime.topologyRevision,
                                      triangleCount: mesh.indices.count / 3)
        for faceID in faces { _ = try value.set(faceID, selected: true) }
        return value
    }
    @MainActor
    private func configuredModel(
        faces: [Int], pickingCache: MeshBVHCache = MeshBVHCache()
    ) throws -> WorkspaceModel {
        let model = WorkspaceModel(pickingCache: pickingCache)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.add)
        for faceID in faces { XCTAssertTrue(model.applyFaceSelectionHit(faceID)) }
        return model
    }
    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var value = EditableMesh(vertices: positions.map {
            MeshVertex(position: $0, normal: SIMD3<Float>(0, 1, 0))
        }, indices: indices)
        value.recalculateNormals(recordChange: false)
        return value
    }
    private func cubeWithSubdividedTop(
        size: Float, centerXZ: SIMD2<Float> = .zero
    ) throws -> EditableMesh {
        let cube = try PrimitiveMeshBuilder.cube(size: size)
        var positions = cube.vertices.map(\.position)
        positions.append(SIMD3<Float>(centerXZ.x, size * 0.5, centerXZ.y))
        let indices = Array(cube.indices.prefix(30)) + [
            UInt32(3), 7, 8, 7, 6, 8, 6, 2, 8, 2, 3, 8,
        ]
        return mesh(positions, indices)
    }
    private func assertVector(
        _ actual: SIMD3<Double>, _ expected: SIMD3<Double>, accuracy: Double = 1.0e-12,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
    private func assertVector(
        _ actual: SIMD3<Float>, _ expected: SIMD3<Float>, accuracy: Float = 0.000_01,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}

private struct FaceInsetImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
