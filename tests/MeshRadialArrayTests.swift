import MetalKit
import SwiftUI
import XCTest
import simd
@testable import Forge3D

final class MeshRadialArrayTests: XCTestCase {
    func testDefaultsLimitsAndAngleConventions() throws {
        let defaults = MeshRadialArrayOptions()
        XCTAssertEqual(defaults.axis, .z)
        XCTAssertEqual(defaults.distribution, .fullCircle)
        XCTAssertEqual(defaults.count, 6)
        XCTAssertEqual(defaults.direction, .positive)
        XCTAssertEqual(defaults.effectiveSweepDegrees, 360)
        XCTAssertEqual(defaults.stepDegrees, 60)
        XCTAssertEqual(MeshRadialArray.minimumCount, 2)
        XCTAssertEqual(MeshRadialArray.maximumCount, 256)
        XCTAssertEqual(MeshRadialArray.minimumSweepDegrees, 0.01)
        XCTAssertEqual(MeshRadialArray.maximumSweepDegrees, 359.99)
        XCTAssertEqual(MeshRadialArray.maximumVertices, 2_000_000)
        XCTAssertEqual(MeshRadialArray.maximumTriangles, 4_000_000)
        XCTAssertEqual(MeshRadialArray.maximumWorkingBytes, 768 * 1_024 * 1_024)

        XCTAssertEqual(
            try MeshRadialArray.anglesDegrees(for: options(count: 4)),
            [0, 90, 180, 270])
        XCTAssertEqual(
            try MeshRadialArray.anglesDegrees(for: options(count: 4, direction: .negative)),
            [0, -90, -180, -270])
    }

    func testOpenArcIncludesBothEndpointsAndSweepSignControlsDirection() throws {
        let positive = options(distribution: .openArc, count: 4, sweep: 120)
        let negative = options(distribution: .openArc, count: 4, direction: .negative, sweep: -120)
        XCTAssertEqual(try MeshRadialArray.anglesDegrees(for: positive), [0, 40, 80, 120])
        XCTAssertEqual(try MeshRadialArray.anglesDegrees(for: negative), [0, -40, -80, -120])
        XCTAssertEqual(positive.stepDegrees, 40)
        XCTAssertEqual(negative.stepDegrees, -40)
    }

    func testCountAndSweepBoundariesRejectInvalidValues() throws {
        let source = offAxisTriangle()
        for count in [2, 3, 256] {
            XCTAssertNoThrow(try MeshRadialArray.estimate(
                mesh: source, transform: .identity,
                options: options(distribution: .openArc, count: count, sweep: 0.01)))
        }
        for sweep in [0.01, -0.01, 359.99, -359.99] {
            XCTAssertNoThrow(try MeshRadialArray.estimate(
                mesh: source, transform: .identity,
                options: options(distribution: .openArc, sweep: sweep)))
        }
        for count in [Int.min, -1, 0, 1, 257, Int.max] {
            XCTAssertThrowsError(try MeshRadialArray.estimate(
                mesh: source, transform: .identity,
                options: options(count: count))) {
                XCTAssertEqual($0 as? MeshRadialArrayError, .invalidCount)
            }
        }
        for sweep in [0, 0.009, -0.009, 360, -360, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try MeshRadialArray.estimate(
                mesh: source, transform: .identity,
                options: options(distribution: .openArc, sweep: sweep))) {
                XCTAssertEqual($0 as? MeshRadialArrayError, .invalidSweep)
            }
        }
    }

    func testLocalAxesRotateAroundLocalOriginForFullAndOpenDistributions() throws {
        let source = offAllAxesTriangle()
        for axis in LinearArrayAxis.allCases {
            for requested in [
                options(axis: axis, count: 3),
                options(axis: axis, distribution: .openArc, count: 3, sweep: -135),
            ] {
                let result = try MeshRadialArray.array(
                    mesh: source, transform: .identity, options: requested)
                assertWorldRigidRotation(
                    result.mesh, source: source, transform: .identity, options: requested)
                assertValid(
                    result.mesh,
                    components: requested.count,
                    boundaryEdges: 3 * requested.count)
            }
        }
    }

    func testWorldRigidRotationSurvivesTransformCombinations() throws {
        let source = offAllAxesTriangle()
        let transforms = [
            ObjectTransform(translation: SIMD3<Float>(14, -9, 3)),
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, -35, 70))),
            ObjectTransform(scale: SIMD3<Float>(2, 2, 2)),
            ObjectTransform(scale: SIMD3<Float>(0.25, 3, 7)),
            ObjectTransform(
                translation: SIMD3<Float>(800, -500, 250),
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(25, 40, -15)),
                scale: SIMD3<Float>(0.2, 4, 1.5)),
        ]
        for transform in transforms {
            let requested = options(
                axis: .y, distribution: .openArc, count: 5, sweep: 217.5)
            let result = try MeshRadialArray.array(
                mesh: source, transform: transform, options: requested)
            assertWorldRigidRotation(
                result.mesh, source: source, transform: transform, options: requested,
                accuracy: 0.005)
            XCTAssertEqual(result.estimate.resultWorldBounds, worldBounds(result.mesh, transform))
        }
    }

    func testCanonicalOptionsIgnoreInactiveControlsAndRemainStableAcrossModeRoundTrip() throws {
        let source = offAllAxesTriangle()
        let fullA = options(count: 5, direction: .negative, sweep: 12)
        let fullB = options(count: 5, direction: .negative, sweep: 321)
        let fullResultA = try MeshRadialArray.array(
            mesh: source, transform: .identity, options: fullA)
        let fullResultB = try MeshRadialArray.array(
            mesh: source, transform: .identity, options: fullB)
        XCTAssertEqual(fullA.canonicalized, fullB.canonicalized)
        XCTAssertEqual(fullResultA, fullResultB)
        let meshVersion = TopologyEditChangeVersion(
            identity: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            value: 7)
        let transformVersion = TopologyEditChangeVersion(
            identity: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
            value: 9)
        let fullPreviewA = try MeshRadialArray.makePreview(
            mesh: source,
            transform: .identity,
            options: fullA,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion)
        let fullPreviewB = try MeshRadialArray.makePreview(
            mesh: source,
            transform: .identity,
            options: fullB,
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion)
        XCTAssertEqual(fullPreviewA, fullPreviewB)

        let openA = options(
            distribution: .openArc, count: 5, direction: .positive, sweep: -120)
        let openB = options(
            distribution: .openArc, count: 5, direction: .negative, sweep: -120)
        let openResultA = try MeshRadialArray.array(
            mesh: source, transform: .identity, options: openA)
        let openResultB = try MeshRadialArray.array(
            mesh: source, transform: .identity, options: openB)
        XCTAssertEqual(openA.canonicalized, openB.canonicalized)
        XCTAssertEqual(openResultA, openResultB)
        XCTAssertEqual(
            try MeshRadialArray.makePreview(
                mesh: source,
                transform: .identity,
                options: openA,
                meshChangeVersion: meshVersion,
                transformChangeVersion: transformVersion),
            try MeshRadialArray.makePreview(
                mesh: source,
                transform: .identity,
                options: openB,
                meshChangeVersion: meshVersion,
                transformChangeVersion: transformVersion))
        XCTAssertNotEqual(fullResultA.analysisFingerprint, openResultA.analysisFingerprint)
        XCTAssertEqual(fullA.canonicalized, fullB.canonicalized.canonicalized)
    }

    func testEstimateReportsPivotAxisVertexClassesAndMixedRadiusRange() throws {
        let source = mesh([
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0.000_1, 0, 0),
            SIMD3<Float>(1_000, 10, 0),
        ], [0, 1, 2])
        let estimate = try MeshRadialArray.estimate(
            mesh: source,
            transform: .identity,
            options: options(axis: .z, distribution: .openArc, count: 3, sweep: 90))
        XCTAssertEqual(estimate.pivotWorld, .zero)
        XCTAssertEqual(estimate.axisWorld, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(estimate.axisVertexCount, 1)
        XCTAssertEqual(estimate.offAxisVertexCount, 2)
        XCTAssertEqual(
            estimate.minimumPositiveSourceRadiusMillimeters,
            0.000_1,
            accuracy: 0.000_000_01)
        XCTAssertEqual(
            estimate.maximumSourceRadiusMillimeters,
            hypot(1_000.0, 10.0),
            accuracy: 0.001)
        XCTAssertGreaterThan(estimate.minimumFeatureChordMillimeters, 0)
        XCTAssertGreaterThan(estimate.axisClassificationToleranceMillimeters, 0)
        XCTAssertGreaterThan(estimate.radialToleranceMillimeters, 0)
        XCTAssertGreaterThan(estimate.axialToleranceMillimeters, 0)
        XCTAssertGreaterThan(estimate.maximumAngularToleranceDegrees, 0)
    }

    func testRenderSpaceFloatPathAcceptsRepresentableAndRejectsCollapsedHugeTranslations() throws {
        let source = offAllAxesTriangle()
        for translation in [Float(100_000), Float(1_000_000)] {
            let transform = ObjectTransform(
                translation: SIMD3<Float>(repeating: translation))
            XCTAssertNoThrow(try MeshRadialArray.array(
                mesh: source,
                transform: transform,
                options: options(axis: .z, count: 3)))
        }

        for translation in [Float(16_777_216), Float(100_000_000)] {
            let transform = ObjectTransform(
                translation: SIMD3<Float>(repeating: translation))
            let rendered = source.vertices.map {
                transform.worldPosition(fromLocal: $0.position)
            }
            XCTAssertLessThan(Set(rendered).count, rendered.count)
            XCTAssertThrowsError(try MeshRadialArray.estimate(
                mesh: source,
                transform: transform,
                options: options(axis: .z, count: 3))) {
                guard let error = $0 as? MeshRadialArrayError else {
                    return XCTFail("Expected MeshRadialArrayError")
                }
                XCTAssertTrue([
                    MeshRadialArrayError.renderSpacePrecisionFailure,
                    .copyWouldCollapseTriangle,
                ].contains(error))
            }
        }
    }

    func testTinyOffAxisFeaturesAreNeverClassifiedAsAxisByLargeOuterRadius() throws {
        for radius in [Float(0.000_1), Float(0.001), Float(0.01)] {
            let source = mesh([
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(radius, 0, 0),
                SIMD3<Float>(1_000, 10, 0),
            ], [0, 1, 2])
            let result = try MeshRadialArray.array(
                mesh: source,
                transform: .identity,
                options: options(axis: .z, count: 3))
            XCTAssertEqual(result.estimate.axisVertexCount, 1)
            XCTAssertEqual(result.estimate.offAxisVertexCount, 2)
            XCTAssertEqual(
                result.estimate.minimumPositiveSourceRadiusMillimeters,
                Double(radius),
                accuracy: max(Double(radius) * 0.000_1, 1.0e-9))
            let firstCopy = result.mesh.meshPosition(
                copy: 1, sourceID: 1, sourceCount: source.vertices.count)
            XCTAssertNotEqual(firstCopy, source.vertices[1].position)
        }
    }

    func testMinimumAndNearFullOpenSweepsRemainDistinctInRenderSpace() throws {
        let source = offAllAxesTriangle()
        for sweep in [0.01, -0.01, 359.99, -359.99] {
            for count in [2, 256] {
                let requested = options(
                    axis: .z, distribution: .openArc, count: count, sweep: sweep)
                let result = try MeshRadialArray.array(
                    mesh: source, transform: .identity, options: requested)
                XCTAssertGreaterThan(result.estimate.minimumFeatureChordMillimeters, 0)
                let first = result.mesh.meshPosition(
                    copy: 0, sourceID: 0, sourceCount: source.vertices.count)
                let last = result.mesh.meshPosition(
                    copy: count - 1, sourceID: 0, sourceCount: source.vertices.count)
                XCTAssertNotEqual(first, last)
            }
        }
        for direction in RadialArrayDirection.allCases {
            XCTAssertNoThrow(try MeshRadialArray.array(
                mesh: source,
                transform: .identity,
                options: options(axis: .z, count: 256, direction: direction)))
        }
    }

    func testRenderSpaceValidationSupportsScaleExtremesAndEveryLocalAxis() throws {
        let source = offAllAxesTriangle()
        let transforms = [
            ObjectTransform(
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, -30, 40)),
                scale: SIMD3<Float>(0.001, 0.004, 0.02)),
            ObjectTransform(
                translation: SIMD3<Float>(100_000, -50_000, 25_000),
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(-15, 35, 70)),
                scale: SIMD3<Float>(1_000, 250, 700)),
        ]
        for transform in transforms {
            for axis in LinearArrayAxis.allCases {
                let requested = options(
                    axis: axis, distribution: .openArc, count: 4, sweep: -220)
                let result = try MeshRadialArray.array(
                    mesh: source, transform: transform, options: requested)
                assertWorldRigidRotation(
                    result.mesh,
                    source: source,
                    transform: transform,
                    options: requested,
                    accuracy: max(
                        Float(0.005),
                        Float(result.estimate.validationToleranceMillimeters * 4)))
            }
        }
    }

    @MainActor
    func testRenderSpacePrecisionFailureLeavesWorkspaceAtomic() throws {
        let model = WorkspaceModel()
        model.mesh = offAllAxesTriangle()
        model.updateTranslation(SIMD3<Float>(repeating: 100_000_000))
        let before = WorkspaceState(model)
        try model.prepareForMeshRadialArray()
        XCTAssertThrowsError(try model.previewMeshRadialArray(
            options: options(axis: .z, count: 3))) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .renderSpacePrecisionFailure)
        }
        before.assertUnchanged(model)
        XCTAssertNil(model.meshRadialArrayPreview)
        XCTAssertFalse(model.isMeshRadialArrayRunning)
    }

    func testCopyZeroOrderingAndDirectSourceConstructionAreDeterministic() throws {
        let source = offAllAxesTriangle()
        let requested = options(axis: .x, distribution: .openArc, count: 7, sweep: -270)
        let first = try MeshRadialArray.array(mesh: source, transform: .identity, options: requested)
        let second = try MeshRadialArray.array(mesh: source, transform: .identity, options: requested)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            Array(first.mesh.vertices.prefix(source.vertices.count)).map(\.position),
            source.vertices.map(\.position))
        XCTAssertEqual(Array(first.mesh.indices.prefix(source.indices.count)), source.indices)
        for copy in 0..<requested.count {
            let vertexOffset = copy * source.vertices.count
            let indexOffset = copy * source.indices.count
            for sourceOffset in source.indices.indices {
                XCTAssertEqual(
                    first.mesh.indices[indexOffset + sourceOffset],
                    UInt32(vertexOffset + Int(source.indices[sourceOffset])))
            }
        }
    }

    func testVerticesOnAxisRemainOnAxisWhileOffAxisVerticesRotate() throws {
        let source = mesh([
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(4, 0, 0),
            SIMD3<Float>(0, 3, 1),
        ], [0, 1, 2])
        let requested = options(axis: .z, count: 5)
        let result = try MeshRadialArray.array(mesh: source, transform: .identity, options: requested)
        for copy in 0..<requested.count {
            XCTAssertEqual(result.mesh.meshPosition(copy: copy, sourceID: 0, sourceCount: 3), .zero)
        }
        assertWorldRigidRotation(result.mesh, source: source, transform: .identity, options: requested)
    }

    func testAllVerticesOnAxisUseDedicatedErrorBeforeDegenerateRepairGuidance() {
        let source = mesh([
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 2),
        ], [0, 1, 2], recalculateNormals: false)
        XCTAssertThrowsError(try MeshRadialArray.estimate(
            mesh: source, transform: .identity, options: options(axis: .z))) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .noRadialExtent)
        }
    }

    func testRotationalSymmetryThatCreatesExactDuplicateTrianglesIsRejected() throws {
        let symmetric = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertThrowsError(try MeshRadialArray.array(
            mesh: symmetric, transform: .identity,
            options: options(axis: .z, count: 4))) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .copyWouldCreateDuplicateGeometry)
        }
    }

    func testSourceValidationRejectsRepresentativeUnsafeMeshes() {
        let invalidIndex = mesh(offAllAxesPositions(), [0, 1, 9], recalculateNormals: false)
        let degenerate = mesh([
            SIMD3<Float>(4, 0, 0), SIMD3<Float>(5, 0, 0), SIMD3<Float>(6, 0, 0),
        ], [0, 1, 2], recalculateNormals: false)
        let duplicate = mesh(offAllAxesPositions(), [0, 1, 2, 2, 1, 0])
        let nonManifold = mesh([
            SIMD3<Float>(4, 0, 0), SIMD3<Float>(5, 0, 0),
            SIMD3<Float>(4, 1, 0), SIMD3<Float>(4, -1, 0), SIMD3<Float>(4, 0, 1),
        ], [0, 1, 2, 1, 0, 3, 0, 1, 4])
        let windingConflict = mesh([
            SIMD3<Float>(4, 0, 0), SIMD3<Float>(5, 0, 0),
            SIMD3<Float>(4, 1, 0), SIMD3<Float>(4, 0, 1),
        ], [0, 1, 2, 0, 1, 3])
        var nonFinitePositions = offAllAxesPositions()
        nonFinitePositions[0].x = .nan
        let nonFinite = mesh(nonFinitePositions, [0, 1, 2], recalculateNormals: false)
        let isolated = mesh(offAllAxesPositions() + [SIMD3<Float>(12, 12, 12)], [0, 1, 2])
        let cases: [(EditableMesh, MeshRadialArrayError)] = [
            (invalidIndex, .invalidMesh),
            (degenerate, .degenerateTriangle),
            (duplicate, .duplicateTriangle),
            (nonManifold, .nonManifoldEdge),
            (windingConflict, .windingConflict),
            (nonFinite, .nonFiniteValue),
            (isolated, .isolatedVertex),
        ]
        for (source, expected) in cases {
            XCTAssertThrowsError(try MeshRadialArray.estimate(
                mesh: source, transform: .identity, options: options())) {
                XCTAssertEqual($0 as? MeshRadialArrayError, expected)
            }
        }
    }

    func testResultCountsBoundsNormalsAdjacencyAndTopology() throws {
        let source = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(8, 2, 0))
        let requested = options(axis: .z, distribution: .openArc, count: 6, sweep: 250)
        let result = try MeshRadialArray.array(mesh: source, transform: .identity, options: requested)
        XCTAssertEqual(result.estimate.resultingVertexCount, source.vertices.count * requested.count)
        XCTAssertEqual(result.estimate.resultingTriangleCount, source.indices.count / 3 * requested.count)
        XCTAssertEqual(result.estimate.resultingComponentCount, requested.count)
        XCTAssertEqual(result.estimate.resultingBoundaryEdgeCount, 0)
        XCTAssertEqual(result.mesh.bounds, result.estimate.resultLocalBounds)
        XCTAssertTrue(result.mesh.hasCachedAdjacency)
        assertValid(result.mesh, components: requested.count, boundaryEdges: 0)
        XCTAssertTrue(result.estimate.maximumRadiusErrorMillimeters.isFinite)
        XCTAssertTrue(result.estimate.maximumAxialErrorMillimeters.isFinite)
        XCTAssertTrue(result.estimate.maximumAngularErrorDegrees.isFinite)
        XCTAssertTrue(result.estimate.maximumChordErrorMillimeters.isFinite)
        XCTAssertTrue(result.estimate.validationToleranceMillimeters.isFinite)
    }

    func testMultipleSourceComponentsRemainDetachedAndMultiplyMetrics() throws {
        let first = offAxisTriangle()
        let second = shifted(offAxisTriangle(), by: SIMD3<Float>(0, 0, 5))
        let source = combine([first, second])
        let requested = options(axis: .z, distribution: .openArc, count: 3, sweep: 110)
        let result = try MeshRadialArray.array(
            mesh: source, transform: .identity, options: requested)
        XCTAssertEqual(result.estimate.sourceComponentCount, 2)
        XCTAssertEqual(result.estimate.resultingComponentCount, 6)
        XCTAssertEqual(result.estimate.sourceBoundaryEdgeCount, 6)
        XCTAssertEqual(result.estimate.resultingBoundaryEdgeCount, 18)
        assertValid(result.mesh, components: 6, boundaryEdges: 18)
    }

    func testWorkingMemoryAndCountOverflowAreRejectedBeforeAllocation() {
        XCTAssertThrowsError(try MeshRadialArray.estimatedWorkingBytes(
            sourceVertices: Int.max,
            sourceTriangles: 1,
            uniqueEdges: 1,
            resultingVertices: 1,
            resultingTriangles: 1)) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try MeshRadialArray.estimate(
            mesh: offAxisTriangle(), transform: .identity,
            options: options(count: Int.max))) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .invalidCount)
        }
    }

    @MainActor
    func testPreviewRequestCoordinatorRejectsAAfterParameterChange() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        var coordinator = TopologyPreviewRequestCoordinator()
        let requestA = coordinator.begin()
        try model.beginMeshRadialArrayPreviewRequest(requestA)
        let candidateA = try model.makeMeshRadialArrayPreviewCandidate(
            options: options(count: 3), requestID: requestA)
        XCTAssertEqual(coordinator.invalidate(), requestA)
        model.discardMeshRadialArrayPreview(requestID: requestA)
        XCTAssertFalse(model.completeMeshRadialArrayPreviewRequest(
            requestID: requestA, candidate: candidateA))
        XCTAssertNil(model.meshRadialArrayPreview)
        XCTAssertFalse(model.isMeshRadialArrayRunning)
        XCTAssertFalse(coordinator.isCalculating)

        let requestB = coordinator.begin()
        XCTAssertNoThrow(try model.beginMeshRadialArrayPreviewRequest(requestB))
        model.discardMeshRadialArrayPreview(requestID: requestB)
        XCTAssertTrue(coordinator.finish(requestB))
    }

    @MainActor
    func testOldCompletionAndFailureCannotClearOrPublishOverRequestB() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        var coordinator = TopologyPreviewRequestCoordinator()
        let requestA = coordinator.begin()
        try model.beginMeshRadialArrayPreviewRequest(requestA)
        let candidateA = try model.makeMeshRadialArrayPreviewCandidate(
            options: options(count: 3), requestID: requestA)
        _ = coordinator.invalidate()
        model.discardMeshRadialArrayPreview(requestID: requestA)

        let requestB = coordinator.begin()
        let requestedB = options(distribution: .openArc, count: 4, sweep: -140)
        try model.beginMeshRadialArrayPreviewRequest(requestB)
        XCTAssertFalse(model.completeMeshRadialArrayPreviewRequest(
            requestID: requestA, candidate: candidateA))
        XCTAssertFalse(model.failMeshRadialArrayPreviewRequest(
            requestID: requestA, error: MeshRadialArrayError.invalidSweep))
        XCTAssertFalse(coordinator.finish(requestA))
        XCTAssertTrue(model.isMeshRadialArrayRunning)
        XCTAssertNil(model.meshRadialArrayPreview)
        XCTAssertNil(model.meshRadialArrayError)

        let candidateB = try model.makeMeshRadialArrayPreviewCandidate(
            options: requestedB, requestID: requestB)
        XCTAssertTrue(model.completeMeshRadialArrayPreviewRequest(
            requestID: requestB, candidate: candidateB))
        XCTAssertTrue(coordinator.finish(requestB))
        XCTAssertEqual(model.meshRadialArrayPreview, candidateB)
        XCTAssertFalse(model.isMeshRadialArrayRunning)
    }

    @MainActor
    func testDismissalPreventsGhostPreviewAndApply() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        var coordinator = TopologyPreviewRequestCoordinator()
        let request = coordinator.begin()
        try model.beginMeshRadialArrayPreviewRequest(request)
        let candidate = try model.makeMeshRadialArrayPreviewCandidate(
            options: options(count: 3), requestID: request)
        _ = coordinator.invalidate()
        model.discardMeshRadialArrayPreview(requestID: request)
        XCTAssertFalse(model.completeMeshRadialArrayPreviewRequest(
            requestID: request, candidate: candidate))
        XCTAssertNil(model.meshRadialArrayPreview)
        XCTAssertFalse(model.isMeshRadialArrayRunning)
        XCTAssertThrowsError(try model.applyMeshRadialArray(preview: candidate)) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .stalePreview)
        }
    }

    @MainActor
    func testSourceKeyAndPreparedPlanUseTwoStageValidation() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        let requested = options(axis: .y, distribution: .openArc, count: 3, sweep: 120)
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(options: requested)
        XCTAssertTrue(preview.source.matchesRuntimeIdentity(
            mesh: model.mesh,
            transform: model.objectTransform,
            meshChangeVersion: preview.source.meshChangeVersion,
            transformChangeVersion: preview.source.transformChangeVersion,
            options: requested))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(
            mesh: model.mesh,
            transform: model.objectTransform,
            meshChangeVersion: preview.source.meshChangeVersion,
            transformChangeVersion: preview.source.transformChangeVersion,
            options: options(axis: .x, distribution: .openArc, count: 3, sweep: 120)))

        let result = try MeshRadialArray.array(
            mesh: model.mesh, transform: model.objectTransform, options: requested)
        XCTAssertTrue(MeshRadialArray.preparedResultMatchesPreview(result, preview: preview))
        XCTAssertFalse(MeshRadialArray.preparedResultMatchesPreview(
            MeshRadialArrayResult(
                mesh: result.mesh,
                estimate: result.estimate,
                analysisFingerprint: result.analysisFingerprint ^ 1),
            preview: preview))
        let other = try MeshRadialArray.array(
            mesh: model.mesh, transform: model.objectTransform,
            options: options(axis: .y, distribution: .openArc, count: 4, sweep: 120))
        XCTAssertFalse(MeshRadialArray.preparedResultMatchesPreview(other, preview: preview))

        let originalTransform = model.objectTransform
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3)))
        model.updateTransform(originalTransform)
        XCTAssertTrue(model.isMeshRadialArrayPreviewStale)
    }

    @MainActor
    func testVertexEditStalesAndTopologyReplacementClearsPreview() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        _ = try model.previewMeshRadialArray(options: options(count: 3))
        _ = model.mesh.updatePositions([
            0: model.mesh.vertices[0].position + SIMD3<Float>(0.01, 0, 0),
        ])
        XCTAssertTrue(model.isMeshRadialArrayPreviewStale)

        try model.prepareForMeshRadialArray()
        _ = try model.previewMeshRadialArray(options: options(count: 3))
        model.mesh = EditableMesh(vertices: model.mesh.vertices, indices: model.mesh.indices)
        XCTAssertNil(model.meshRadialArrayPreview)
    }

    @MainActor
    func testWorkspaceApplyRecordsOneCommandAndPreservesState() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
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
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(
            options: options(axis: .y, distribution: .openArc, count: 3, sweep: 120))
        let result = try model.applyMeshRadialArray(preview: preview)
        XCTAssertEqual(model.undoCount, undoCount + 1)
        XCTAssertEqual(model.objectTransform, transform.sanitized())
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.interactionMode, .faceSelect)
        XCTAssertEqual(model.faceSelectionOperation, .toggle)
        XCTAssertEqual(model.brush, .crease)
        XCTAssertEqual(model.symmetry, SculptSymmetry(x: true, y: false, z: true))
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.meshRadialArrayPreview)
        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertTrue(model.pickingCacheHasIndexForTesting)
        XCTAssertFalse(model.isMeshRadialArraySnapshotSafeForTesting)
    }

    @MainActor
    func testUndoRedoRestoreSourceAndResultWithoutPreview() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        let source = model.mesh
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(options: options(count: 3))
        let result = try model.applyMeshRadialArray(preview: preview).mesh
        model.undo()
        XCTAssertEqual(model.mesh, source)
        XCTAssertNil(model.meshRadialArrayPreview)
        model.redo()
        XCTAssertEqual(model.mesh, result)
        XCTAssertNil(model.meshRadialArrayPreview)
    }

    @MainActor
    func testBVHPreparationFailureIsAtomic() throws {
        let cache = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        let model = WorkspaceModel(pickingCache: cache)
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(options: options(count: 3))
        let snapshot = WorkspaceState(model)
        XCTAssertThrowsError(try model.applyMeshRadialArray(preview: preview))
        snapshot.assertUnchanged(model)
        XCTAssertFalse(model.isMeshRadialArrayRunning)
        XCTAssertFalse(model.isMeshRadialArraySnapshotSafeForTesting)
    }

    @MainActor
    func testParameterChangeAndDoubleApplyAreAtomic() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        let previewA = try model.previewMeshRadialArray(options: options(axis: .x, count: 3))
        let previewB = try model.previewMeshRadialArray(
            options: options(axis: .z, distribution: .openArc, count: 4, sweep: 140))
        let before = WorkspaceState(model)
        XCTAssertThrowsError(try model.applyMeshRadialArray(preview: previewA)) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .stalePreview)
        }
        before.assertUnchanged(model)
        XCTAssertEqual(model.meshRadialArrayPreview, previewB)
        _ = try model.applyMeshRadialArray(preview: previewB)
        let applied = WorkspaceState(model)
        XCTAssertThrowsError(try model.applyMeshRadialArray(preview: previewB)) {
            XCTAssertEqual($0 as? MeshRadialArrayError, .stalePreview)
        }
        applied.assertUnchanged(model)
        XCTAssertFalse(model.isMeshRadialArrayRunning)
    }

    @MainActor
    func testPersistenceSTLAndProjectVersionContainOnlyOrdinaryMesh() throws {
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(
            options: options(distribution: .openArc, count: 3, sweep: 120))
        _ = try model.applyMeshRadialArray(preview: preview)
        let meshBefore = model.mesh
        let runtimeBefore = model.mesh.runtime
        let historyBefore = (model.undoCount, model.redoCount)
        let project = try model.projectData()
        let text = String(decoding: project, as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\":1"))
        XCTAssertFalse(text.contains("meshRadialArray"))
        XCTAssertFalse(text.contains("sweepDegrees"))
        XCTAssertEqual(try ProjectCodec.decode(project).mesh, meshBefore)
        try model.prepareForSTLExport()
        let stl = try model.stlData()
        XCTAssertEqual(stl.count, 84 + model.mesh.indices.count / 3 * 50)
        XCTAssertEqual(model.mesh, meshBefore)
        XCTAssertEqual(model.mesh.runtime, runtimeBefore)
        XCTAssertEqual(model.undoCount, historyBefore.0)
        XCTAssertEqual(model.redoCount, historyBefore.1)
    }

    @MainActor
    func testSuccessfulInstallUsesNormalRendererRevisionPath() throws {
        #if targetEnvironment(simulator)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        let model = WorkspaceModel()
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        renderer.update(mesh: model.mesh)
        profiler.reset(vertexCount: model.mesh.vertices.count, triangleCount: model.mesh.indices.count / 3)
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(options: options(count: 3))
        _ = try model.applyMeshRadialArray(preview: preview)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        #endif
    }

    @MainActor
    func testSheetFitsCompactWidthsAndDeclaresRaceSafetyAndAccessibility() throws {
        let model = WorkspaceModel()
        model.mesh = offAxisTriangle()
        for width in [CGFloat(320), 744, 1_024] {
            let sheet = UIHostingController(rootView: MeshRadialArrayView(model: model)
                .environment(\.dynamicTypeSize, .accessibility3))
            let size = sheet.sizeThatFits(in: CGSize(width: width, height: 2_400))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertLessThanOrEqual(size.width, width + 1)
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("src/UI/MeshRadialArrayView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("TopologyPreviewRequestCoordinator"))
        XCTAssertTrue(source.contains("beginMeshRadialArrayPreviewRequest"))
        XCTAssertTrue(source.contains("onDisappear { invalidatePreviewRequest() }"))
        XCTAssertTrue(source.contains("defer { isApplying = false }"))
        XCTAssertTrue(source.contains("accessibilityLabel"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".disabled(isBusy)").count - 1, 5)
    }

    @MainActor
    func testApplyUndoRedoAutosaveOrderingUsesCompletedMeshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshRadialArrayAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: MeshRadialArrayImmediateScheduler(),
            debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = shifted(try PrimitiveMeshBuilder.cube(size: 2), by: SIMD3<Float>(10, 0, 0))
        let before = model.mesh
        var generation = model.projectMutationGeneration
        try model.prepareForMeshRadialArray()
        let preview = try model.previewMeshRadialArray(options: options(count: 3))
        let previewWriteCount = await coordinator.successfulWriteCount
        XCTAssertEqual(previewWriteCount, 0)
        let after = try model.applyMeshRadialArray(preview: preview).mesh
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
        XCTAssertFalse(model.isMeshRadialArraySnapshotSafeForTesting)
    }

    private func options(
        axis: LinearArrayAxis = .z,
        distribution: RadialArrayDistribution = .fullCircle,
        count: Int = 6,
        direction: RadialArrayDirection = .positive,
        sweep: Double = 180
    ) -> MeshRadialArrayOptions {
        MeshRadialArrayOptions(
            axis: axis,
            distribution: distribution,
            count: count,
            direction: direction,
            sweepDegrees: sweep)
    }

    private func offAxisTriangle() -> EditableMesh {
        mesh(offAllAxesPositions(), [0, 1, 2])
    }

    private func offAllAxesTriangle() -> EditableMesh { offAxisTriangle() }

    private func offAllAxesPositions() -> [SIMD3<Float>] {
        [
            SIMD3<Float>(4, 3, 2),
            SIMD3<Float>(5, 3, 2),
            SIMD3<Float>(4, 4, 2),
        ]
    }

    private func mesh(
        _ positions: [SIMD3<Float>],
        _ indices: [UInt32],
        recalculateNormals: Bool = true
    ) -> EditableMesh {
        var result = EditableMesh(
            vertices: positions.map { MeshVertex(position: $0, normal: SIMD3<Float>(0, 0, 1)) },
            indices: indices)
        if recalculateNormals { result.recalculateNormals() }
        _ = result.adjacency()
        return result
    }

    private func shifted(_ source: EditableMesh, by offset: SIMD3<Float>) -> EditableMesh {
        var result = EditableMesh(
            vertices: source.vertices.map {
                MeshVertex(position: $0.position + offset, normal: $0.normal)
            },
            indices: source.indices)
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

    private func assertWorldRigidRotation(
        _ result: EditableMesh,
        source: EditableMesh,
        transform: ObjectTransform,
        options: MeshRadialArrayOptions,
        accuracy: Float = 0.000_2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let localAxis = SIMD3<Float>(
            options.axis == .x ? 1 : 0,
            options.axis == .y ? 1 : 0,
            options.axis == .z ? 1 : 0)
        let worldAxis = transform.worldDirection(fromLocal: localAxis)
        let pivot = transform.worldPosition(fromLocal: .zero)
        for copy in 0..<options.count {
            let angle = Float(options.angleDegrees(copyIndex: copy) * .pi / 180)
            let quaternion = simd_quatf(angle: angle, axis: worldAxis)
            for sourceID in source.vertices.indices {
                let sourceWorld = transform.worldPosition(fromLocal: source.vertices[sourceID].position)
                let expected = pivot + quaternion.act(sourceWorld - pivot)
                let actual = transform.worldPosition(fromLocal: result.meshPosition(
                    copy: copy, sourceID: sourceID, sourceCount: source.vertices.count))
                for axis in 0..<3 {
                    XCTAssertEqual(actual[axis], expected[axis], accuracy: accuracy, file: file, line: line)
                }
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

    private func worldBounds(_ mesh: EditableMesh, _ transform: ObjectTransform) -> AxisAlignedBoundingBox {
        var result = AxisAlignedBoundingBox()
        for vertex in mesh.vertices { result.include(transform.worldPosition(fromLocal: vertex.position)) }
        return result
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

@MainActor
private struct WorkspaceState {
    let mesh: EditableMesh
    let transform: ObjectTransform
    let camera: CameraState
    let selection: FaceSelection
    let undoCount: Int
    let redoCount: Int
    let generation: MutationGeneration
    let bytes: Data

    init(_ model: WorkspaceModel) {
        mesh = model.mesh
        transform = model.objectTransform
        camera = model.camera
        selection = model.faceSelection
        undoCount = model.undoCount
        redoCount = model.redoCount
        generation = model.projectMutationGeneration
        bytes = try! model.projectData()
    }

    func assertUnchanged(
        _ model: WorkspaceModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.mesh, mesh, file: file, line: line)
        XCTAssertEqual(model.objectTransform, transform, file: file, line: line)
        XCTAssertEqual(model.camera, camera, file: file, line: line)
        XCTAssertEqual(model.faceSelection, selection, file: file, line: line)
        XCTAssertEqual(model.undoCount, undoCount, file: file, line: line)
        XCTAssertEqual(model.redoCount, redoCount, file: file, line: line)
        XCTAssertEqual(model.projectMutationGeneration, generation, file: file, line: line)
        XCTAssertEqual(try? model.projectData(), bytes, file: file, line: line)
    }
}

private struct MeshRadialArrayImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
