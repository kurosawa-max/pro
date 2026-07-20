import MetalKit
import SwiftUI
import XCTest
import simd
@testable import Forge3D

final class MeshLinearArrayTests: XCTestCase {
    func testPreviewRequestCoordinatorKeepsOnlyLatestRequestBusy() {
        var coordinator = MeshLinearArrayPreviewRequestCoordinator()
        let requestA = UUID()
        let requestB = UUID()

        XCTAssertEqual(coordinator.begin(requestID: requestA), requestA)
        XCTAssertTrue(coordinator.isCalculating)
        XCTAssertTrue(coordinator.isCurrent(requestA))

        XCTAssertEqual(coordinator.invalidate(), requestA)
        XCTAssertFalse(coordinator.isCalculating)
        XCTAssertFalse(coordinator.isCurrent(requestA))

        XCTAssertEqual(coordinator.begin(requestID: requestB), requestB)
        XCTAssertFalse(coordinator.finish(requestA))
        XCTAssertTrue(coordinator.isCalculating)
        XCTAssertTrue(coordinator.isCurrent(requestB))
        XCTAssertTrue(coordinator.finish(requestB))
        XCTAssertFalse(coordinator.isCalculating)
    }

    @MainActor
    func testOptionsChangeRejectsRequestAAndAllowsRecalculation() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        var coordinator = MeshLinearArrayPreviewRequestCoordinator()
        let requestA = coordinator.begin()
        try model.beginMeshLinearArrayPreviewRequest(requestA)
        let candidateA = try model.makeMeshLinearArrayPreviewCandidate(
            options: options(axis: .x, count: 2, spacing: 10),
            requestID: requestA)

        XCTAssertEqual(coordinator.invalidate(), requestA)
        model.discardMeshLinearArrayPreview(requestID: requestA)
        XCTAssertFalse(model.completeMeshLinearArrayPreviewRequest(
            requestID: requestA,
            candidate: candidateA))
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertFalse(model.isMeshLinearArrayRunning)
        XCTAssertFalse(coordinator.isCalculating)

        let requestB = coordinator.begin()
        XCTAssertNoThrow(try model.beginMeshLinearArrayPreviewRequest(requestB))
        model.discardMeshLinearArrayPreview(requestID: requestB)
        XCTAssertTrue(coordinator.finish(requestB))
        XCTAssertFalse(model.isMeshLinearArrayRunning)
    }

    @MainActor
    func testRequestACompletionAndFailureCannotClearOrPublishOverRequestB() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        var coordinator = MeshLinearArrayPreviewRequestCoordinator()

        let requestA = coordinator.begin()
        try model.beginMeshLinearArrayPreviewRequest(requestA)
        let candidateA = try model.makeMeshLinearArrayPreviewCandidate(
            options: options(axis: .x, count: 2, spacing: 10),
            requestID: requestA)
        _ = coordinator.invalidate()
        model.discardMeshLinearArrayPreview(requestID: requestA)

        let requestB = coordinator.begin()
        let optionsB = options(axis: .y, count: 3, spacing: -5)
        try model.beginMeshLinearArrayPreviewRequest(requestB)
        XCTAssertFalse(model.completeMeshLinearArrayPreviewRequest(
            requestID: requestA,
            candidate: candidateA))
        XCTAssertFalse(model.failMeshLinearArrayPreviewRequest(
            requestID: requestA,
            error: MeshLinearArrayError.invalidSpacing))
        XCTAssertFalse(coordinator.finish(requestA))
        XCTAssertTrue(model.isMeshLinearArrayRunning)
        XCTAssertTrue(coordinator.isCalculating)
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertNil(model.meshLinearArrayError)

        let candidateB = try model.makeMeshLinearArrayPreviewCandidate(
            options: optionsB,
            requestID: requestB)
        XCTAssertTrue(model.completeMeshLinearArrayPreviewRequest(
            requestID: requestB,
            candidate: candidateB))
        XCTAssertTrue(coordinator.finish(requestB))
        XCTAssertEqual(model.meshLinearArrayPreview, candidateB)
        XCTAssertFalse(model.isMeshLinearArrayRunning)
        XCTAssertFalse(coordinator.isCalculating)
    }

    @MainActor
    func testDismissalInvalidatesRequestAndPreventsGhostPreview() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        var coordinator = MeshLinearArrayPreviewRequestCoordinator()
        let request = coordinator.begin()
        try model.beginMeshLinearArrayPreviewRequest(request)
        let candidate = try model.makeMeshLinearArrayPreviewCandidate(
            options: options(),
            requestID: request)

        XCTAssertEqual(coordinator.invalidate(), request)
        model.discardMeshLinearArrayPreview(requestID: request)
        XCTAssertFalse(model.completeMeshLinearArrayPreviewRequest(
            requestID: request,
            candidate: candidate))
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertFalse(model.isMeshLinearArrayRunning)
        XCTAssertFalse(coordinator.isCalculating)
        XCTAssertThrowsError(try model.applyMeshLinearArray(preview: candidate)) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .stalePreview)
        }
    }

    @MainActor
    func testInvalidatedRequestFailureDoesNotPublishErrorOrRemainBusy() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        var coordinator = MeshLinearArrayPreviewRequestCoordinator()
        let request = coordinator.begin()
        try model.beginMeshLinearArrayPreviewRequest(request)

        _ = coordinator.invalidate()
        model.discardMeshLinearArrayPreview(requestID: request)
        XCTAssertFalse(model.failMeshLinearArrayPreviewRequest(
            requestID: request,
            error: MeshLinearArrayError.invalidSpacing))
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertNil(model.meshLinearArrayError)
        XCTAssertFalse(model.isMeshLinearArrayRunning)
        XCTAssertFalse(coordinator.isCalculating)
    }

    func testDefaultOptionsAndDocumentedLimits() {
        let options = MeshLinearArrayOptions()
        XCTAssertEqual(options.axis, .x)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.spacingMillimeters, 10)
        XCTAssertEqual(MeshLinearArray.minimumCount, 2)
        XCTAssertEqual(MeshLinearArray.maximumCount, 256)
        XCTAssertEqual(MeshLinearArray.minimumSpacingMillimeters, 0.001)
        XCTAssertEqual(MeshLinearArray.maximumSpacingMillimeters, 1_000)
        XCTAssertEqual(MeshLinearArray.maximumVertices, 2_000_000)
        XCTAssertEqual(MeshLinearArray.maximumTriangles, 4_000_000)
        XCTAssertEqual(MeshLinearArray.maximumWorkingBytes, 768 * 1_024 * 1_024)
    }

    func testCountAndSpacingBoundaries() throws {
        let source = singleTriangle()
        for count in [2, 3, 10, 256] {
            let estimate = try MeshLinearArray.estimate(
                mesh: source, transform: .identity,
                options: options(count: count, spacing: 0.001))
            XCTAssertEqual(estimate.count, count)
        }
        for spacing in [0.001, -0.001, 1_000.0, -1_000.0] {
            let estimate = try MeshLinearArray.estimate(
                mesh: source, transform: .identity,
                options: options(count: 2, spacing: spacing))
            XCTAssertEqual(estimate.spacingMillimeters, spacing)
        }
        for count in [Int.min, -1, 0, 1, 257, Int.max] {
            XCTAssertThrowsError(try MeshLinearArray.estimate(
                mesh: source, transform: .identity,
                options: options(count: count, spacing: 10))) {
                XCTAssertEqual($0 as? MeshLinearArrayError, .invalidCount)
            }
        }
        for spacing in [0, 0.000_9, -0.000_9, 1_000.1, -1_000.1, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try MeshLinearArray.estimate(
                mesh: source, transform: .identity,
                options: options(count: 2, spacing: spacing))) {
                XCTAssertEqual($0 as? MeshLinearArrayError, .invalidSpacing)
            }
        }
    }

    func testSingleTriangleUsesExactCountsAndCopyMajorMapping() throws {
        let source = singleTriangle()
        let result = try MeshLinearArray.array(
            mesh: source, transform: .identity,
            options: options(axis: .x, count: 3, spacing: 5))
        XCTAssertEqual(result.mesh.vertices.count, 9)
        XCTAssertEqual(result.mesh.indices.count / 3, 3)
        XCTAssertEqual(Array(result.mesh.vertices.prefix(3)).map(\.position), source.vertices.map(\.position))
        XCTAssertEqual(Array(result.mesh.indices.prefix(3)), source.indices)
        XCTAssertEqual(result.mesh.indices, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        for copy in 0..<3 {
            for sourceID in source.vertices.indices {
                let position = result.mesh.vertices[copy * source.vertices.count + sourceID].position
                XCTAssertEqual(position.x, source.vertices[sourceID].position.x + Float(copy * 5), accuracy: 0.000_01)
                XCTAssertEqual(position.y, source.vertices[sourceID].position.y, accuracy: 0.000_01)
                XCTAssertEqual(position.z, source.vertices[sourceID].position.z, accuracy: 0.000_01)
            }
        }
        assertValid(result.mesh, components: 3, boundaryEdges: 9)
    }

    func testAllAxesAndSignedDirectionMaintainRequestedWorldSpacing() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        for axis in LinearArrayAxis.allCases {
            for spacing in [7.25, -7.25] {
                let options = options(axis: axis, count: 4, spacing: spacing)
                let result = try MeshLinearArray.array(
                    mesh: source, transform: .identity, options: options)
                assertWorldSpacing(result.mesh, source: source, transform: .identity, options: options)
                XCTAssertEqual(result.estimate.totalSpanMillimeters, spacing * 3)
                assertValid(result.mesh, components: 4, boundaryEdges: 0)
            }
        }
    }

    func testTranslationRotationUniformAndNonUniformScaleUseWorldMillimeters() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let transforms = [
            ObjectTransform.identity,
            ObjectTransform(translation: SIMD3<Float>(20, -30, 40)),
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, 35, -15))),
            ObjectTransform(scale: SIMD3<Float>(repeating: 3)),
            ObjectTransform(scale: SIMD3<Float>(2, 5, 0.25)),
            ObjectTransform(
                translation: SIMD3<Float>(100, -250, 70),
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(25, -40, 65)),
                scale: SIMD3<Float>(0.1, 8, 2)),
        ]
        for transform in transforms {
            for axis in LinearArrayAxis.allCases {
                let requested = options(axis: axis, count: 5, spacing: -12.5)
                let result = try MeshLinearArray.array(mesh: source, transform: transform, options: requested)
                assertWorldSpacing(result.mesh, source: source, transform: transform, options: requested)
                assertBoundsApproximatelyEqual(
                    result.estimate.resultWorldBounds,
                    worldBounds(result.mesh, transform),
                    accuracy: 0.001)
            }
        }
    }

    func testCopiesUseSourceFormulaWithoutCumulativeDrift() throws {
        let source = singleTriangle()
        let requested = options(axis: .y, count: 10, spacing: 0.125)
        let result = try MeshLinearArray.array(mesh: source, transform: .identity, options: requested)
        for copy in 0..<requested.count {
            let actual = result.mesh.vertices[copy * source.vertices.count].position
            XCTAssertEqual(actual.y, source.vertices[0].position.y + Float(Double(copy) * requested.spacingMillimeters), accuracy: 0.000_001)
        }
        XCTAssertEqual(result.mesh.vertices[9 * source.vertices.count].position.y, 1.125, accuracy: 0.000_001)
    }

    func testOpenClosedAndMultipleComponentsMultiplyTopologyMetrics() throws {
        let open = singleTriangle()
        let closed = try PrimitiveMeshBuilder.cube(size: 2)
        let multiple = combine([open, shifted(closed, by: SIMD3<Float>(10, 0, 0))])
        for source in [open, closed, multiple] {
            let sourceReport = MeshTopologyDiagnostics.analyze(source)
            let result = try MeshLinearArray.array(
                mesh: source, transform: .identity,
                options: options(axis: .z, count: 3, spacing: 20))
            XCTAssertEqual(result.estimate.resultingComponentCount, sourceReport.connectedComponentCount * 3)
            XCTAssertEqual(result.estimate.resultingBoundaryEdgeCount, sourceReport.boundaryEdgeCount * 3)
            assertValid(
                result.mesh,
                components: sourceReport.connectedComponentCount * 3,
                boundaryEdges: sourceReport.boundaryEdgeCount * 3)
        }
    }

    func testNormalsAdjacencyWindingAndTriangleAreasRemainValid() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 3)
        let result = try MeshLinearArray.array(
            mesh: source, transform: .identity,
            options: options(axis: .x, count: 4, spacing: 8))
        XCTAssertTrue(result.mesh.hasCachedAdjacency)
        assertValid(result.mesh, components: 4, boundaryEdges: 0)
        for copy in 0..<4 {
            for face in 0..<(source.indices.count / 3) {
                XCTAssertEqual(
                    twiceArea(result.mesh, triangle: copy * source.indices.count / 3 + face),
                    twiceArea(source, triangle: face),
                    accuracy: 0.000_01)
            }
        }
    }

    func testResultAndFingerprintAreDeterministic() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        let requested = options(axis: .z, count: 6, spacing: -3.75)
        let first = try MeshLinearArray.array(mesh: source, transform: .identity, options: requested)
        let second = try MeshLinearArray.array(mesh: source, transform: .identity, options: requested)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
        XCTAssertEqual(first.mesh.vertices, second.mesh.vertices)
        XCTAssertEqual(first.mesh.indices, second.mesh.indices)
    }

    func testPreviewSourceKeyBindsMeshTransformAndOptions() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        let meshVersion = TopologyEditChangeVersion(identity: UUID(), value: 7)
        let transformVersion = TopologyEditChangeVersion(identity: UUID(), value: 9)
        let requested = options(axis: .y, count: 4, spacing: 5)
        let preview = try MeshLinearArray.makePreview(
            mesh: source,
            transform: .identity,
            options: requested,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion)
        XCTAssertTrue(preview.source.matchesRuntimeIdentity(
            mesh: source,
            transform: .identity,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion,
            options: requested))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: source,
            transform: .identity,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion,
            options: options(axis: .y, count: 5, spacing: 5)))
        var vertexEdited = source
        _ = vertexEdited.updatePositions([
            0: vertexEdited.vertices[0].position + SIMD3<Float>(0.01, 0, 0),
        ])
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: vertexEdited,
            transform: .identity,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion,
            options: requested))
        let newTopologyIdentity = EditableMesh(vertices: source.vertices, indices: source.indices)
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: newTopologyIdentity,
            transform: .identity,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion,
            options: requested))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: source,
            transform: .identity,
            meshChangeVersion: meshVersion,
            transformChangeVersion: TopologyEditChangeVersion(identity: UUID(), value: 9),
            options: requested))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: source,
            transform: ObjectTransform(translation: SIMD3<Float>(1, 2, 3)),
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion,
            options: requested))
        XCTAssertEqual(preview.source.sourceComponentCount, 1)
        XCTAssertEqual(preview.source.resultingTriangleCount, source.indices.count / 3 * 4)
    }

    func testSourceValidationRejectsKnownDefectsAndAllowsOpenBoundary() throws {
        XCTAssertNoThrow(try MeshLinearArray.estimate(
            mesh: singleTriangle(), transform: .identity, options: options()))
        let cases: [(EditableMesh, MeshLinearArrayError)] = [
            (EditableMesh(vertices: [], indices: []), .invalidMesh),
            (mesh([.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0)], [0, 1, 2]), .degenerateTriangle),
            (mesh([.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)], [0, 1, 2, 0, 1, 2]), .duplicateTriangle),
            (mesh([.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, -1, 0)], [0, 1, 2, 1, 0, 3, 0, 1, 4]), .nonManifoldEdge),
            (mesh([.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0)], [0, 1, 2, 0, 1, 3]), .windingConflict),
            (mesh([.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(5, 5, 5)], [0, 1, 2]), .isolatedVertex),
        ]
        for (candidate, expected) in cases {
            XCTAssertThrowsError(try MeshLinearArray.estimate(
                mesh: candidate, transform: .identity, options: options())) {
                XCTAssertEqual($0 as? MeshLinearArrayError, expected)
            }
        }
    }

    func testNonFiniteSourceAndTransformAreRejected() throws {
        var vertices = singleTriangle().vertices
        vertices[0].position.x = .nan
        XCTAssertThrowsError(try MeshLinearArray.estimate(
            mesh: EditableMesh(vertices: vertices, indices: [0, 1, 2]),
            transform: .identity, options: options())) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .nonFiniteValue)
        }
        var transform = ObjectTransform.identity
        transform.translation.x = .infinity
        XCTAssertThrowsError(try MeshLinearArray.estimate(
            mesh: singleTriangle(), transform: transform, options: options())) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .nonFiniteValue)
        }
    }

    func testGeometricDuplicateSourceAndGeneratedCopyAreRejected() throws {
        let geometricDuplicate = mesh([
            .zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
            .zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
        ], [0, 1, 2, 3, 4, 5])
        XCTAssertThrowsError(try MeshLinearArray.estimate(
            mesh: geometricDuplicate, transform: .identity, options: options())) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .duplicateTriangle)
        }

        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        let periodic = combine([cube, shifted(cube, by: SIMD3<Float>(10, 0, 0))])
        XCTAssertThrowsError(try MeshLinearArray.array(
            mesh: periodic, transform: .identity,
            options: options(axis: .x, count: 2, spacing: 10))) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .copyWouldCreateDuplicateGeometry)
        }
    }

    func testSharedGeometricDuplicateHelperHandlesInvalidWindingAndSignedZero() {
        XCTAssertNil(MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(
            EditableMesh(vertices: [], indices: [])))
        XCTAssertNil(MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(
            mesh([.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)], [0, 1, 9])))
        XCTAssertEqual(
            MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(singleTriangle()),
            false)

        let sameIndices = mesh([
            .zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
        ], [0, 1, 2, 0, 1, 2])
        XCTAssertEqual(MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(sameIndices), true)

        let oppositeWinding = mesh([
            .zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
            .zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
        ], [0, 1, 2, 5, 4, 3])
        XCTAssertEqual(MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(oppositeWinding), true)

        let negativeZero = Float(bitPattern: 0x8000_0000)
        let signedZero = mesh([
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(negativeZero, 0, 0), SIMD3<Float>(1, negativeZero, 0),
            SIMD3<Float>(negativeZero, 1, 0),
        ], [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(signedZero), true)
    }

    func testMinimumSpacingWorksAtNormalCoordinatesAndFailsAtHugeTranslation() throws {
        XCTAssertNoThrow(try MeshLinearArray.array(
            mesh: singleTriangle(), transform: .identity,
            options: options(count: 2, spacing: 0.001)))
        let huge = ObjectTransform(translation: SIMD3<Float>(100_000_000, 0, 0))
        XCTAssertThrowsError(try MeshLinearArray.estimate(
            mesh: singleTriangle(), transform: huge,
            options: options(count: 2, spacing: 0.001))) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .spacingRoundTripFailure)
        }
    }

    func testBoundsFollowAxisDirectionAndStoredFloatPositions() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        for axis in LinearArrayAxis.allCases {
            for spacing in [6.0, -6.0] {
                let result = try MeshLinearArray.array(
                    mesh: source, transform: ObjectTransform(
                        translation: SIMD3<Float>(30, -20, 10),
                        rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(15, 25, 35)),
                        scale: SIMD3<Float>(2, 0.5, 4)),
                    options: options(axis: axis, count: 3, spacing: spacing))
                XCTAssertEqual(result.estimate.resultLocalBounds, result.mesh.bounds)
                XCTAssertTrue(result.estimate.sourceWorldBounds.isFinite)
                XCTAssertTrue(result.estimate.resultWorldBounds.isFinite)
                XCTAssertEqual(result.estimate.totalSpanMillimeters, spacing * 2)
            }
        }
    }

    func testWorkingMemoryArithmeticAndLimitsAreCheckedBeforeAllocation() throws {
        XCTAssertThrowsError(try MeshLinearArray.estimatedWorkingBytes(
            sourceVertices: .max,
            sourceTriangles: 1,
            uniqueEdges: 1,
            resultingVertices: 1,
            resultingTriangles: 1)) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .arithmeticOverflow)
        }
        let source = singleTriangle()
        XCTAssertThrowsError(try MeshLinearArray.estimate(
            mesh: source, transform: .identity,
            options: options(count: Int.max, spacing: 1))) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .invalidCount)
        }
    }

    @MainActor
    func testRepresentativePreviewValidationFailuresAreAtomic() throws {
        let invalidCount = WorkspaceModel()
        invalidCount.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try invalidCount.prepareForMeshLinearArray()
        try assertPreviewFailureAtomic(
            invalidCount, options: options(count: 1, spacing: 10), expected: .invalidCount)

        let invalidSpacing = WorkspaceModel()
        invalidSpacing.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try invalidSpacing.prepareForMeshLinearArray()
        try assertPreviewFailureAtomic(
            invalidSpacing, options: options(count: 2, spacing: 0), expected: .invalidSpacing)

        let precision = WorkspaceModel()
        precision.mesh = singleTriangle()
        precision.updateTransform(ObjectTransform(translation: SIMD3<Float>(100_000_000, 0, 0)))
        try precision.prepareForMeshLinearArray()
        try assertPreviewFailureAtomic(
            precision, options: options(count: 2, spacing: 0.001), expected: .spacingRoundTripFailure)

        let duplicate = WorkspaceModel()
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        duplicate.mesh = combine([cube, shifted(cube, by: SIMD3<Float>(10, 0, 0))])
        try duplicate.prepareForMeshLinearArray()
        try assertPreviewFailureAtomic(
            duplicate,
            options: options(axis: .x, count: 2, spacing: 10),
            expected: .copyWouldCreateDuplicateGeometry)
    }

    @MainActor
    func testWorkspaceApplyIsOneCommandAndPreservesNonTopologyState() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let transform = ObjectTransform(
            translation: SIMD3<Float>(4, -2, 8),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 20, 30)),
            scale: SIMD3<Float>(2, 3, 4))
        model.updateTransform(transform)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.toggle)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        model.brush = .crease
        model.symmetry = SculptSymmetry(x: true, y: false, z: true)
        let camera = model.camera
        let undoCount = model.undoCount
        try model.prepareForMeshLinearArray()
        let preview = try model.previewMeshLinearArray(
            options: options(axis: .y, count: 3, spacing: 12))
        let result = try model.applyMeshLinearArray(preview: preview)
        XCTAssertEqual(model.undoCount, undoCount + 1)
        XCTAssertEqual(model.objectTransform, transform.sanitized())
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.interactionMode, .faceSelect)
        XCTAssertEqual(model.faceSelectionOperation, .toggle)
        XCTAssertEqual(model.brush, .crease)
        XCTAssertEqual(model.symmetry, SculptSymmetry(x: true, y: false, z: true))
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertTrue(model.pickingCacheHasIndexForTesting)
        XCTAssertFalse(model.isMeshLinearArraySnapshotSafeForTesting)
    }

    @MainActor
    func testUndoRedoRestoreSourceAndResultWithoutSelectionOrPreview() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let source = model.mesh
        try model.prepareForMeshLinearArray()
        let preview = try model.previewMeshLinearArray(options: options(count: 3, spacing: 5))
        let result = try model.applyMeshLinearArray(preview: preview).mesh
        model.undo()
        XCTAssertEqual(model.mesh, source)
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertEqual(model.selectedFaceCount, 0)
        model.redo()
        XCTAssertEqual(model.mesh, result)
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertEqual(model.selectedFaceCount, 0)
    }

    @MainActor
    func testFailedBVHPreparationLeavesWorkspaceHistoryAndProjectBytesAtomic() throws {
        let cache = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        let model = WorkspaceModel(pickingCache: cache)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        let preview = try model.previewMeshLinearArray(options: options())
        let source = model.mesh
        let transform = model.objectTransform
        let camera = model.camera
        let selection = model.faceSelection
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        XCTAssertThrowsError(try model.applyMeshLinearArray(preview: preview))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertFalse(model.isMeshLinearArraySnapshotSafeForTesting)
    }

    @MainActor
    func testPreviewStalesForMeshTransformAndParameterChanges() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        let requested = options(axis: .x, count: 3, spacing: 5)
        let preview = try model.previewMeshLinearArray(options: requested)
        let originalTransform = model.objectTransform
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3)))
        model.updateTransform(originalTransform)
        XCTAssertTrue(model.isMeshLinearArrayPreviewStale)
        XCTAssertThrowsError(try model.applyMeshLinearArray(preview: preview)) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .stalePreview)
        }
        try model.prepareForMeshLinearArray()
        let current = try model.previewMeshLinearArray(options: requested)
        for changed in [
            options(axis: .y, count: 3, spacing: 5),
            options(axis: .x, count: 4, spacing: 5),
            options(axis: .x, count: 3, spacing: -5),
        ] {
            XCTAssertFalse(current.source.matchesRuntimeIdentity(
                mesh: model.mesh,
                transform: model.objectTransform,
                meshChangeVersion: current.source.meshChangeVersion,
                transformChangeVersion: current.source.transformChangeVersion,
                options: changed))
        }
        _ = model.mesh.updatePositions([0: model.mesh.vertices[0].position + SIMD3<Float>(0.01, 0, 0)])
        XCTAssertTrue(model.isMeshLinearArrayPreviewStale)
    }

    @MainActor
    func testPreparedPhaseRejectsEstimateAndFingerprintMismatchAtomically() throws {
        for mismatch in [PreviewMismatch.estimate, .fingerprint] {
            let model = WorkspaceModel()
            model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
            try model.prepareForMeshLinearArray()
            let requestID = UUID()
            try model.beginMeshLinearArrayPreviewRequest(requestID)
            let candidate = try model.makeMeshLinearArrayPreviewCandidate(
                options: options(axis: .z, count: 3, spacing: 7),
                requestID: requestID)
            let mismatched = mismatch == .estimate
                ? replacingEstimate(candidate)
                : replacingFingerprint(candidate)
            XCTAssertTrue(model.completeMeshLinearArrayPreviewRequest(
                requestID: requestID,
                candidate: mismatched))

            let source = model.mesh
            let transform = model.objectTransform
            let camera = model.camera
            let selection = model.faceSelection
            let history = (model.undoCount, model.redoCount)
            let generation = model.projectMutationGeneration
            let bytes = try model.projectData()
            XCTAssertThrowsError(try model.applyMeshLinearArray(preview: mismatched)) {
                XCTAssertEqual($0 as? MeshLinearArrayError, .stalePreview)
            }
            XCTAssertEqual(model.mesh, source)
            XCTAssertEqual(model.objectTransform, transform)
            XCTAssertEqual(model.camera, camera)
            XCTAssertEqual(model.faceSelection, selection)
            XCTAssertEqual(model.undoCount, history.0)
            XCTAssertEqual(model.redoCount, history.1)
            XCTAssertEqual(model.projectMutationGeneration, generation)
            XCTAssertEqual(try model.projectData(), bytes)
            XCTAssertNil(model.meshLinearArrayPreview)
            XCTAssertFalse(model.isMeshLinearArrayRunning)
        }
    }

    @MainActor
    func testCameraToolsSelectionAndDiagnosticsDoNotStalePreview() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        try model.prepareForMeshLinearArray()
        let preview = try model.previewMeshLinearArray(options: options())
        model.camera = CameraState(yaw: 0.7, pitch: -0.2, distance: 40, target: SIMD3<Float>(1, 2, 3))
        model.brush = .crease
        model.symmetry = SculptSymmetry(x: true, y: true, z: false)
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        XCTAssertTrue(model.isMeshLinearArrayPreviewCurrent(preview))
    }

    @MainActor
    func testFailedRecalculationCancelAndFailureDoNotMutateProject() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let source = model.mesh
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        try model.prepareForMeshLinearArray()
        let original = try model.previewMeshLinearArray(options: options())
        XCTAssertThrowsError(try model.previewMeshLinearArray(options: options(spacing: 0)))
        XCTAssertNil(model.meshLinearArrayPreview)
        XCTAssertFalse(model.isMeshLinearArrayPreviewCurrent(original))
        model.discardMeshLinearArrayPreview()
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
    }

    @MainActor
    func testApplyAfterOptionsChangeAndDoubleApplyAreAtomic() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        let previewA = try model.previewMeshLinearArray(
            options: options(axis: .x, count: 2, spacing: 10))
        let previewB = try model.previewMeshLinearArray(
            options: options(axis: .y, count: 3, spacing: 5))
        let source = model.mesh
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        XCTAssertThrowsError(try model.applyMeshLinearArray(preview: previewA)) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .stalePreview)
        }
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertEqual(model.meshLinearArrayPreview, previewB)
        XCTAssertFalse(model.isMeshLinearArrayRunning)

        _ = try model.applyMeshLinearArray(preview: previewB)
        let appliedMesh = model.mesh
        let appliedHistory = (model.undoCount, model.redoCount)
        let appliedGeneration = model.projectMutationGeneration
        let appliedBytes = try model.projectData()
        XCTAssertThrowsError(try model.applyMeshLinearArray(preview: previewB)) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .stalePreview)
        }
        XCTAssertEqual(model.mesh, appliedMesh)
        XCTAssertEqual(model.undoCount, appliedHistory.0)
        XCTAssertEqual(model.redoCount, appliedHistory.1)
        XCTAssertEqual(model.projectMutationGeneration, appliedGeneration)
        XCTAssertEqual(try model.projectData(), appliedBytes)
        XCTAssertFalse(model.isMeshLinearArrayRunning)
    }

    @MainActor
    func testApplyUndoRedoAutosaveOrderingUsesOnlyCompletedMeshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshLinearArrayAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: MeshLinearArrayImmediateScheduler(),
            debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        let before = model.mesh
        var generation = model.projectMutationGeneration
        try model.prepareForMeshLinearArray()
        let stalePreview = try model.previewMeshLinearArray(options: options(axis: .x))
        let preview = try model.previewMeshLinearArray(options: options(axis: .y))
        XCTAssertThrowsError(try model.applyMeshLinearArray(preview: stalePreview)) {
            XCTAssertEqual($0 as? MeshLinearArrayError, .stalePreview)
        }
        let previewWriteCount = await coordinator.successfulWriteCount
        XCTAssertEqual(previewWriteCount, 0)
        let after = try model.applyMeshLinearArray(preview: preview).mesh
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
        let finalWriteCount = await coordinator.successfulWriteCount
        XCTAssertEqual(finalWriteCount, 3)
        XCTAssertFalse(model.isMeshLinearArraySnapshotSafeForTesting)
    }

    @MainActor
    func testPersistenceAndSTLExportContainOnlyOrdinaryResultMesh() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        try model.prepareForMeshLinearArray()
        let preview = try model.previewMeshLinearArray(options: options(axis: .z, count: 3, spacing: 5))
        _ = try model.applyMeshLinearArray(preview: preview)
        let meshBefore = model.mesh
        let runtimeBefore = model.mesh.runtime
        let historyBefore = (model.undoCount, model.redoCount)
        let project = try model.projectData()
        let text = String(decoding: project, as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\":1"))
        XCTAssertFalse(text.contains("meshLinearArray"))
        XCTAssertFalse(text.contains("spacingMillimeters"))
        let decoded = try ProjectCodec.decode(project)
        XCTAssertEqual(decoded.mesh, meshBefore)
        try model.prepareForSTLExport()
        let stl = try model.stlData()
        XCTAssertEqual(stl.count, 84 + model.mesh.indices.count / 3 * 50)
        XCTAssertEqual(model.mesh, meshBefore)
        XCTAssertEqual(model.mesh.runtime, runtimeBefore)
        XCTAssertEqual(model.undoCount, historyBefore.0)
        XCTAssertEqual(model.redoCount, historyBefore.1)
    }

    @MainActor
    func testSuccessfulInstallUploadsFreshTopologyOnceThenSkipsUnchangedFrame() throws {
        #if targetEnvironment(simulator)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        renderer.update(mesh: model.mesh)
        profiler.reset(vertexCount: model.mesh.vertices.count, triangleCount: model.mesh.indices.count / 3)
        try model.prepareForMeshLinearArray()
        let preview = try model.previewMeshLinearArray(options: options())
        _ = try model.applyMeshLinearArray(preview: preview)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        #endif
    }

    @MainActor
    func testSheetFitsCompactWidthsAndLargeDynamicType() throws {
        let model = WorkspaceModel()
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        for width in [CGFloat(320), 744, 1_024] {
            let sheet = UIHostingController(rootView: MeshLinearArrayView(model: model)
                .environment(\.dynamicTypeSize, .accessibility3))
            let size = sheet.sizeThatFits(in: CGSize(width: width, height: 2_000))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertLessThanOrEqual(size.width, width + 1)
        }
    }

    func testSheetExplainsCountWorldSpacingPrecisionCollisionAndUndo() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("src/UI/MeshLinearArrayView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("Count includes the unchanged source mesh as copy 0."))
        XCTAssertTrue(source.contains("world-space millimeters"))
        XCTAssertTrue(source.contains("Copies remain detached"))
        XCTAssertTrue(source.contains("collision detection"))
        XCTAssertTrue(source.contains("one Undo command"))
        XCTAssertTrue(source.contains("accessibilityLabel"))
        XCTAssertTrue(source.contains("MeshLinearArrayPreviewRequestCoordinator"))
        XCTAssertTrue(source.contains("beginMeshLinearArrayPreviewRequest"))
        XCTAssertTrue(source.contains("onDisappear { invalidatePreviewRequest() }"))
        XCTAssertTrue(source.contains("defer { isApplying = false }"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: ".disabled(isBusy)").count - 1,
            4)
    }

    private enum PreviewMismatch: Equatable { case estimate, fingerprint }

    @MainActor
    private func assertPreviewFailureAtomic(
        _ model: WorkspaceModel,
        options: MeshLinearArrayOptions,
        expected: MeshLinearArrayError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let mesh = model.mesh
        let transform = model.objectTransform
        let camera = model.camera
        let selection = model.faceSelection
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        XCTAssertThrowsError(try model.previewMeshLinearArray(options: options), file: file, line: line) {
            XCTAssertEqual($0 as? MeshLinearArrayError, expected, file: file, line: line)
        }
        XCTAssertEqual(model.mesh, mesh, file: file, line: line)
        XCTAssertEqual(model.objectTransform, transform, file: file, line: line)
        XCTAssertEqual(model.camera, camera, file: file, line: line)
        XCTAssertEqual(model.faceSelection, selection, file: file, line: line)
        XCTAssertEqual(model.undoCount, history.0, file: file, line: line)
        XCTAssertEqual(model.redoCount, history.1, file: file, line: line)
        XCTAssertEqual(model.projectMutationGeneration, generation, file: file, line: line)
        XCTAssertEqual(try model.projectData(), bytes, file: file, line: line)
        XCTAssertNil(model.meshLinearArrayPreview, file: file, line: line)
        XCTAssertFalse(model.isMeshLinearArrayRunning, file: file, line: line)
    }

    private func replacingEstimate(_ preview: MeshLinearArrayPreview) -> MeshLinearArrayPreview {
        let estimate = preview.estimate
        return MeshLinearArrayPreview(
            options: preview.options,
            estimate: MeshLinearArrayEstimate(
                axis: estimate.axis,
                count: estimate.count,
                spacingMillimeters: estimate.spacingMillimeters,
                totalSpanMillimeters: estimate.totalSpanMillimeters,
                originalVertexCount: estimate.originalVertexCount,
                resultingVertexCount: estimate.resultingVertexCount,
                originalTriangleCount: estimate.originalTriangleCount,
                resultingTriangleCount: estimate.resultingTriangleCount,
                sourceComponentCount: estimate.sourceComponentCount,
                resultingComponentCount: estimate.resultingComponentCount,
                sourceBoundaryEdgeCount: estimate.sourceBoundaryEdgeCount,
                resultingBoundaryEdgeCount: estimate.resultingBoundaryEdgeCount,
                sourceLocalBounds: estimate.sourceLocalBounds,
                resultLocalBounds: estimate.resultLocalBounds,
                sourceWorldBounds: estimate.sourceWorldBounds,
                resultWorldBounds: estimate.resultWorldBounds,
                actualSpacingToleranceMillimeters: estimate.actualSpacingToleranceMillimeters,
                estimatedWorkingByteCount: estimate.estimatedWorkingByteCount + 1),
            source: preview.source)
    }

    private func replacingFingerprint(_ preview: MeshLinearArrayPreview) -> MeshLinearArrayPreview {
        let source = preview.source
        return MeshLinearArrayPreview(
            options: preview.options,
            estimate: preview.estimate,
            source: MeshLinearArraySourceKey(
                topologyID: source.topologyID,
                topologyRevision: source.topologyRevision,
                vertexRevision: source.vertexRevision,
                meshChangeVersion: source.meshChangeVersion,
                transformChangeVersion: source.transformChangeVersion,
                transform: source.transform,
                options: source.options,
                sourceVertexCount: source.sourceVertexCount,
                sourceTriangleCount: source.sourceTriangleCount,
                sourceComponentCount: source.sourceComponentCount,
                sourceBoundaryEdgeCount: source.sourceBoundaryEdgeCount,
                resultingVertexCount: source.resultingVertexCount,
                resultingTriangleCount: source.resultingTriangleCount,
                totalSpanMillimeters: source.totalSpanMillimeters,
                analysisFingerprint: source.analysisFingerprint ^ 1))
    }

    private func options(
        axis: LinearArrayAxis = .x,
        count: Int = 2,
        spacing: Double = 10
    ) -> MeshLinearArrayOptions {
        MeshLinearArrayOptions(axis: axis, count: count, spacingMillimeters: spacing)
    }

    private func singleTriangle() -> EditableMesh {
        mesh([
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
        ], [0, 1, 2])
    }

    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var result = EditableMesh(
            vertices: positions.map { MeshVertex(position: $0, normal: SIMD3<Float>(0, 0, 1)) },
            indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        return result
    }

    private func shifted(_ source: EditableMesh, by offset: SIMD3<Float>) -> EditableMesh {
        let vertices = source.vertices.map {
            MeshVertex(position: $0.position + offset, normal: $0.normal)
        }
        var result = EditableMesh(vertices: vertices, indices: source.indices)
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

    private func assertWorldSpacing(
        _ result: EditableMesh,
        source: EditableMesh,
        transform: ObjectTransform,
        options: MeshLinearArrayOptions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let direction = transform.worldDirection(fromLocal: SIMD3<Float>(
            options.axis == .x ? 1 : 0,
            options.axis == .y ? 1 : 0,
            options.axis == .z ? 1 : 0))
        for copy in 0..<(options.count - 1) {
            for sourceID in source.vertices.indices {
                let first = transform.worldPosition(fromLocal: result.meshPosition(copy: copy, sourceID: sourceID, sourceCount: source.vertices.count))
                let second = transform.worldPosition(fromLocal: result.meshPosition(copy: copy + 1, sourceID: sourceID, sourceCount: source.vertices.count))
                let delta = second - first
                let projection = simd_dot(delta, direction)
                let perpendicular = delta - direction * projection
                XCTAssertEqual(Double(projection), options.spacingMillimeters, accuracy: max(abs(options.spacingMillimeters) * 0.01, 0.000_01), file: file, line: line)
                XCTAssertEqual(Double(simd_length(delta)), abs(options.spacingMillimeters), accuracy: max(abs(options.spacingMillimeters) * 0.01, 0.000_01), file: file, line: line)
                XCTAssertLessThanOrEqual(Double(simd_length(perpendicular)), max(abs(options.spacingMillimeters) * 0.01, 0.000_01), file: file, line: line)
            }
        }
    }

    private func assertValid(
        _ mesh: EditableMesh,
        components: Int,
        boundaryEdges: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let report = MeshTopologyDiagnostics.analyze(mesh)
        XCTAssertEqual(report.connectedComponentCount, components, file: file, line: line)
        XCTAssertEqual(report.boundaryEdgeCount, boundaryEdges, file: file, line: line)
        XCTAssertEqual(report.nonManifoldEdgeCount, 0, file: file, line: line)
        XCTAssertEqual(report.inconsistentWindingEdgeCount, 0, file: file, line: line)
        XCTAssertEqual(report.degenerateTriangleCount, 0, file: file, line: line)
        XCTAssertEqual(report.duplicateTriangleCount, 0, file: file, line: line)
        XCTAssertEqual(report.isolatedVertexCount, 0, file: file, line: line)
        XCTAssertTrue(mesh.vertices.allSatisfy {
            $0.position.allFinite && $0.normal.allFinite && abs(simd_length($0.normal) - 1) <= 0.001
        }, file: file, line: line)
    }

    private func twiceArea(_ mesh: EditableMesh, triangle: Int) -> Double {
        let offset = triangle * 3
        return DiagnosticMath.twiceArea(
            mesh.vertices[Int(mesh.indices[offset])].position,
            mesh.vertices[Int(mesh.indices[offset + 1])].position,
            mesh.vertices[Int(mesh.indices[offset + 2])].position)
    }

    private func worldBounds(_ mesh: EditableMesh, _ transform: ObjectTransform) -> AxisAlignedBoundingBox {
        var result = AxisAlignedBoundingBox()
        for vertex in mesh.vertices { result.include(transform.worldPosition(fromLocal: vertex.position)) }
        return result
    }

    private func assertBoundsApproximatelyEqual(
        _ lhs: AxisAlignedBoundingBox,
        _ rhs: AxisAlignedBoundingBox,
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for axis in 0..<3 {
            XCTAssertEqual(lhs.minimum[axis], rhs.minimum[axis], accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(lhs.maximum[axis], rhs.maximum[axis], accuracy: accuracy, file: file, line: line)
        }
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

private extension EditableMesh {
    func meshPosition(copy: Int, sourceID: Int, sourceCount: Int) -> SIMD3<Float> {
        vertices[copy * sourceCount + sourceID].position
    }
}

private struct MeshLinearArrayImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
