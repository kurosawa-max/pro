import MetalKit
import SwiftUI
import XCTest
import simd
@testable import Forge3D

final class FaceExtrudeTests: XCTestCase {
    func testChangeVersionAdvancesWithoutReusingOverflowIdentity() {
        let identity = UUID(uuidString: "11111111-AAAA-BBBB-CCCC-222222222222")!
        var normal = FaceExtrudeChangeVersion(identity: identity, value: 10)
        normal.advance()
        XCTAssertEqual(normal, FaceExtrudeChangeVersion(identity: identity, value: 11))

        var boundary = FaceExtrudeChangeVersion(identity: identity, value: .max - 1)
        boundary.advance()
        let maximum = boundary
        XCTAssertEqual(maximum.value, .max)
        boundary.advance()
        XCTAssertEqual(boundary.value, 0)
        XCTAssertNotEqual(boundary.identity, identity)
        XCTAssertNotEqual(boundary, maximum)
        XCTAssertNotEqual(boundary, FaceExtrudeChangeVersion(identity: identity, value: 0))
    }

    func testCubeFaceEstimateHasExactCountsBoundsAndMemory() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let estimate = try FaceExtrude.estimate(
            mesh: cube, selection: try selection(cube, faces: [10, 11]),
            transform: .identity, options: options(2))
        XCTAssertEqual(estimate.originalVertexCount, 8)
        XCTAssertEqual(estimate.originalTriangleCount, 12)
        XCTAssertEqual(estimate.selectedFaceCount, 2)
        XCTAssertEqual(estimate.componentCount, 1)
        XCTAssertEqual(estimate.boundaryEdgeCount, 4)
        XCTAssertEqual(estimate.selectedUniqueVertexCount, 4)
        XCTAssertEqual(estimate.resultingVertexCount, 12)
        XCTAssertEqual(estimate.resultingTriangleCount, 20)
        XCTAssertEqual(estimate.removedOriginalVertexCount, 0)
        XCTAssertEqual(estimate.addedExtrudedVertexCount, 4)
        XCTAssertEqual(estimate.addedSideTriangleCount, 8)
        XCTAssertGreaterThan(estimate.estimatedWorkingByteCount, 0)
        XCTAssertLessThanOrEqual(estimate.estimatedWorkingByteCount, FaceExtrude.maximumWorkingBytes)
        assertVector(estimate.resultBounds.extent, SIMD3<Float>(2, 4, 2))
    }

    func testSingleTriangleAndMultipleComponentsAreClassifiedBySharedEdges() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let single = try FaceExtrude.estimate(
            mesh: cube, selection: try selection(cube, faces: [10]),
            transform: .identity, options: options())
        XCTAssertEqual(single.componentCount, 1)
        XCTAssertEqual(single.boundaryEdgeCount, 3)
        XCTAssertEqual(single.resultingVertexCount, 11)
        XCTAssertEqual(single.resultingTriangleCount, 18)

        let separate = try FaceExtrude.estimate(
            mesh: cube, selection: try selection(cube, faces: [8, 9, 10, 11]),
            transform: .identity, options: options())
        XCTAssertEqual(separate.componentCount, 2)
        XCTAssertEqual(separate.boundaryEdgeCount, 8)
        XCTAssertEqual(separate.addedExtrudedVertexCount, 8)
        XCTAssertEqual(separate.resultingTriangleCount, 28)
    }

    func testVertexOnlyTouchingSelectionsUseSeparateComponentDuplicates() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let estimate = try FaceExtrude.estimate(
            mesh: cube, selection: try selection(cube, faces: [0, 8]),
            transform: .identity, options: options())
        XCTAssertEqual(estimate.componentCount, 2)
        XCTAssertEqual(estimate.selectedUniqueVertexCount, 5)
        XCTAssertEqual(estimate.addedExtrudedVertexCount, 6)
        XCTAssertEqual(estimate.boundaryEdgeCount, 6)
    }

    func testInteriorSelectedVertexIsCompactedAndDuplicatedOnce() throws {
        let source = try cubeWithSubdividedTop()
        let estimate = try FaceExtrude.estimate(
            mesh: source, selection: try selection(source, faces: [10, 11, 12, 13]),
            transform: .identity, options: options())
        XCTAssertEqual(estimate.removedOriginalVertexCount, 1)
        XCTAssertEqual(estimate.addedExtrudedVertexCount, 5)
        XCTAssertEqual(estimate.resultingVertexCount, 13)
        let result = try FaceExtrude.extrude(
            mesh: source, selection: try selection(source, faces: [10, 11, 12, 13]),
            transform: .identity, options: options())
        XCTAssertEqual(result.mesh.vertices.count, 13)
        XCTAssertEqual(result.mesh.vertices.filter { $0.position == SIMD3<Float>(0, 1, 0) }.count, 0)
        XCTAssertEqual(result.mesh.vertices.filter { $0.position == SIMD3<Float>(0, 2, 0) }.count, 1)
    }

    func testResultOrderingWindingTopologyAndNormalsAreDeterministic() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        let first = try FaceExtrude.extrude(
            mesh: cube, selection: selected, transform: .identity, options: options())
        let second = try FaceExtrude.extrude(
            mesh: cube, selection: selected, transform: .identity, options: options())
        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.mesh.indices.prefix(30)), Array(cube.indices.prefix(30)))
        XCTAssertEqual(Array(first.mesh.indices[30..<36]), [9, 11, 10, 9, 10, 8])
        XCTAssertNotEqual(first.mesh.runtime.topologyID, cube.runtime.topologyID)
        XCTAssertTrue(first.mesh.hasCachedAdjacency)
        let topology = MeshTopologyDiagnostics.analyze(first.mesh)
        XCTAssertEqual(topology.degenerateTriangleCount, 0)
        XCTAssertEqual(topology.duplicateTriangleCount, 0)
        XCTAssertEqual(topology.boundaryEdgeCount, 0)
        XCTAssertEqual(topology.nonManifoldEdgeCount, 0)
        XCTAssertEqual(topology.inconsistentWindingEdgeCount, 0)
        XCTAssertTrue(first.mesh.vertices.allSatisfy {
            $0.position.allFinite && $0.normal.allFinite && abs(simd_length($0.normal) - 1) < 0.000_1
        })
    }

    func testPositiveAndNegativeDistancesFollowWindingNormal() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        let positive = try FaceExtrude.extrude(
            mesh: cube, selection: selected, transform: .identity, options: options(2)).mesh
        let negative = try FaceExtrude.extrude(
            mesh: cube, selection: selected, transform: .identity, options: options(-0.5)).mesh
        XCTAssertEqual(positive.vertices.suffix(4).map(\.position.y), [3, 3, 3, 3])
        XCTAssertEqual(negative.vertices.suffix(4).map(\.position.y), [0.5, 0.5, 0.5, 0.5])
    }

    func testNegativeMultipleComponentTopologyRemainsManifoldUnderTransform() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(
            translation: SIMD3<Float>(8, -4, 2),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, 35, 70)),
            scale: SIMD3<Float>(2, 3, 0.5))
        for distance in [-0.001, -0.25, -999.999] {
            let result = try FaceExtrude.extrude(
                mesh: cube, selection: try selection(cube, faces: [8, 9, 10, 11]),
                transform: transform, options: options(distance))
            XCTAssertEqual(result.estimate.componentCount, 2)
            XCTAssertEqual(result.estimate.boundaryEdgeCount, 8)
            let topology = MeshTopologyDiagnostics.analyze(result.mesh)
            XCTAssertEqual(topology.degenerateTriangleCount, 0)
            XCTAssertEqual(topology.duplicateTriangleCount, 0)
            XCTAssertEqual(topology.boundaryEdgeCount, 0)
            XCTAssertEqual(topology.nonManifoldEdgeCount, 0)
            XCTAssertEqual(topology.inconsistentWindingEdgeCount, 0)
            XCTAssertTrue(result.mesh.bounds.isFinite)
            XCTAssertTrue(result.mesh.vertices.allSatisfy {
                $0.normal.allFinite && abs(simd_length($0.normal) - 1) <= 0.000_1
            })
        }
    }

    func testPrecisionCollapsedMinimumDistanceIsRejectedInsteadOfInstalled() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(translation: SIMD3<Float>(100_000_000, 0, 0))
        XCTAssertThrowsError(try FaceExtrude.extrude(
            mesh: cube, selection: try selection(cube, faces: [8, 9]),
            transform: transform, options: options(0.001))) {
            guard let error = $0 as? FaceExtrudeError else {
                return XCTFail("Expected a Face Extrude validation error")
            }
            XCTAssertTrue([.zeroComponentNormal, .inverseTransformFailure,
                           .validationFailed].contains(error))
        }
    }

    func testWorldMillimeterDirectionHandlesTranslationRotationAndNonUniformScale() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(
            translation: SIMD3<Float>(10, -5, 2),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, 35, 70)),
            scale: SIMD3<Float>(2, 3, 4))
        let result = try FaceExtrude.extrude(
            mesh: cube, selection: try selection(cube, faces: [10, 11]),
            transform: transform, options: options(2.5)).mesh
        let originalIDs = [2, 3, 6, 7]
        let expectedNormal = transform.worldNormal(fromLocal: SIMD3<Float>(0, 1, 0))
        for (offset, originalID) in originalIDs.enumerated() {
            let sourceWorld = transform.worldPosition(fromLocal: cube.vertices[originalID].position)
            let resultWorld = transform.worldPosition(fromLocal: result.vertices[8 + offset].position)
            let displacement = resultWorld - sourceWorld
            XCTAssertEqual(simd_length(displacement), 2.5, accuracy: 0.000_1)
            assertVector(simd_normalize(displacement), expectedNormal, accuracy: 0.000_1)
        }
    }

    func testIdentityTranslationRotationUniformAndNonUniformTransformsKeepWorldDistance() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let transforms = [
            ObjectTransform.identity,
            ObjectTransform(translation: SIMD3<Float>(20, -3, 7)),
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(45, 20, -30))),
            ObjectTransform(scale: SIMD3<Float>(repeating: 5)),
            ObjectTransform(translation: SIMD3<Float>(1, 2, 3),
                            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 40, 80)),
                            scale: SIMD3<Float>(2, 5, 0.5)),
        ]
        for transform in transforms {
            let result = try FaceExtrude.extrude(
                mesh: cube, selection: try selection(cube, faces: [10, 11]),
                transform: transform, options: options(3)).mesh
            for (offset, sourceID) in [2, 3, 6, 7].enumerated() {
                let before = transform.worldPosition(fromLocal: cube.vertices[sourceID].position)
                let after = transform.worldPosition(fromLocal: result.vertices[8 + offset].position)
                XCTAssertEqual(simd_length(after - before), 3, accuracy: 0.000_5)
            }
        }
    }

    func testAreaWeightedComponentNormalUsesAllSelectedFaces() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let result = try FaceExtrude.extrude(
            mesh: cube, selection: try selection(cube, faces: [0, 11]),
            transform: .identity, options: options()).mesh
        let expected = simd_normalize(SIMD3<Float>(0, 1, -1))
        let sourceIDs = [0, 2, 3, 6]
        for (offset, sourceID) in sourceIDs.enumerated() {
            let delta = result.vertices[8 + offset].position - cube.vertices[sourceID].position
            assertVector(delta, expected, accuracy: 0.000_1)
        }
    }

    func testPreviewSourceKeyRejectsDistanceAndNonRewindingChanges() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10, 11])
        let meshIdentity = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let transformIdentity = UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!
        let meshVersion = FaceExtrudeChangeVersion(identity: meshIdentity, value: 4)
        let transformVersion = FaceExtrudeChangeVersion(identity: transformIdentity, value: 8)
        let preview = try FaceExtrude.makePreview(
            mesh: cube, selection: selected, transform: .identity, options: options(),
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion)
        XCTAssertTrue(preview.source.matches(
            mesh: cube, selection: selected, transform: .identity,
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            options: options()))
        var changedMesh = meshVersion
        changedMesh.advance()
        XCTAssertFalse(preview.source.matches(
            mesh: cube, selection: selected, transform: .identity,
            meshChangeVersion: changedMesh, transformChangeVersion: transformVersion,
            options: options()))
        XCTAssertFalse(preview.source.matches(
            mesh: cube, selection: selected, transform: .identity,
            meshChangeVersion: meshVersion, transformChangeVersion: transformVersion,
            options: options(2)))
    }

    func testNoSelectionAndStaleSelectionAreRejected() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertThrowsError(try FaceExtrude.estimate(
            mesh: cube, selection: try selection(cube, faces: []),
            transform: .identity, options: options())) {
            XCTAssertEqual($0 as? FaceExtrudeError, .noSelection)
        }
        var stale = try FaceSelection(sourceTopologyID: UUID(), sourceTopologyRevision: 1,
                                      triangleCount: cube.indices.count / 3)
        _ = try stale.set(0, selected: true)
        XCTAssertThrowsError(try FaceExtrude.estimate(
            mesh: cube, selection: stale, transform: .identity, options: options())) {
            XCTAssertEqual($0 as? FaceExtrudeError, .staleSelection)
        }
    }

    func testDistanceValidationRejectsZeroTinyNonFiniteAndOutsideLimit() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(cube, faces: [10])
        for (distance, expected) in [
            (0.0, FaceExtrudeError.distanceTooSmall),
            (0.000_1, .distanceTooSmall),
            (Double.nan, .invalidDistance),
            (Double.infinity, .invalidDistance),
            (1_000.1, .distanceLimitExceeded),
        ] {
            XCTAssertThrowsError(try FaceExtrude.estimate(
                mesh: cube, selection: selected, transform: .identity,
                options: options(distance))) { XCTAssertEqual($0 as? FaceExtrudeError, expected) }
        }
    }

    func testInvalidMeshValuesDegenerateDuplicateAndIndexAreRejected() throws {
        let invalidIndex = mesh(cubePositions, [0, 1, 99])
        try assertExtrudeError(invalidIndex, faces: [0], expected: .invalidMesh)

        let nonFinitePosition = mesh([
            SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)
        ], [0, 1, 2])
        try assertExtrudeError(nonFinitePosition, faces: [0], expected: .nonFiniteValue)

        let nonFiniteNormal = EditableMesh(vertices: [
            MeshVertex(position: SIMD3(0, 0, 0), normal: SIMD3(.infinity, 0, 0)),
            MeshVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)),
        ], indices: [0, 1, 2])
        try assertExtrudeError(nonFiniteNormal, faces: [0], expected: .nonFiniteValue)

        let degenerate = mesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)], [0, 1, 2])
        try assertExtrudeError(degenerate, faces: [0], expected: .degenerateTriangle)

        let duplicate = mesh(cubePositions, [0, 1, 2, 2, 0, 1])
        try assertExtrudeError(duplicate, faces: [0], expected: .duplicateTriangle)
    }

    func testDistantMeshIssuePolicyIsExplicitAndCountPreserving() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let distantDegenerate = appendedMesh(
            cube,
            positions: [SIMD3(10, 0, 0), SIMD3(11, 0, 0), SIMD3(12, 0, 0)],
            indices: [0, 1, 2])
        try assertExtrudeError(distantDegenerate, faces: [10, 11], expected: .degenerateTriangle)

        let distantDuplicate = appendedMesh(
            cube,
            positions: [SIMD3(10, 0, 0), SIMD3(11, 0, 0), SIMD3(10, 1, 0)],
            indices: [0, 1, 2, 0, 1, 2])
        try assertExtrudeError(distantDuplicate, faces: [10, 11], expected: .duplicateTriangle)

        let distantOpen = appendedMesh(
            cube,
            positions: [SIMD3(10, 0, 0), SIMD3(11, 0, 0), SIMD3(10, 1, 0)],
            indices: [0, 1, 2])
        let distantNonManifold = appendedMesh(
            cube,
            positions: [SIMD3(10, 0, 0), SIMD3(11, 0, 0), SIMD3(10, 1, 0),
                        SIMD3(10, -1, 0), SIMD3(10, 0, 1)],
            indices: [0, 1, 2, 1, 0, 3, 0, 1, 4])
        let distantWinding = appendedMesh(
            cube,
            positions: [SIMD3(10, 0, 0), SIMD3(11, 0, 0), SIMD3(10, 1, 0), SIMD3(10, -1, 0)],
            indices: [0, 1, 2, 0, 1, 3])

        for source in [distantOpen, distantNonManifold, distantWinding] {
            let sourceTopology = MeshTopologyDiagnostics.analyze(source)
            let result = try FaceExtrude.extrude(
                mesh: source, selection: try selection(source, faces: [10, 11]),
                transform: .identity, options: options())
            let resultTopology = MeshTopologyDiagnostics.analyze(result.mesh)
            XCTAssertEqual(resultTopology.boundaryEdgeCount, sourceTopology.boundaryEdgeCount)
            XCTAssertEqual(resultTopology.nonManifoldEdgeCount, sourceTopology.nonManifoldEdgeCount)
            XCTAssertEqual(resultTopology.inconsistentWindingEdgeCount,
                           sourceTopology.inconsistentWindingEdgeCount)
            XCTAssertEqual(resultTopology.degenerateTriangleCount, 0)
            XCTAssertEqual(resultTopology.duplicateTriangleCount, 0)
        }
    }

    func testOpenNonManifoldWindingAndWholeShellSelectionsAreRejected() throws {
        let open = mesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2])
        try assertExtrudeError(open, faces: [0], expected: .openSelectedEdge)

        let nonManifold = mesh([
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0, -1, 0), SIMD3(0, 0, 1),
        ], [0, 1, 2, 1, 0, 3, 0, 1, 4])
        try assertExtrudeError(nonManifold, faces: [0], expected: .nonManifoldSelectedEdge)

        let winding = mesh([
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0)
        ], [0, 1, 2, 0, 1, 3])
        try assertExtrudeError(winding, faces: [0], expected: .windingConflict)

        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        try assertExtrudeError(cube, faces: Array(0..<12), expected: .boundarylessComponent)
    }

    func testNonFiniteTransformAndWorkingMemoryOverflowAreRejected() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        var transform = ObjectTransform.identity
        transform.translation.x = .nan
        XCTAssertThrowsError(try FaceExtrude.estimate(
            mesh: cube, selection: try selection(cube, faces: [10]),
            transform: transform, options: options())) {
            XCTAssertEqual($0 as? FaceExtrudeError, .invalidTransform)
        }
        XCTAssertThrowsError(try FaceExtrude.estimatedWorkingBytes(
            originalVertices: .max, originalTriangles: .max, selectedFaces: .max,
            boundaryEdges: .max, resultingVertices: .max, resultingTriangles: .max)) {
            XCTAssertEqual($0 as? FaceExtrudeError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try FaceExtrude.validateWorkingByteCount(
            FaceExtrude.maximumWorkingBytes + 1)) {
            XCTAssertEqual($0 as? FaceExtrudeError, .workingMemoryLimitExceeded)
        }
        XCTAssertThrowsError(try FaceExtrude.validateWorkingByteCount(-1)) {
            XCTAssertEqual($0 as? FaceExtrudeError, .arithmeticOverflow)
        }
        XCTAssertEqual(FaceExtrude.maximumVertices, MeshCleanup.maximumVertices)
        XCTAssertEqual(FaceExtrude.maximumTriangles, MeshCleanup.maximumTriangles)
        XCTAssertEqual(FaceExtrude.maximumWorkingBytes, MeshCleanup.maximumWorkingBytes)
    }

    @MainActor
    func testWorkspaceApplyPreservesToolsAndRecordsOneReplaceCommand() throws {
        let model = try configuredModel(faces: [10, 11])
        let transform = ObjectTransform(translation: SIMD3(4, 5, 6),
                                        rotation: ObjectTransform.rotation(degrees: SIMD3(10, 20, 30)),
                                        scale: SIMD3(2, 3, 4))
        model.updateTransform(transform)
        model.camera = CameraState(yaw: 0.7, pitch: -0.2, distance: 11,
                                   target: SIMD3(1, 2, 3))
        model.brush = .crease
        model.symmetry = SculptSymmetry(x: true, y: false, z: true)
        model.setGizmoMode(.rotate)
        let camera = model.camera, brush = model.brush, symmetry = model.symmetry
        let operation = model.faceSelectionOperation, undoBefore = model.undoCount
        let generationBefore = model.projectMutationGeneration
        let dirtyBefore = model.isDirty
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options(2))
        XCTAssertEqual(model.projectMutationGeneration, generationBefore)
        XCTAssertEqual(model.isDirty, dirtyBefore)
        let result = try model.applyFaceExtrude(preview: preview)
        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.brush, brush)
        XCTAssertEqual(model.symmetry, symmetry)
        XCTAssertEqual(model.gizmoMode, .rotate)
        XCTAssertEqual(model.interactionMode, .faceSelect)
        XCTAssertEqual(model.faceSelectionOperation, operation)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.faceExtrudePreview)
        XCTAssertEqual(model.undoCount, undoBefore + 1)
        XCTAssertNotEqual(model.projectMutationGeneration, generationBefore)
        XCTAssertEqual(model.projectMutationGeneration.overflowIdentity, generationBefore.overflowIdentity)
        XCTAssertEqual(model.projectMutationGeneration.value, generationBefore.value + 1)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.mesh.vertices.count, 12)
        XCTAssertEqual(model.mesh.indices.count / 3, 20)
    }

    @MainActor
    func testPreviewAndCancelDoNotMutateProjectSelectionOrHistory() throws {
        let model = try configuredModel(faces: [10, 11])
        let mesh = model.mesh, transform = model.objectTransform, camera = model.camera
        let selection = model.faceSelection, history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration, data = try model.projectData()
        try model.prepareForFaceExtrude()
        _ = try model.previewFaceExtrude(options: options())
        model.discardFaceExtrudePreview()
        XCTAssertEqual(model.mesh, mesh)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), data)
        XCTAssertNil(model.faceExtrudePreview)
    }

    @MainActor
    func testPreparationCancelsConnectedSelectionProcessingAndKeepsSelection() throws {
        let model = try configuredModel(faces: [10])
        let selected = model.faceSelection
        model.selectConnectedFaces()
        XCTAssertTrue(model.isFaceSelectionProcessing)
        try model.prepareForFaceExtrude()
        XCTAssertFalse(model.isFaceSelectionProcessing)
        XCTAssertEqual(model.faceSelection, selected)
        XCTAssertTrue(model.canBeginFaceExtrude)
    }

    @MainActor
    func testWorkspaceFailureIsAtomicExceptForErrorState() throws {
        let open = mesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2])
        let model = WorkspaceModel()
        model.mesh = open
        model.setInteractionMode(.faceSelect)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        let source = model.mesh, selection = model.faceSelection, transform = model.objectTransform
        let camera = model.camera, history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration, data = try model.projectData()
        try model.prepareForFaceExtrude()
        XCTAssertThrowsError(try model.previewFaceExtrude(options: options()))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), data)
        XCTAssertNotNil(model.faceExtrudeError)
    }

    @MainActor
    func testWorkspacePreviewStalesAfterMeshTransformSelectionAndExactRestoration() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceExtrude()
        _ = try model.previewFaceExtrude(options: options())
        let originalMesh = model.mesh
        _ = model.mesh.updatePositions([0: model.mesh.vertices[0].position + SIMD3(0.01, 0, 0)])
        model.mesh = originalMesh
        XCTAssertTrue(model.isFaceExtrudePreviewStale)

        _ = try model.previewFaceExtrude(options: options())
        let originalTransform = model.objectTransform
        model.updateTranslation(SIMD3(1, 0, 0))
        model.undo()
        XCTAssertEqual(model.objectTransform, originalTransform)
        XCTAssertTrue(model.isFaceExtrudePreviewStale)

        _ = try model.previewFaceExtrude(options: options())
        model.setFaceSelectionOperation(.remove)
        XCTAssertTrue(model.applyFaceSelectionHit(10))
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(10))
        XCTAssertEqual(model.selectedFaceCount, 2)
        XCTAssertTrue(model.isFaceExtrudePreviewStale)
    }

    @MainActor
    func testFailedPreviewRecalculationInvalidatesPreviousModelPreview() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceExtrude()
        let original = try model.previewFaceExtrude(options: options())
        XCTAssertTrue(model.isFaceExtrudePreviewCurrent(original))
        XCTAssertThrowsError(try model.previewFaceExtrude(options: options(0))) {
            XCTAssertEqual($0 as? FaceExtrudeError, .distanceTooSmall)
        }
        XCTAssertNil(model.faceExtrudePreview)
        XCTAssertFalse(model.isFaceExtrudePreviewCurrent(original))
        XCTAssertNotNil(model.faceExtrudeError)
    }

    @MainActor
    func testUndoRedoRestoreMeshesWithoutRestoringSelection() throws {
        let model = try configuredModel(faces: [10, 11])
        let before = model.mesh
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        let after = try model.applyFaceExtrude(preview: preview).mesh
        let generationAfterApply = model.projectMutationGeneration
        model.undo()
        XCTAssertEqual(model.mesh, before)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertTrue(model.canRedo)
        XCTAssertNotEqual(model.projectMutationGeneration, generationAfterApply)
        let generationAfterUndo = model.projectMutationGeneration
        model.redo()
        XCTAssertEqual(model.mesh, after)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNotEqual(model.projectMutationGeneration, generationAfterUndo)
        XCTAssertTrue(model.mesh.hasCachedAdjacency)
    }

    func testBVHRebuildFailureInvalidatesStaleCacheAndLaterPickingRetries() throws {
        var failNextBuild = false
        let cache = MeshBVHCache(builder: { mesh in
            if failNextBuild {
                failNextBuild = false
                throw MeshBVHError.invalidMesh
            }
            return try MeshBVH(mesh: mesh)
        })
        let original = EditableMesh.icosphere(subdivisions: 0)
        XCTAssertNotNil(cache.index(for: original))
        XCTAssertEqual(cache.topologyID, original.runtime.topologyID)

        let replacement = EditableMesh.icosphere(subdivisions: 1)
        failNextBuild = true
        XCTAssertFalse(cache.rebuild(for: replacement))
        XCTAssertNil(cache.bvh)
        XCTAssertNil(cache.topologyID)
        XCTAssertNil(cache.topologyRevision)
        XCTAssertNil(cache.revision)

        let ray = Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1))
        let unavailable = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        XCTAssertNil(MeshPicker.hit(ray: ray, mesh: replacement, profiler: nil,
                                    cache: unavailable))
        XCTAssertNil(unavailable.bvh)
        let indexed = MeshPicker.indexedHit(ray: ray, mesh: replacement, culling: .none,
                                            profiler: nil, cache: cache)
        guard case .hit(let hit) = indexed else {
            return XCTFail("Picking should rebuild the invalidated cache")
        }
        XCTAssertTrue((0..<(replacement.indices.count / 3)).contains(hit.triangleIndex))
        XCTAssertNotNil(MeshPicker.hit(ray: ray, mesh: replacement, profiler: nil, cache: cache))
        XCTAssertEqual(cache.topologyID, replacement.runtime.topologyID)
    }

    @MainActor
    func testUndoRedoBVHFailureNeverUsesStaleTopologyAndCanRetry() throws {
        var failNextBuild = false
        let cache = MeshBVHCache(builder: { mesh in
            if failNextBuild {
                failNextBuild = false
                throw MeshBVHError.invalidMesh
            }
            return try MeshBVH(mesh: mesh)
        })
        let model = try configuredModel(faces: [10, 11], pickingCache: cache)
        let before = model.mesh
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        let after = try model.applyFaceExtrude(preview: preview).mesh
        _ = try model.analyzeCurrentMesh()
        XCTAssertNotNil(model.currentMeshDiagnosticsReport)

        failNextBuild = true
        model.undo()
        XCTAssertEqual(model.mesh, before)
        XCTAssertFalse(model.pickingCacheHasIndexForTesting)
        XCTAssertNil(model.pickingCacheTopologyIDForTesting)
        XCTAssertNil(model.currentMeshDiagnosticsReport)
        XCTAssertTrue(model.selectFace(fromWorldRay: Ray(
            origin: SIMD3<Float>(0, 4, 0), direction: SIMD3<Float>(0, -1, 0))))
        XCTAssertEqual(model.pickingCacheTopologyIDForTesting, model.mesh.runtime.topologyID)
        _ = try model.analyzeCurrentMesh()
        XCTAssertNotNil(model.currentMeshDiagnosticsReport)

        failNextBuild = true
        model.redo()
        XCTAssertEqual(model.mesh, after)
        XCTAssertFalse(model.pickingCacheHasIndexForTesting)
        XCTAssertNil(model.currentMeshDiagnosticsReport)
        XCTAssertTrue(model.selectFace(fromWorldRay: Ray(
            origin: SIMD3<Float>(0, 4, 0), direction: SIMD3<Float>(0, -1, 0))))
        XCTAssertEqual(model.pickingCacheTopologyIDForTesting, model.mesh.runtime.topologyID)
    }

    @MainActor
    func testPickingBVHPreparationFailureLeavesWorkspaceAtomic() throws {
        let cache = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        let model = try configuredModel(faces: [10, 11], pickingCache: cache)
        _ = try model.analyzeCurrentMesh()
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        let sourceMesh = model.mesh
        let sourceTransform = model.objectTransform
        let sourceCamera = model.camera
        let sourceSelection = model.faceSelection
        let sourceHistory = (model.undoCount, model.redoCount, model.canUndo, model.canRedo)
        let sourceGeneration = model.projectMutationGeneration
        let sourceProject = try model.projectData()
        let sourceSTL = try model.stlData()
        let sourceDiagnostics = model.currentMeshDiagnosticsReport
        let sourceProfiler = model.profiler?.snapshot()

        XCTAssertThrowsError(try model.applyFaceExtrude(preview: preview)) { error in
            guard let pickingError = error as? MeshBVHError,
                  case .invalidMesh = pickingError else {
                return XCTFail("Expected the injected Picking BVH build failure")
            }
        }
        XCTAssertEqual(model.mesh, sourceMesh)
        XCTAssertEqual(model.objectTransform, sourceTransform)
        XCTAssertEqual(model.camera, sourceCamera)
        XCTAssertEqual(model.faceSelection, sourceSelection)
        XCTAssertEqual(model.undoCount, sourceHistory.0)
        XCTAssertEqual(model.redoCount, sourceHistory.1)
        XCTAssertEqual(model.canUndo, sourceHistory.2)
        XCTAssertEqual(model.canRedo, sourceHistory.3)
        XCTAssertEqual(model.projectMutationGeneration, sourceGeneration)
        XCTAssertEqual(try model.projectData(), sourceProject)
        XCTAssertEqual(try model.stlData(), sourceSTL)
        XCTAssertEqual(model.currentMeshDiagnosticsReport, sourceDiagnostics)
        XCTAssertEqual(model.profiler?.snapshot(), sourceProfiler)
        XCTAssertEqual(model.faceExtrudePreview, preview)
        XCTAssertFalse(model.isFaceExtrudeSnapshotSafeForTesting)
    }

    @MainActor
    func testApplyInvalidatesDiagnosticsAndRebuildsRuntimeIndexes() throws {
        let model = try configuredModel(faces: [10, 11])
        _ = try model.analyzeCurrentMesh()
        XCTAssertNotNil(model.currentMeshDiagnosticsReport)
        let spatialBuilds = model.sculptSpatialIndexBuildCount
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        _ = try model.applyFaceExtrude(preview: preview)
        XCTAssertNil(model.currentMeshDiagnosticsReport)
        XCTAssertNil(model.currentMeshDiagnosticsOverlay)
        XCTAssertGreaterThan(model.sculptSpatialIndexBuildCount, spatialBuilds)
        XCTAssertTrue(model.mesh.hasCachedAdjacency)
    }

    @MainActor
    func testSuccessfulInstallUploadsTopologyOnceAndClearsSelectionOverlay() throws {
        #if targetEnvironment(simulator)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        let model = try configuredModel(faces: [10, 11])
        renderer.update(mesh: model.mesh)
        XCTAssertTrue(renderer.updateFaceSelection(mesh: model.mesh, selection: model.faceSelection))
        profiler.reset(vertexCount: model.mesh.vertices.count, triangleCount: model.mesh.indices.count / 3)

        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        _ = try model.applyFaceExtrude(preview: preview)
        renderer.update(mesh: model.mesh)
        XCTAssertTrue(renderer.updateFaceSelection(mesh: model.mesh, selection: model.faceSelection))
        XCTAssertEqual(renderer.faceSelectionOverlayIndexCount, 0)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        #endif
    }

    @MainActor
    func testPersistenceRoundTripKeepsFormatOneAndExtrudedGeometryOnly() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        _ = try model.applyFaceExtrude(preview: preview)
        let data = try model.projectData()
        let decoded = try ProjectCodec.decode(data)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.mesh, model.mesh)
        XCTAssertEqual(decoded.transform, model.objectTransform)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("faceExtrude"))
        XCTAssertFalse(text.contains("faceSelection"))
        let stl = try BinarySTLExporter.data(for: model.mesh, transform: model.objectTransform)
        XCTAssertEqual(stl.count, 84 + model.mesh.indices.count / 3 * 50)
    }

    @MainActor
    func testApplySchedulesExactlyOneAutosaveFromCompletedMesh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceExtrudeAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: FaceExtrudeImmediateScheduler(), debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(10))
        XCTAssertTrue(model.applyFaceSelectionHit(11))
        try model.prepareForFaceExtrude()
        let preview = try model.previewFaceExtrude(options: options())
        _ = try model.applyFaceExtrude(preview: preview)
        XCTAssertFalse(model.isFaceExtrudeSnapshotSafeForTesting)
        await waitForWriteCount(1, coordinator: coordinator)
        var recovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(recovery.project.mesh, model.mesh)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, model.projectMutationGeneration)

        model.undo()
        await waitForWriteCount(2, coordinator: coordinator)
        recovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(recovery.project.mesh, model.mesh)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, model.projectMutationGeneration)

        model.redo()
        await waitForWriteCount(3, coordinator: coordinator)
        recovery = try await coordinator.inspectRecovery()
        XCTAssertEqual(recovery.project.mesh, model.mesh)
        XCTAssertEqual(recovery.descriptor.sourceGeneration, model.projectMutationGeneration)
    }

    @MainActor
    func testPanelAndSheetFitCompactAndAccessibilityLayouts() throws {
        let model = try configuredModel(faces: [10, 11])
        for width in [CGFloat(320), 744, 1_024] {
            let panel = UIHostingController(rootView: FaceSelectionPanel(model: model) {})
            let panelSize = panel.sizeThatFits(in: CGSize(width: width, height: 1_400))
            XCTAssertLessThanOrEqual(panelSize.width, width + 1)
            XCTAssertGreaterThan(panelSize.height, 0)

            let sheet = UIHostingController(rootView: FaceExtrudeView(model: model)
                .environment(\.dynamicTypeSize, .accessibility3))
            let sheetSize = sheet.sizeThatFits(in: CGSize(width: width, height: 1_600))
            XCTAssertTrue(sheetSize.width.isFinite && sheetSize.height.isFinite)
            XCTAssertLessThanOrEqual(sheetSize.width, width + 1)
            XCTAssertGreaterThan(sheetSize.height, 0)
        }
    }

    private func options(_ distance: Double = 1) -> FaceExtrudeOptions {
        FaceExtrudeOptions(distanceMillimeters: distance)
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

    private func appendedMesh(
        _ source: EditableMesh,
        positions: [SIMD3<Float>],
        indices: [UInt32]
    ) -> EditableMesh {
        let offset = UInt32(source.vertices.count)
        return mesh(source.vertices.map(\.position) + positions,
                    source.indices + indices.map { $0 + offset })
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

    private func assertExtrudeError(
        _ source: EditableMesh, faces: [Int], expected: FaceExtrudeError,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let selected = try selection(source, faces: faces)
        XCTAssertThrowsError(try FaceExtrude.estimate(
            mesh: source, selection: selected, transform: .identity, options: options()),
            file: file, line: line) {
            XCTAssertEqual($0 as? FaceExtrudeError, expected, file: file, line: line)
        }
    }

    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var value = EditableMesh(vertices: positions.map {
            MeshVertex(position: $0, normal: SIMD3<Float>(0, 0, 1))
        }, indices: indices)
        value.recalculateNormals(recordChange: false)
        return value
    }

    private func cubeWithSubdividedTop() throws -> EditableMesh {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        var positions = cube.vertices.map(\.position)
        positions.append(SIMD3<Float>(0, 1, 0))
        let indices = Array(cube.indices.prefix(30)) + [
            UInt32(3), 7, 8, 7, 6, 8, 6, 2, 8, 2, 3, 8,
        ]
        return mesh(positions, indices)
    }

    private var cubePositions: [SIMD3<Float>] {
        [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
         SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
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

private struct FaceExtrudeImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
