import MetalKit
import SwiftUI
import XCTest
import simd
@testable import Forge3D

final class FaceBevelTests: XCTestCase {
    func testDefaultOptionsUseOneMillimeterWidthAndHalfMillimeterHeight() {
        let value = FaceBevelOptions()
        XCTAssertEqual(value.widthMillimeters, 1)
        XCTAssertEqual(value.heightMillimeters, 0.5)
        XCTAssertEqual(value.bevelAngleDegrees, atan2(0.5, 1) * 180 / .pi, accuracy: 1.0e-12)
    }

    func testSquareBevelHasExactCountsAndValidTopology() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        let result = try FaceBevel.bevel(
            mesh: source,
            selection: try selection(source, faces: [10, 11]),
            transform: .identity,
            options: options(width: 0.5, height: 0.5))
        XCTAssertEqual(result.estimate.originalVertexCount, 8)
        XCTAssertEqual(result.estimate.originalTriangleCount, 12)
        XCTAssertEqual(result.estimate.selectedFaceCount, 2)
        XCTAssertEqual(result.estimate.componentCount, 1)
        XCTAssertEqual(result.estimate.boundaryLoopCount, 1)
        XCTAssertEqual(result.estimate.boundaryEdgeCount, 4)
        XCTAssertEqual(result.estimate.resultingVertexCount, 12)
        XCTAssertEqual(result.estimate.resultingTriangleCount, 20)
        XCTAssertEqual(result.estimate.addedBevelVertexCount, 4)
        XCTAssertEqual(result.estimate.addedChamferTriangleCount, 8)
        let topology = MeshTopologyDiagnostics.analyze(result.mesh)
        XCTAssertEqual(topology.degenerateTriangleCount, 0)
        XCTAssertEqual(topology.duplicateTriangleCount, 0)
        XCTAssertEqual(topology.boundaryEdgeCount, 0)
        XCTAssertEqual(topology.nonManifoldEdgeCount, 0)
        XCTAssertEqual(topology.inconsistentWindingEdgeCount, 0)
        XCTAssertTrue(result.mesh.hasCachedAdjacency)
        XCTAssertNotEqual(result.mesh.runtime.topologyID, source.runtime.topologyID)
    }

    func testPositiveAndNegativeHeightShiftInnerCapAlongWindingNormal() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        for height in [0.5, -0.5] {
            let result = try FaceBevel.bevel(
                mesh: source,
                selection: try selection(source, faces: [10, 11]),
                transform: .identity,
                options: options(width: 0.25, height: height))
            let inner = result.mesh.vertices.suffix(4)
            XCTAssertTrue(inner.allSatisfy {
                abs(Double($0.position.y) - (1 + height)) < 0.000_01
            })
            XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).inconsistentWindingEdgeCount, 0)
        }
    }

    func testSingleTriangleCreatesSixChamferTriangles() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let result = try FaceBevel.bevel(
            mesh: source,
            selection: try selection(source, faces: [10]),
            transform: .identity,
            options: options(width: 0.25, height: 0.5))
        XCTAssertEqual(result.estimate.boundaryEdgeCount, 3)
        XCTAssertEqual(result.estimate.addedChamferTriangleCount, 6)
        XCTAssertEqual(result.mesh.indices.count / 3, 18)
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).degenerateTriangleCount, 0)
    }

    func testBevelAngleAndSlopeAreFiniteReferenceValues() {
        let value = options(width: 1, height: -1)
        XCTAssertEqual(value.bevelAngleDegrees, 45, accuracy: 1.0e-12)
        XCTAssertEqual(value.slopeLengthMillimeters, sqrt(2), accuracy: 1.0e-12)
        XCTAssertGreaterThan(value.bevelAngleDegrees, 0)
        XCTAssertLessThan(value.bevelAngleDegrees, 90)
    }

    func testWidthAndHeightLimitsRejectInvalidValues() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 10)
        let selected = try selection(source, faces: [10, 11])
        let cases: [(FaceBevelOptions, FaceBevelError)] = [
            (options(width: 0, height: 1), .widthTooSmall),
            (options(width: -1, height: 1), .widthTooSmall),
            (options(width: 0.000_9, height: 1), .widthTooSmall),
            (options(width: 1_001, height: 1), .widthLimitExceeded),
            (options(width: .nan, height: 1), .invalidWidth),
            (options(width: 1, height: 0), .heightTooSmall),
            (options(width: 1, height: 0.000_9), .heightTooSmall),
            (options(width: 1, height: -0.000_9), .heightTooSmall),
            (options(width: 1, height: 1_001), .heightLimitExceeded),
            (options(width: 1, height: -.infinity), .invalidHeight),
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try FaceBevel.estimate(
                mesh: source, selection: selected, transform: .identity, options: value)) {
                XCTAssertEqual($0 as? FaceBevelError, expected)
            }
        }
    }

    func testMinimumWidthAndSignedHeightAreAccepted() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 20)
        let selected = try selection(source, faces: [10, 11])
        for height in [0.001, -0.001] {
            let result = try FaceBevel.bevel(
                mesh: source, selection: selected, transform: .identity,
                options: options(width: 0.001, height: height))
            XCTAssertTrue(result.mesh.vertices.allSatisfy {
                $0.position.allFinite && $0.normal.allFinite
            })
        }
    }

    func testLargeValidWidthOnLargeRegionIsAccepted() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 1_000)
        let transform = ObjectTransform(scale: SIMD3<Float>(repeating: 4))
        let estimate = try FaceBevel.estimate(
            mesh: source,
            selection: try selection(source, faces: [10, 11]),
            transform: transform,
            options: options(width: 1_000, height: 1))
        XCTAssertEqual(estimate.innerAreaSquareMillimeters, 4_000_000, accuracy: 0.1)
    }

    func testStoredWorldGeometryPreservesWidthHeightSlopeAndBoundsAcrossTransforms() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 20)
        let transforms = [
            ObjectTransform.identity,
            ObjectTransform(
                translation: SIMD3<Float>(120, -80, 60),
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, -35, 47)),
                scale: SIMD3<Float>(2, 3, 5)),
            ObjectTransform(
                translation: SIMD3<Float>(100_000, -75_000, 45_000),
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(-11, 29, 63)),
                scale: SIMD3<Float>(0.2, 8, 40)),
        ]
        for transform in transforms {
            let result = try FaceBevel.bevel(
                mesh: source,
                selection: try selection(source, faces: [10, 11]),
                transform: transform,
                options: options(width: 0.5, height: -0.75))
            assertWorldHeight(
                source: source, result: result.mesh, transform: transform,
                expected: -0.75)
            try assertWorldBoundaryWidth(
                source: source, result: result.mesh, transform: transform,
                expected: 0.5)
            try assertWorldChamferCrossSections(
                source: source, result: result.mesh, transform: transform,
                width: 0.5, height: -0.75)
            XCTAssertEqual(worldBounds(result.mesh, transform), result.estimate.resultBounds)
        }
    }

    func testMinimumHeightAtUnrepresentableWorldTranslationIsRejected() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 20)
        let transform = ObjectTransform(
            translation: SIMD3<Float>(0, 1_000_000, 0),
            scale: SIMD3<Float>(0.1, 0.1, 0.1))
        XCTAssertThrowsError(try FaceBevel.bevel(
            mesh: source,
            selection: try selection(source, faces: [10, 11]),
            transform: transform,
            options: options(width: 0.25, height: 0.001))) {
            XCTAssertEqual($0 as? FaceBevelError, .heightRoundTripFailure)
        }
    }

    func testRingIndicesAndWindingCoverAllWorldAxesAndSignedHeights() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let transform = ObjectTransform(
            translation: SIMD3<Float>(17, -23, 31),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(19, -37, 61)),
            scale: SIMD3<Float>(0.5, 3, 7))
        let facePairs = [[0, 1], [2, 3], [4, 5], [6, 7], [8, 9], [10, 11]]
        for faces in facePairs {
            for height in [0.5, -0.5] {
                let selected = try selection(source, faces: faces)
                let analysis = try PlanarFaceRegionAnalyzer.analyze(
                    mesh: source, selection: selected, transform: transform,
                    widthMillimeters: 0.25)
                let component = try XCTUnwrap(analysis.components.first)
                let result = try FaceBevel.bevel(
                    mesh: source, selection: selected, transform: transform,
                    options: options(width: 0.25, height: height))
                let firstRingIndex = (source.indices.count / 3 - faces.count) * 3
                let innerBase = result.mesh.vertices.count - component.originalVertexIDs.count
                let innerBySource = Dictionary(uniqueKeysWithValues:
                    component.originalVertexIDs.enumerated().map {
                        ($0.element, UInt32(innerBase + $0.offset))
                    })
                var expectedIndices: [UInt32] = []
                for index in component.boundaryVertexIDs.indices {
                    let outerA = component.boundaryVertexIDs[index]
                    let outerB = component.boundaryVertexIDs[
                        (index + 1) % component.boundaryVertexIDs.count]
                    expectedIndices.append(contentsOf: [
                        outerA, outerB, try XCTUnwrap(innerBySource[outerB]),
                        outerA, try XCTUnwrap(innerBySource[outerB]),
                        try XCTUnwrap(innerBySource[outerA]),
                    ])
                }
                XCTAssertEqual(
                    Array(result.mesh.indices[
                        firstRingIndex..<(firstRingIndex + expectedIndices.count)]),
                    expectedIndices)
                for ringOffset in stride(from: 0, to: expectedIndices.count, by: 6) {
                    let ids = Array(expectedIndices[ringOffset..<(ringOffset + 6)])
                    let a = world(result.mesh, transform, ids[0])
                    let b = world(result.mesh, transform, ids[1])
                    let innerB = world(result.mesh, transform, ids[2])
                    let innerA = world(result.mesh, transform, ids[5])
                    let firstNormal = simd_cross(b - a, innerB - a)
                    let secondNormal = simd_cross(innerB - a, innerA - a)
                    let edgeDirection = simd_normalize(b - a)
                    let inward = simd_cross(component.basis.normal, edgeDirection)
                    XCTAssertGreaterThan(simd_dot(firstNormal, component.basis.normal), 0)
                    XCTAssertGreaterThan(simd_dot(secondNormal, component.basis.normal), 0)
                    let signedFacing = height > 0 ? -1.0 : 1.0
                    XCTAssertGreaterThan(simd_dot(firstNormal, inward) * signedFacing, 0)
                    XCTAssertGreaterThan(simd_dot(secondNormal, inward) * signedFacing, 0)
                }
                XCTAssertEqual(
                    MeshTopologyDiagnostics.analyze(result.mesh).inconsistentWindingEdgeCount,
                    0)
            }
        }
    }

    func testMultipleOppositeComponentsRemainIndependent() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let result = try FaceBevel.bevel(
            mesh: source,
            selection: try selection(source, faces: [0, 1, 2, 3]),
            transform: .identity,
            options: options(width: 0.5, height: 0.25))
        XCTAssertEqual(result.estimate.componentCount, 2)
        XCTAssertEqual(result.estimate.boundaryLoopCount, 2)
        XCTAssertEqual(result.estimate.addedBevelVertexCount, 8)
        XCTAssertEqual(result.estimate.addedChamferTriangleCount, 16)
        XCTAssertEqual(MeshTopologyDiagnostics.analyze(result.mesh).nonManifoldEdgeCount, 0)
    }

    func testResultOrderingAndFingerprintAreDeterministic() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let selected = try selection(source, faces: [10, 11])
        let first = try FaceBevel.bevel(
            mesh: source, selection: selected, transform: .identity,
            options: options(width: 0.5, height: 0.75))
        let second = try FaceBevel.bevel(
            mesh: source, selection: selected, transform: .identity,
            options: options(width: 0.5, height: 0.75))
        XCTAssertEqual(first.mesh.vertices, second.mesh.vertices)
        XCTAssertEqual(first.mesh.indices, second.mesh.indices)
        XCTAssertEqual(first.estimate, second.estimate)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
    }

    func testSharedGeometryKeepsFaceInsetOrderingAndOutputStable() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        let selected = try selection(source, faces: [10, 11])
        let first = try FaceInset.inset(
            mesh: source, selection: selected, transform: .identity,
            options: FaceInsetOptions(distanceMillimeters: 0.5))
        let second = try FaceInset.inset(
            mesh: source, selection: selected, transform: .identity,
            options: FaceInsetOptions(distanceMillimeters: 0.5))
        XCTAssertEqual(first.mesh.vertices, second.mesh.vertices)
        XCTAssertEqual(first.mesh.indices, second.mesh.indices)
        XCTAssertEqual(first.analysisFingerprint, second.analysisFingerprint)
    }

    func testPlanarRegionAnalyzerAndBuilderHaveNoWorkspaceDependency() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 2)
        let analysis = try PlanarFaceRegionAnalyzer.analyze(
            mesh: source,
            selection: try selection(source, faces: [10, 11]),
            transform: .identity,
            widthMillimeters: 0.25)
        let result = try PlanarFaceRegionMeshBuilder.build(
            source: source,
            analysis: analysis,
            innerLocalPositions: analysis.components.map(\.insetLocalPositions))
        XCTAssertEqual(result.indices.count / 3, analysis.estimate.resultingTriangleCount)
    }

    func testCollapseOpenBoundaryAndNonPlanarRegionsAreRejected() throws {
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertThrowsError(try FaceBevel.estimate(
            mesh: cube,
            selection: try selection(cube, faces: [10, 11]),
            transform: .identity,
            options: options(width: 1, height: 0.5))) {
            XCTAssertEqual($0 as? FaceBevelError, .collapsedBevel)
        }
        let open = mesh(
            [SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(0, 0, 2)],
            [0, 1, 2])
        XCTAssertThrowsError(try FaceBevel.estimate(
            mesh: open,
            selection: try selection(open, faces: [0]),
            transform: .identity,
            options: options())) {
            XCTAssertEqual($0 as? FaceBevelError, .openSelectedEdge)
        }
        let nonPlanar = try cubeWithSubdividedTop(size: 4, centerHeight: 0.1)
        XCTAssertThrowsError(try FaceBevel.estimate(
            mesh: nonPlanar,
            selection: try selection(nonPlanar, faces: [10, 11, 12, 13]),
            transform: .identity,
            options: options(width: 0.25, height: 0.5)))
    }

    func testPreviewSourceIncludesBothParametersAndRuntimeVersions() throws {
        let source = try PrimitiveMeshBuilder.cube(size: 4)
        let selected = try selection(source, faces: [10, 11])
        let meshVersion = TopologyEditChangeVersion(identity: UUID(), value: 4)
        let transformVersion = TopologyEditChangeVersion(identity: UUID(), value: 7)
        let preview = try FaceBevel.makePreview(
            mesh: source, selection: selected, transform: .identity,
            options: options(width: 0.5, height: -0.25),
            meshChangeVersion: meshVersion,
            transformChangeVersion: transformVersion)
        XCTAssertEqual(preview.source.meshChangeVersion, meshVersion)
        XCTAssertEqual(preview.source.transformChangeVersion, transformVersion)
        XCTAssertEqual(preview.source.options.widthMillimeters, 0.5)
        XCTAssertEqual(preview.source.options.heightMillimeters, -0.25)
        XCTAssertNotEqual(preview.source.analysisFingerprint, 0)
    }

    @MainActor
    func testWorkspaceApplyRecordsOneCommandAndPreservesTransformCameraAndTools() throws {
        let model = try configuredModel(faces: [10, 11])
        let transform = ObjectTransform(
            translation: SIMD3<Float>(4, -2, 7),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 20, 30)),
            scale: SIMD3<Float>(2, 3, 4))
        model.updateTransform(transform)
        let camera = model.camera
        let operation = model.faceSelectionOperation
        let beforeUndo = model.undoCount
        try model.prepareForFaceBevel()
        let preview = try model.previewFaceBevel(options: options(width: 0.25, height: 0.5))
        let result = try model.applyFaceBevel(preview: preview)
        XCTAssertEqual(model.undoCount, beforeUndo + 1)
        XCTAssertEqual(model.redoCount, 0)
        XCTAssertEqual(model.objectTransform, transform.sanitized())
        XCTAssertEqual(model.camera, camera)
        XCTAssertEqual(model.faceSelectionOperation, operation)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.faceExtrudePreview)
        XCTAssertNil(model.faceInsetPreview)
        XCTAssertNil(model.faceBevelPreview)
        XCTAssertEqual(model.mesh, result.mesh)
        XCTAssertTrue(model.pickingCacheHasIndexForTesting)
        XCTAssertFalse(model.isFaceBevelSnapshotSafeForTesting)
    }

    @MainActor
    func testUndoRedoRestoreMeshesWithoutSelectionOrPreview() throws {
        let model = try configuredModel(faces: [10, 11])
        let before = model.mesh
        try model.prepareForFaceBevel()
        let preview = try model.previewFaceBevel(options: options())
        let after = try model.applyFaceBevel(preview: preview).mesh
        model.undo()
        XCTAssertEqual(model.mesh, before)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.faceBevelPreview)
        model.redo()
        XCTAssertEqual(model.mesh, after)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.faceBevelPreview)
    }

    @MainActor
    func testFailedBVHPreparationLeavesWorkspaceAtomic() throws {
        let cache = MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh })
        let model = try configuredModel(faces: [10, 11], pickingCache: cache)
        try model.prepareForFaceBevel()
        let preview = try model.previewFaceBevel(options: options())
        let source = model.mesh
        let selected = model.faceSelection
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        XCTAssertThrowsError(try model.applyFaceBevel(preview: preview))
        XCTAssertEqual(model.mesh, source)
        XCTAssertEqual(model.faceSelection, selected)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertFalse(model.isFaceBevelSnapshotSafeForTesting)
    }

    @MainActor
    func testPreviewStalesAfterSelectionTransformVertexAndOptionChanges() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceBevel()
        let preview = try model.previewFaceBevel(options: options())
        XCTAssertTrue(model.applyFaceSelectionHit(8))
        model.setFaceSelectionOperation(.remove)
        XCTAssertTrue(model.applyFaceSelectionHit(8))
        XCTAssertTrue(model.isFaceBevelPreviewStale)
        XCTAssertThrowsError(try model.applyFaceBevel(preview: preview)) {
            XCTAssertEqual($0 as? FaceBevelError, .stalePreview)
        }

        let transformModel = try configuredModel(faces: [10, 11])
        let original = transformModel.objectTransform
        try transformModel.prepareForFaceBevel()
        let transformPreview = try transformModel.previewFaceBevel(options: options())
        transformModel.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3)))
        transformModel.updateTransform(original)
        XCTAssertTrue(transformModel.isFaceBevelPreviewStale)
        XCTAssertThrowsError(try transformModel.applyFaceBevel(preview: transformPreview))

        let vertexModel = try configuredModel(faces: [10, 11])
        try vertexModel.prepareForFaceBevel()
        _ = try vertexModel.previewFaceBevel(options: options())
        _ = vertexModel.mesh.updatePositions([
            0: vertexModel.mesh.vertices[0].position + SIMD3<Float>(0.01, 0, 0)
        ])
        XCTAssertTrue(vertexModel.isFaceBevelPreviewStale)
    }

    @MainActor
    func testFailedRecalculationRemovesOldPreview() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceBevel()
        let original = try model.previewFaceBevel(options: options())
        XCTAssertTrue(model.isFaceBevelPreviewCurrent(original))
        XCTAssertThrowsError(try model.previewFaceBevel(
            options: options(width: 0, height: 0.5)))
        XCTAssertNil(model.faceBevelPreview)
        XCTAssertFalse(model.isFaceBevelPreviewCurrent(original))
    }

    @MainActor
    func testPreviewCancelAndFailureDoNotMutateProjectOrHistory() throws {
        let model = try configuredModel(faces: [10, 11])
        let mesh = model.mesh
        let selection = model.faceSelection
        let history = (model.undoCount, model.redoCount)
        let generation = model.projectMutationGeneration
        let bytes = try model.projectData()
        try model.prepareForFaceBevel()
        _ = try model.previewFaceBevel(options: options())
        model.discardFaceBevelPreview()
        XCTAssertThrowsError(try model.previewFaceBevel(
            options: options(width: 0, height: 0.5)))
        XCTAssertEqual(model.mesh, mesh)
        XCTAssertEqual(model.faceSelection, selection)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes)
    }

    @MainActor
    func testApplyUndoRedoAutosaveOrderingUsesCompletedMeshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceBevelAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: FaceBevelImmediateScheduler(),
            debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.add)
        XCTAssertTrue(model.applyFaceSelectionHit(10))
        XCTAssertTrue(model.applyFaceSelectionHit(11))
        let before = model.mesh
        var generation = model.projectMutationGeneration
        try model.prepareForFaceBevel()
        let preview = try model.previewFaceBevel(options: options())
        let after = try model.applyFaceBevel(preview: preview).mesh
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
        XCTAssertEqual(model.projectMutationGeneration, generation)
        let writeCount = await coordinator.successfulWriteCount
        XCTAssertEqual(writeCount, 3)
    }

    @MainActor
    func testPersistenceAndCompactUILayoutExcludeRuntimeBevelState() throws {
        let model = try configuredModel(faces: [10, 11])
        try model.prepareForFaceBevel()
        _ = try model.previewFaceBevel(options: options())
        let data = try model.projectData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("faceBevel"))
        XCTAssertFalse(text.contains("widthMillimeters"))
        XCTAssertTrue(text.contains("\"formatVersion\":1"))
        for width in [CGFloat(320), 744, 1_024] {
            let panel = UIHostingController(rootView: FaceSelectionPanel(model: model))
            let panelSize = panel.sizeThatFits(in: CGSize(width: width, height: 1_600))
            XCTAssertLessThanOrEqual(panelSize.width, width + 1)
            let sheet = UIHostingController(rootView: FaceBevelView(model: model)
                .environment(\.dynamicTypeSize, .accessibility3))
            let sheetSize = sheet.sizeThatFits(in: CGSize(width: width, height: 1_800))
            XCTAssertTrue(sheetSize.width.isFinite && sheetSize.height.isFinite)
            XCTAssertLessThanOrEqual(sheetSize.width, width + 1)
        }
    }

    func testWorkingMemoryArithmeticIsBoundedAndOverflowSafe() throws {
        XCTAssertThrowsError(try FaceBevel.estimatedWorkingBytes(
            baseWorkingBytes: .max,
            duplicateVertices: 1,
            boundaryEdges: 1,
            resultingVertices: 1,
            resultingTriangles: 1)) {
            XCTAssertEqual($0 as? FaceBevelError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try FaceBevel.estimatedWorkingBytes(
            baseWorkingBytes: -1,
            duplicateVertices: 0,
            boundaryEdges: 0,
            resultingVertices: 0,
            resultingTriangles: 0)) {
            XCTAssertEqual($0 as? FaceBevelError, .arithmeticOverflow)
        }
        XCTAssertEqual(FaceBevel.maximumVertices, FaceInset.maximumVertices)
        XCTAssertEqual(FaceBevel.maximumTriangles, FaceInset.maximumTriangles)
        XCTAssertEqual(
            FaceBevel.maximumInnerIntersectionPairChecks,
            FaceInset.maximumInnerIntersectionPairChecks)
    }

    @MainActor
    func testSuccessfulInstallUploadsFreshTopologyOnceThenSkipsUnchangedFrame() throws {
        #if targetEnvironment(simulator)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        let model = try configuredModel(faces: [10, 11])
        renderer.update(mesh: model.mesh)
        profiler.reset(
            vertexCount: model.mesh.vertices.count,
            triangleCount: model.mesh.indices.count / 3)

        try model.prepareForFaceBevel()
        let preview = try model.previewFaceBevel(options: options())
        _ = try model.applyFaceBevel(preview: preview)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        #endif
    }

    private func options(
        width: Double = 0.25,
        height: Double = 0.5
    ) -> FaceBevelOptions {
        FaceBevelOptions(widthMillimeters: width, heightMillimeters: height)
    }

    private func selection(_ mesh: EditableMesh, faces: [Int]) throws -> FaceSelection {
        var value = try FaceSelection(
            sourceTopologyID: mesh.runtime.topologyID,
            sourceTopologyRevision: mesh.runtime.topologyRevision,
            triangleCount: mesh.indices.count / 3)
        for faceID in faces { _ = try value.set(faceID, selected: true) }
        return value
    }

    @MainActor
    private func configuredModel(
        faces: [Int],
        pickingCache: MeshBVHCache = MeshBVHCache()
    ) throws -> WorkspaceModel {
        let model = WorkspaceModel(pickingCache: pickingCache)
        model.mesh = try PrimitiveMeshBuilder.cube(size: 2)
        model.setInteractionMode(.faceSelect)
        model.setFaceSelectionOperation(.add)
        for faceID in faces { XCTAssertTrue(model.applyFaceSelectionHit(faceID)) }
        return model
    }

    private func mesh(
        _ positions: [SIMD3<Float>], _ indices: [UInt32]
    ) -> EditableMesh {
        var value = EditableMesh(
            vertices: positions.map {
                MeshVertex(position: $0, normal: SIMD3<Float>(0, 1, 0))
            },
            indices: indices)
        value.recalculateNormals(recordChange: false)
        return value
    }

    private func cubeWithSubdividedTop(
        size: Float, centerHeight: Float
    ) throws -> EditableMesh {
        let cube = try PrimitiveMeshBuilder.cube(size: size)
        var positions = cube.vertices.map(\.position)
        positions.append(SIMD3<Float>(0, size * 0.5 + centerHeight, 0))
        let indices = Array(cube.indices.prefix(30)) + [
            UInt32(3), 7, 8,
            7, 6, 8,
            6, 2, 8,
            2, 3, 8,
        ]
        return mesh(positions, indices)
    }

    private func assertWorldHeight(
        source: EditableMesh,
        result: EditableMesh,
        transform: ObjectTransform,
        expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let triangle = Array(source.indices[30...32])
        let a = double(transform.worldPosition(fromLocal: source.vertices[Int(triangle[0])].position))
        let b = double(transform.worldPosition(fromLocal: source.vertices[Int(triangle[1])].position))
        let c = double(transform.worldPosition(fromLocal: source.vertices[Int(triangle[2])].position))
        let normal = simd_normalize(simd_cross(b - a, c - a))
        let inner = result.vertices.suffix(4).map {
            double(transform.worldPosition(fromLocal: $0.position))
        }
        let magnitude = max(abs(a.x), max(abs(a.y), abs(a.z)))
        let tolerance = max(magnitude * Double(Float.ulpOfOne) * 24, 0.000_1)
        for point in inner {
            XCTAssertEqual(simd_dot(point - a, normal), expected,
                           accuracy: tolerance, file: file, line: line)
        }
    }

    private func assertWorldBoundaryWidth(
        source: EditableMesh,
        result: EditableMesh,
        transform: ObjectTransform,
        expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let analysis = try PlanarFaceRegionAnalyzer.analyze(
            mesh: source,
            selection: try selection(source, faces: [10, 11]),
            transform: transform,
            widthMillimeters: expected)
        let component = try XCTUnwrap(analysis.components.first, file: file, line: line)
        let firstInnerVertex = result.vertices.count - component.originalVertexIDs.count
        let innerBySource = Dictionary(uniqueKeysWithValues:
            component.originalVertexIDs.enumerated().map { offset, sourceID in
                let local = result.vertices[firstInnerVertex + offset].position
                let world = double(transform.worldPosition(fromLocal: local))
                let relative = world - component.planeOrigin
                return (sourceID, FaceInsetPoint2D(
                    x: simd_dot(relative, component.basis.u),
                    y: simd_dot(relative, component.basis.v)))
            })
        let coordinateMagnitude = result.vertices.reduce(0.0) { partial, vertex in
            let point = transform.worldPosition(fromLocal: vertex.position)
            return max(partial, max(abs(Double(point.x)), max(
                abs(Double(point.y)), abs(Double(point.z)))))
        }
        let tolerance = max(
            coordinateMagnitude * Double(Float.ulpOfOne) * 32,
            max(component.worldDiagonalLength * Double(Float.ulpOfOne) * 32, 0.000_1))
        for index in component.boundaryVertexIDs.indices {
            let aID = component.boundaryVertexIDs[index]
            let bID = component.boundaryVertexIDs[
                (index + 1) % component.boundaryVertexIDs.count]
            let sourceA = component.sourcePolygon[index]
            let sourceB = component.sourcePolygon[(index + 1) % component.sourcePolygon.count]
            let innerA = try XCTUnwrap(innerBySource[aID], file: file, line: line)
            let innerB = try XCTUnwrap(innerBySource[bID], file: file, line: line)
            let sourceEdge = sourceB - sourceA
            let innerEdge = innerB - innerA
            let sourceLength = hypot(sourceEdge.x, sourceEdge.y)
            let innerLength = hypot(innerEdge.x, innerEdge.y)
            XCTAssertGreaterThan(sourceLength, 0, file: file, line: line)
            XCTAssertGreaterThan(innerLength, 0, file: file, line: line)
            let sourceDirection = sourceEdge * (1 / sourceLength)
            let innerDirection = innerEdge * (1 / innerLength)
            XCTAssertEqual(
                PlanarFaceRegionGeometry.cross(sourceDirection, innerDirection),
                0,
                accuracy: tolerance / max(sourceLength, innerLength),
                file: file,
                line: line)
            XCTAssertEqual(
                PlanarFaceRegionGeometry.cross(sourceDirection, innerA - sourceA),
                expected,
                accuracy: tolerance,
                file: file,
                line: line)
        }
    }

    private func assertWorldChamferCrossSections(
        source: EditableMesh,
        result: EditableMesh,
        transform: ObjectTransform,
        width expectedWidth: Double,
        height expectedHeight: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let analysis = try PlanarFaceRegionAnalyzer.analyze(
            mesh: source,
            selection: try selection(source, faces: [10, 11]),
            transform: transform,
            widthMillimeters: expectedWidth)
        let component = try XCTUnwrap(analysis.components.first, file: file, line: line)
        let innerBase = result.vertices.count - component.originalVertexIDs.count
        let innerBySource = Dictionary(uniqueKeysWithValues:
            component.originalVertexIDs.enumerated().map { offset, sourceID in
                (sourceID, world(result, transform, UInt32(innerBase + offset)))
            })
        let coordinateMagnitude = result.vertices.reduce(0.0) { partial, vertex in
            let point = transform.worldPosition(fromLocal: vertex.position)
            return max(partial, max(abs(Double(point.x)), max(
                abs(Double(point.y)), abs(Double(point.z)))))
        }
        let precisionTolerance = max(
            coordinateMagnitude * Double(Float.ulpOfOne) * 32,
            max(component.worldDiagonalLength * Double(Float.ulpOfOne) * 32, 1.0e-6))
        let widthTolerance = min(precisionTolerance, max(expectedWidth * 0.02, 1.0e-6))
        let heightTolerance = min(precisionTolerance, max(abs(expectedHeight) * 0.02, 1.0e-6))
        let expectedSlope = hypot(expectedWidth, expectedHeight)
        let slopeTolerance = min(precisionTolerance * 2, max(expectedSlope * 0.02, 2.0e-6))
        for index in component.boundaryVertexIDs.indices {
            let aID = component.boundaryVertexIDs[index]
            let bID = component.boundaryVertexIDs[
                (index + 1) % component.boundaryVertexIDs.count]
            let outerA = world(source, transform, aID)
            let outerB = world(source, transform, bID)
            let innerA = try XCTUnwrap(innerBySource[aID], file: file, line: line)
            let innerB = try XCTUnwrap(innerBySource[bID], file: file, line: line)
            let sourceDirection = simd_normalize(outerB - outerA)
            let innerDirection = simd_normalize(innerB - innerA)
            XCTAssertEqual(
                simd_length(simd_cross(sourceDirection, innerDirection)), 0,
                accuracy: max(widthTolerance / simd_length(outerB - outerA), 1.0e-7),
                file: file, line: line)
            let innerCrossSectionPoint = innerA
                + sourceDirection * simd_dot(outerA - innerA, sourceDirection)
            let section = innerCrossSectionPoint - outerA
            let actualHeight = simd_dot(section, component.basis.normal)
            let inPlane = section - component.basis.normal * actualHeight
            let inward = simd_cross(component.basis.normal, sourceDirection)
            XCTAssertEqual(
                simd_dot(inPlane, inward), expectedWidth,
                accuracy: widthTolerance, file: file, line: line)
            XCTAssertEqual(
                actualHeight, expectedHeight,
                accuracy: heightTolerance, file: file, line: line)
            XCTAssertEqual(
                simd_length(section), expectedSlope,
                accuracy: slopeTolerance, file: file, line: line)
        }
    }

    private func world(
        _ mesh: EditableMesh,
        _ transform: ObjectTransform,
        _ vertexID: UInt32
    ) -> SIMD3<Double> {
        double(transform.worldPosition(fromLocal: mesh.vertices[Int(vertexID)].position))
    }

    private func worldBounds(
        _ mesh: EditableMesh, _ transform: ObjectTransform
    ) -> AxisAlignedBoundingBox {
        var result = AxisAlignedBoundingBox()
        for vertex in mesh.vertices {
            result.include(transform.worldPosition(fromLocal: vertex.position))
        }
        return result
    }

    private func double(_ value: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(value.x), Double(value.y), Double(value.z))
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

private struct FaceBevelImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
