import XCTest
import MetalKit
@testable import Forge3D

@MainActor
final class VertexSelectionTests: XCTestCase {
    func testTopologyTableBuildsDeterministicVertexRecords() throws {
        let first = try MeshVertexTopologyTable.build(mesh: quad())
        let second = try MeshVertexTopologyTable.build(mesh: quad())
        XCTAssertEqual(first.records.map(\.vertexID), [0, 1, 2, 3])
        XCTAssertEqual(first.records[0].neighboringVertexIDs, [1, 2, 3])
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertTrue(first.records.allSatisfy(\.isBoundary))
    }

    func testDuplicateAndSignedZeroPositionsRemainDistinctVertexIDs() throws {
        let source = mesh(
            [SIMD3(0,0,0), SIMD3(-0.0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)],
            [0,2,3, 1,3,2])
        let table = try MeshVertexTopologyTable.build(mesh: source)
        XCTAssertEqual(table.records.map(\.vertexID), [0,1,2,3])
        XCTAssertNotEqual(table.records[0].incidentFaceIDs, table.records[1].incidentFaceIDs)
    }

    func testTopologyTableClassifiesIsolatedAndNonManifoldVertices() throws {
        let isolated = try MeshVertexTopologyTable.build(mesh: mesh(
            [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(9,9,9)], [0,1,2]))
        XCTAssertTrue(isolated.records[3].isIsolated)
        let nonManifold = try MeshVertexTopologyTable.build(mesh: mesh(
            [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,1)],
            [0,1,2, 1,0,3, 0,1,4]))
        XCTAssertTrue(nonManifold.records[0].hasNonManifoldNeighborhood)
        XCTAssertTrue(nonManifold.records[1].hasNonManifoldNeighborhood)
    }

    func testTopologyTableRejectsInvalidMeshAndMemoryLimit() throws {
        XCTAssertThrowsError(try MeshVertexTopologyTable.build(mesh: mesh([SIMD3(0,0,0)], [0,1,2])))
        XCTAssertThrowsError(try MeshVertexTopologyTable.build(mesh: quad(), memoryLimit: 1))
        XCTAssertThrowsError(try MeshVertexTopologyTable.estimatedPeakBytes(vertexCount: Int.max, indexCount: Int.max))
    }

    func testDenseSelectionOperationsAndNoOpVersions() throws {
        let table = try MeshVertexTopologyTable.build(mesh: quad())
        var selection = try VertexSelection(table: table)
        let emptyVersion = selection.version
        XCTAssertFalse(selection.clear())
        XCTAssertEqual(selection.version, emptyVersion)
        XCTAssertTrue(try selection.apply(.add, vertexID: 2))
        let oneVersion = selection.version
        XCTAssertFalse(try selection.apply(.add, vertexID: 2))
        XCTAssertEqual(selection.version, oneVersion)
        XCTAssertTrue(try selection.apply(.toggle, vertexID: 2))
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertTrue(try selection.apply(.replace, vertexIDs: [3, 1, 3]))
        XCTAssertEqual(selection.selectedVertexIDs(), [1, 3])
        XCTAssertTrue(try selection.apply(.remove, vertexID: 1))
        XCTAssertEqual(selection.selectedVertexIDs(), [3])
    }

    func testDenseSelectionMasksWordBoundaries() throws {
        for count in [0, 1, 63, 64, 65] {
            let table = try MeshVertexTopologyTable.build(mesh: isolatedVertices(count))
            var selection = try VertexSelection(table: table)
            XCTAssertEqual(selection.selectAll(), count > 0)
            XCTAssertEqual(selection.selectedCount, count)
            XCTAssertEqual(selection.selectedVertexIDs().count, count)
            XCTAssertEqual(selection.invert(), count > 0)
            XCTAssertEqual(selection.selectedCount, 0)
        }
    }

    func testInvalidVertexDoesNotMutateSelection() throws {
        let table = try MeshVertexTopologyTable.build(mesh: quad())
        var selection = try VertexSelection(table: table)
        let before = selection
        XCTAssertThrowsError(try selection.apply(.add, vertexID: 99))
        XCTAssertEqual(selection, before)
    }

    func testConnectedUsesSharedEdgeTopologyAndMultipleSeeds() throws {
        let source = mesh(
            [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0),
             SIMD3(3,0,0), SIMD3(4,0,0), SIMD3(3,1,0)],
            [0,1,2, 3,4,5])
        let table = try MeshVertexTopologyTable.build(mesh: source)
        XCTAssertEqual(try VertexSelectionConnectivity.connectedVertexIDs(table: table, seeds: [0]), [0,1,2])
        XCTAssertEqual(try VertexSelectionConnectivity.connectedVertexIDs(table: table, seeds: [4,0,4]), [0,1,2,3,4,5])
    }

    func testConnectedSupportsEverySelectionOperation() throws {
        let table = try MeshVertexTopologyTable.build(mesh: quad())
        let connected = try VertexSelectionConnectivity.connectedVertexIDs(table: table, seeds: [0])
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.replace, vertexIDs: connected))
        XCTAssertEqual(selection.selectedCount, 4)
        XCTAssertTrue(try selection.apply(.remove, vertexIDs: connected))
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertTrue(try selection.apply(.add, vertexIDs: connected))
        XCTAssertTrue(try selection.apply(.toggle, vertexIDs: connected))
        XCTAssertEqual(selection.selectedCount, 0)
    }

    func testPickerUsesScreenDistanceThresholdAndIDTieBreak() throws {
        let source = mesh([SIMD3(-0.5,-0.5,0), SIMD3(0.5,-0.5,0), SIMD3(0,0.5,0)], [0,1,2])
        let table = try MeshVertexTopologyTable.build(mesh: source)
        let ray = Ray(origin: SIMD3(0,0,1), direction: SIMD3(0,0,-1))
        let cache = MeshBVHCache()
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: ray, screenPoint: CGPoint(x: 50, y: 150), viewportSize: CGSize(width: 200, height: 200),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache), .hit(vertexID: 0))
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: ray, screenPoint: CGPoint(x: 100, y: 150), viewportSize: CGSize(width: 200, height: 200),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache, threshold: 60), .hit(vertexID: 0))
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: ray, screenPoint: CGPoint(x: 0, y: 0), viewportSize: CGSize(width: 200, height: 200),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache, threshold: 1), .miss)
    }

    func testNearestCandidateUsesStrictDistanceBeforeID() {
        let candidates = [
            MeshVertexPicker.ScreenCandidate(vertexID: 1, point: CGPoint(x: 1.00001, y: 0)),
            MeshVertexPicker.ScreenCandidate(vertexID: 99, point: CGPoint(x: 1, y: 0))
        ]
        XCTAssertEqual(MeshVertexPicker.nearestCandidate(
            to: .zero, candidates: candidates, threshold: 2), 99)
        XCTAssertEqual(MeshVertexPicker.nearestCandidate(
            to: .zero, candidates: Array(candidates.reversed()), threshold: 2), 99)
    }

    func testNearestCandidateUsesIDOnlyForExactDistanceTie() {
        let candidates = [
            MeshVertexPicker.ScreenCandidate(vertexID: 7, point: CGPoint(x: -1, y: 0)),
            MeshVertexPicker.ScreenCandidate(vertexID: 2, point: CGPoint(x: 1, y: 0)),
            MeshVertexPicker.ScreenCandidate(vertexID: 2, point: CGPoint(x: 1, y: 0))
        ]
        XCTAssertEqual(MeshVertexPicker.nearestCandidate(
            to: .zero, candidates: candidates, threshold: 1), 2)
    }

    func testNearestCandidateThresholdAndNonFiniteInputs() {
        let onBoundary = MeshVertexPicker.ScreenCandidate(vertexID: 4, point: CGPoint(x: 3, y: 4))
        XCTAssertEqual(MeshVertexPicker.nearestCandidate(
            to: .zero, candidates: [onBoundary], threshold: 5), 4)
        XCTAssertNil(MeshVertexPicker.nearestCandidate(
            to: .zero, candidates: [onBoundary], threshold: 4.9999))
        XCTAssertNil(MeshVertexPicker.nearestCandidate(
            to: CGPoint(x: CGFloat.nan, y: 0), candidates: [onBoundary], threshold: 5))
        XCTAssertNil(MeshVertexPicker.nearestCandidate(
            to: .zero, candidates: [.init(vertexID: 1, point: CGPoint(x: CGFloat.infinity, y: 0))],
            threshold: 5))
    }

    func testTopologyFingerprintIncludesCountsAndTriangleIndexSequence() throws {
        let first = quad()
        let reordered = mesh(first.vertices.map(\.position), [0,2,3, 0,1,2])
        let differentCount = mesh(first.vertices.map(\.position) + [SIMD3(2,2,0)], first.indices)
        XCTAssertNotEqual(try MeshVertexTopologyTable.topologyFingerprint(mesh: first),
                          try MeshVertexTopologyTable.topologyFingerprint(mesh: reordered))
        XCTAssertNotEqual(try MeshVertexTopologyTable.topologyFingerprint(mesh: first),
                          try MeshVertexTopologyTable.topologyFingerprint(mesh: differentCount))
    }

    func testTopologyFingerprintRejectsMalformedIndexData() {
        XCTAssertThrowsError(try MeshVertexTopologyTable.topologyFingerprint(
            mesh: mesh([SIMD3(0,0,0)], [0,0])))
        XCTAssertThrowsError(try MeshVertexTopologyTable.topologyFingerprint(
            mesh: mesh([SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], [0,1,9])))
    }

    func testSelectionBindsIndexCountAndFingerprint() throws {
        let table = try MeshVertexTopologyTable.build(mesh: quad())
        let selection = try VertexSelection(table: table)
        let wrongCount = MeshVertexTopologyTable(
            sourceTopologyID: table.sourceTopologyID,
            sourceTopologyRevision: table.sourceTopologyRevision,
            sourceVertexCount: table.sourceVertexCount,
            sourceIndexCount: table.sourceIndexCount + 3,
            records: table.records,
            fingerprint: table.fingerprint)
        let wrongFingerprint = MeshVertexTopologyTable(
            sourceTopologyID: table.sourceTopologyID,
            sourceTopologyRevision: table.sourceTopologyRevision,
            sourceVertexCount: table.sourceVertexCount,
            sourceIndexCount: table.sourceIndexCount,
            records: table.records,
            fingerprint: table.fingerprint ^ 1)
        XCTAssertFalse(selection.matches(wrongCount))
        XCTAssertFalse(selection.matches(wrongFingerprint))
    }

    func testPickerRejectsStaleTopologyAndInvalidRay() throws {
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        let replacement = EditableMesh(vertices: source.vertices, indices: source.indices)
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: Ray(origin: SIMD3(0,0,1), direction: SIMD3(0,0,-1)),
            screenPoint: .zero, viewportSize: CGSize(width: 100, height: 100),
            mesh: replacement, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: MeshBVHCache()), .unavailable)
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: Ray(origin: SIMD3(.nan,0,1), direction: SIMD3(0,0,-1)),
            screenPoint: .zero, viewportSize: CGSize(width: 100, height: 100),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: MeshBVHCache()), .unavailable)
    }

    func testPickerRejectsInvalidViewportAndProjectedCoordinates() throws {
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        let ray = Ray(origin: SIMD3(0.25,0.25,1), direction: SIMD3(0,0,-1))
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: ray, screenPoint: .zero, viewportSize: .zero,
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: MeshBVHCache()), .unavailable)
        var zeroW = matrix_identity_float4x4
        zeroW.columns.3.w = 0
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: ray, screenPoint: CGPoint(x: 50, y: 50),
            viewportSize: CGSize(width: 100, height: 100), mesh: source,
            transform: .identity, viewProjection: zeroW, table: table,
            cache: MeshBVHCache(), threshold: 100), .miss)
        var nonFinite = matrix_identity_float4x4
        nonFinite.columns.0.x = .nan
        XCTAssertEqual(MeshVertexPicker.pick(
            worldRay: ray, screenPoint: CGPoint(x: 50, y: 50),
            viewportSize: CGSize(width: 100, height: 100), mesh: source,
            transform: .identity, viewProjection: nonFinite, table: table,
            cache: MeshBVHCache(), threshold: 100), .miss)
    }

    func testPickerUsesOnlyNearestVisibleTriangleCandidates() throws {
        let source = mesh(
            [SIMD3(-0.1,-0.1,0.5), SIMD3(0.1,-0.1,0.5), SIMD3(0,0.1,0.5),
             SIMD3(-0.9,-0.9,0), SIMD3(0.9,-0.9,0), SIMD3(0,0.9,0)],
            [0,1,2, 3,4,5])
        let table = try MeshVertexTopologyTable.build(mesh: source)
        let result = MeshVertexPicker.pick(
            worldRay: Ray(origin: SIMD3(0,0,1), direction: SIMD3(0,0,-1)),
            screenPoint: CGPoint(x: 5, y: 95), viewportSize: CGSize(width: 100, height: 100),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: MeshBVHCache(), threshold: 2)
        XCTAssertEqual(result, .miss)
    }

    func testPickerRespectsTranslationRotationAndNonUniformScale() throws {
        let source = mesh([SIMD3(-0.5,-0.5,0), SIMD3(0.5,-0.5,0), SIMD3(0,0.5,0)], [0,1,2])
        let table = try MeshVertexTopologyTable.build(mesh: source)
        let transforms = [
            ObjectTransform(translation: SIMD3(0.2,-0.1,0.3)),
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3(0,0,35))),
            ObjectTransform(translation: SIMD3(0.1,0.1,0.2),
                            rotation: ObjectTransform.rotation(degrees: SIMD3(20,10,15)),
                            scale: SIMD3(2,0.5,1.5))
        ]
        for transform in transforms {
            let localTarget = SIMD3<Float>(-0.25, -0.25, 0)
            let worldTarget = transform.worldPosition(fromLocal: localTarget)
            let worldDirection = transform.worldDirection(fromLocal: SIMD3(0,0,-1))
            let ray = Ray(origin: worldTarget - worldDirection, direction: worldDirection)
            XCTAssertEqual(MeshVertexPicker.pick(
                worldRay: ray, screenPoint: CGPoint(x: 37.5, y: 62.5),
                viewportSize: CGSize(width: 100, height: 100), mesh: source,
                transform: transform, viewProjection: transform.inverseModelMatrix,
                table: table, cache: MeshBVHCache(), threshold: 30), .hit(vertexID: 0))
        }
    }

    func testHoverVersionChangesOnlyWhenValueChanges() {
        let initial = VertexHoverState(vertexID: 1)
        XCTAssertEqual(initial.updating(1).version, initial.version)
        XCTAssertNotEqual(initial.updating(2).version, initial.version)
    }

    func testRawHoverIsSuppressedAndRestoredBySelectionWithoutPointerMotion() throws {
        let table = try MeshVertexTopologyTable.build(mesh: quad())
        var selection = try VertexSelection(table: table)
        let rawHover = VertexHoverState(vertexID: 2)
        XCTAssertEqual(rawHover.effectiveVertexID(for: selection), 2)
        XCTAssertTrue(try selection.apply(.add, vertexID: 2))
        XCTAssertNil(rawHover.effectiveVertexID(for: selection))
        XCTAssertEqual(rawHover.vertexID, 2)
        XCTAssertTrue(try selection.apply(.remove, vertexID: 2))
        XCTAssertEqual(rawHover.effectiveVertexID(for: selection), 2)
    }

    func testVertexOverlayPeakMemoryIncludesActiveGPUCandidateGPUAndCPU() {
        XCTAssertEqual(try? VertexOverlayMemory.peakBytes(activeBytes: 40, candidateCount: 3).get(), 64)
        XCTAssertEqual(try? VertexOverlayMemory.peakBytes(activeBytes: 0, candidateCount: 1).get(), 8)
        XCTAssertEqual(try? VertexOverlayMemory.peakBytes(activeBytes: 400, candidateCount: 1).get(), 408)
        for result in [
            VertexOverlayMemory.peakBytes(activeBytes: -1, candidateCount: 1),
            VertexOverlayMemory.peakBytes(activeBytes: Int.max, candidateCount: 1),
            VertexOverlayMemory.peakBytes(activeBytes: 0, candidateCount: Int.max)
        ] {
            guard case .failure(.arithmeticOverflow) = result else {
                return XCTFail("Expected checked arithmetic failure")
            }
        }
    }

    func testWorkspaceSelectionDoesNotDirtyProjectOrHistory() throws {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        let bytes = try model.projectData()
        let generation = model.projectMutationGeneration
        let history = (model.undoCount, model.redoCount)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        model.selectAllVertices()
        model.invertVertexSelection()
        model.clearVertexSelection()
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(try model.projectData(), bytes)
    }

    func testWorkspaceSelectionModesAndOperationsRemainRuntimeOnly() throws {
        let model = WorkspaceModel()
        let bytes = try model.projectData()
        let generation = model.projectMutationGeneration
        let history = (model.undoCount, model.redoCount)
        model.setInteractionMode(.vertexSelect)
        for operation in VertexSelectionOperation.allCases {
            model.setVertexSelectionOperation(operation)
            _ = model.applyVertexSelectionHit(0)
        }
        model.selectAllVertices()
        model.invertVertexSelection()
        model.selectConnectedVertices()
        model.clearVertexSelection()
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(try ProjectCodec.decode(model.projectData()).formatVersion, 1)
    }

    func testFaceEdgeAndVertexSelectionsRemainIndependentAcrossModes() {
        let model = WorkspaceModel()
        model.setInteractionMode(.faceSelect)
        XCTAssertTrue(model.applyFaceSelectionHit(0))
        let faceCount = model.selectedFaceCount
        model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0))
        let edgeCount = model.selectedEdgeCount
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        XCTAssertEqual(model.selectedFaceCount, faceCount)
        XCTAssertEqual(model.selectedEdgeCount, edgeCount)
        XCTAssertEqual(model.selectedVertexCount, 1)
        model.setVertexSelectionOperation(.toggle)
        XCTAssertTrue(model.applyVertexSelectionHit(1))
        XCTAssertEqual(model.selectedFaceCount, faceCount)
        XCTAssertEqual(model.selectedEdgeCount, edgeCount)
    }

    func testProjectLoadDoesNotPersistVertexSelectionOrHover() throws {
        let source = WorkspaceModel()
        source.setInteractionMode(.vertexSelect)
        XCTAssertTrue(source.applyVertexSelectionHit(0))
        let loaded = WorkspaceModel()
        try loaded.loadProject(data: source.projectData())
        XCTAssertEqual(loaded.selectedVertexCount, 0)
        XCTAssertNil(loaded.vertexHover.vertexID)
    }

    func testLeavingVertexModeClearsHoverWithoutClearingSelection() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        model.updateVertexHover(
            fromWorldRay: Ray(origin: SIMD3(0,0,100), direction: SIMD3(0,0,-1)),
            screenPoint: CGPoint(x: 50, y: 50), viewportSize: CGSize(width: 100, height: 100),
            viewProjection: matrix_identity_float4x4)
        model.setInteractionMode(.sculpt)
        XCTAssertNil(model.vertexHover.vertexID)
        XCTAssertEqual(model.selectedVertexCount, 1)
        model.setInteractionMode(.vertexSelect)
        XCTAssertNil(model.vertexHover.vertexID)
        XCTAssertEqual(model.selectedVertexCount, 1)
    }

    func testWorkspaceKeepsSelectionAcrossVertexOnlyChange() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        let selected = model.vertexSelection
        var changed = model.mesh
        let position = changed.vertices[0].position + SIMD3<Float>(0.01, 0, 0)
        XCTAssertEqual(changed.updatePositions([0: position]).count, 1)
        model.mesh = changed
        XCTAssertEqual(model.vertexSelection, selected)
    }

    func testWorkspaceClearsSelectionForNewTopology() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        model.mesh = quad()
        XCTAssertEqual(model.selectedVertexCount, 0)
        XCTAssertEqual(model.totalVertexCount, 4)
    }

    func testRendererDrawOrderPlacesVertexBeforeDiagnostics() {
        XCTAssertEqual(MetalRenderer.drawOrder,
                       [.mesh, .faceSelection, .edgeSelection, .vertexSelection, .diagnostics, .gizmo])
    }

    func testOverlayRetriesAfterAllocationFailure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultVertexAllocator(); allocator.failNext = true
        guard let renderer = MetalRenderer(view: view, profiler: nil,
                                           vertexSelectionBufferAllocator: allocator) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        let hover = VertexHoverState()
        let failed = renderer.updateVertexSelection(mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(failed.selected, .unavailable(.allocationFailed))
        XCTAssertFalse(renderer.vertexSelectionOverlayHasSelectedBuffer)
        let retried = renderer.updateVertexSelection(mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(retried.selected, .updated)
        XCTAssertTrue(renderer.vertexSelectionOverlayHasSelectedBuffer)
    }


    func testOverlayRetriesAfterCopyFailureWithoutCachingFailedSelection() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultVertexAllocator(); allocator.failCopyNumber = 1
        guard let renderer = MetalRenderer(view: view, profiler: nil,
                                           vertexSelectionBufferAllocator: allocator) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        let failed = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        XCTAssertEqual(failed.selected, .unavailable(.copyFailed))
        XCTAssertFalse(renderer.vertexSelectionOverlayHasSelectedBuffer)
        let retried = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        XCTAssertEqual(retried.selected, .updated)
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedCount, 1)
    }

    func testOverlayMemoryLimitFailureRetriesAndPreservesHoverPeer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(
            view: view, profiler: nil, vertexSelectionMemoryLimit: 8) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        let hover = VertexHoverState(vertexID: 3)
        let initial = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(initial.hover, .updated)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 1)
        XCTAssertTrue(try selection.apply(.add, vertexIDs: [0, 1]))
        let failed = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(failed.selected, .unavailable(.workingMemoryLimitExceeded))
        XCTAssertEqual(failed.hover, .unchanged)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 1)
    }

    func testHoverAllocationFailurePreservesSelectedPeerAndRetries() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultVertexAllocator()
        guard let renderer = MetalRenderer(view: view, profiler: nil,
                                           vertexSelectionBufferAllocator: allocator) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        _ = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        allocator.failNext = true
        let hover = VertexHoverState(vertexID: 2)
        let failed = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(failed.selected, .unchanged)
        XCTAssertEqual(failed.hover, .unavailable(.allocationFailed))
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedCount, 1)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 0)
        let retry = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(retry.hover, .updated)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 1)
    }

    func testHoverCopyFailurePreservesSelectedPeerAndRetries() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultVertexAllocator(); allocator.failCopyNumber = 2
        guard let renderer = MetalRenderer(view: view, profiler: nil,
                                           vertexSelectionBufferAllocator: allocator) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        _ = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        let hover = VertexHoverState(vertexID: 2)
        let failed = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(failed.selected, .unchanged)
        XCTAssertEqual(failed.hover, .unavailable(.copyFailed))
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedCount, 1)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 0)
        let retry = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: hover)
        XCTAssertEqual(retry.hover, .updated)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 1)
    }

    func testOverlayFailureNotificationIsDeduplicatedAndRecoveryClearsIt() {
        let model = WorkspaceModel()
        let failure = VertexSelectionOverlayUpdateSummary(
            selected: .unavailable(.copyFailed), hover: .unchanged)
        model.handleVertexSelectionOverlayUpdate(failure)
        let first = model.vertexSelectionError
        model.handleVertexSelectionOverlayUpdate(failure)
        XCTAssertEqual(model.vertexSelectionError, first)
        model.handleVertexSelectionOverlayUpdate(
            .init(selected: .updated, hover: .unchanged))
        XCTAssertNil(model.vertexSelectionError)
    }

    func testClearingSelectionReleasesSelectedBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(view: view, profiler: nil) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        _ = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        XCTAssertTrue(renderer.vertexSelectionOverlayHasSelectedBuffer)
        XCTAssertTrue(selection.clear())
        let cleared = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        XCTAssertEqual(cleared.selected, .cleared)
        XCTAssertFalse(renderer.vertexSelectionOverlayHasSelectedBuffer)
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedCount, 0)
    }

    func testSelectedHoverTransitionsDoNotReuploadSelectedPeer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(view: view, profiler: nil) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        let rawHover = VertexHoverState(vertexID: 1)
        _ = renderer.updateVertexSelection(mesh: source, table: table, selection: selection, hover: rawHover)
        let selectedUploads = renderer.vertexSelectionOverlaySelectedUploadCount
        let hoverUploads = renderer.vertexSelectionOverlayHoverUploadCount
        XCTAssertTrue(try selection.apply(.add, vertexID: 1))
        _ = renderer.updateVertexSelection(mesh: source, table: table, selection: selection, hover: rawHover)
        XCTAssertNil(rawHover.effectiveVertexID(for: selection))
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 0)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverUploadCount, hoverUploads)
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedUploadCount, selectedUploads + 1)
        XCTAssertTrue(try selection.apply(.remove, vertexID: 1))
        _ = renderer.updateVertexSelection(mesh: source, table: table, selection: selection, hover: rawHover)
        XCTAssertEqual(renderer.vertexSelectionOverlayHoverCount, 1)
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedUploadCount, selectedUploads + 2)
    }

    func testSelectedVertexSuppressesHover() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        model.clearVertexHover()
        XCTAssertNil(model.vertexHover.vertexID)
    }

    func testVertexTranslatePivotUsesSelectedLocalAABBCenterAndWorldTransform() throws {
        let source = quad()
        let table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.replace, vertexIDs: [0, 2, 3]))
        let transform = ObjectTransform(
            translation: SIMD3(4, -3, 2),
            rotation: ObjectTransform.rotation(degrees: SIMD3(10, 20, 30)),
            scale: SIMD3(2, 0.5, 3))
        let transaction = try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: transform)
        XCTAssertEqual(transaction.vertexIDs, [0, 2, 3])
        XCTAssertEqual(transaction.pivotLocal, SIMD3(0.5, 0.5, 0))
        assertEqual(transaction.pivotWorld, transform.worldPosition(fromLocal: transaction.pivotLocal))
    }

    func testVertexTranslateWorldDeltaUsesInverseModelLinearPart() throws {
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.replace, vertexIDs: [0, 2]))
        let transform = ObjectTransform(
            translation: SIMD3(100, -50, 25),
            rotation: ObjectTransform.rotation(degrees: SIMD3(20, -35, 15)),
            scale: SIMD3(3, 0.25, 2))
        var transaction = try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: transform)
        let worldDelta = SIMD3<Float>(2, -1, 0.5)
        let candidate = try XCTUnwrap(VertexTranslateGeometry.candidate(
            sourceMesh: source, transaction: &transaction, worldDelta: worldDelta))
        for (offset, id) in transaction.vertexIDs.enumerated() {
            let beforeWorld = transform.worldPosition(fromLocal: transaction.startPositions[offset])
            let afterWorld = transform.worldPosition(fromLocal: candidate.vertices[Int(id)].position)
            assertEqual(afterWorld - beforeWorld, worldDelta, accuracy: 0.000_05)
        }
        XCTAssertEqual(candidate.indices, source.indices)
        XCTAssertEqual(candidate.runtime.topologyID, source.runtime.topologyID)
        XCTAssertEqual(candidate.runtime.topologyRevision, source.runtime.topologyRevision)
    }

    func testVertexTranslateCandidateIsAbsoluteFromStartAcrossUpdates() throws {
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.replace, vertexIDs: [0, 1]))
        var transaction = try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: .identity)
        let first = try XCTUnwrap(VertexTranslateGeometry.candidate(
            sourceMesh: source, transaction: &transaction, worldDelta: SIMD3(1, 0, 0)))
        let second = try XCTUnwrap(VertexTranslateGeometry.candidate(
            sourceMesh: first, transaction: &transaction, worldDelta: SIMD3(2, 0, 0)))
        XCTAssertEqual(second.vertices[0].position, source.vertices[0].position + SIMD3(2, 0, 0))
        XCTAssertEqual(second.vertices[1].position, source.vertices[1].position + SIMD3(2, 0, 0))
        XCTAssertGreaterThan(second.runtime.revision, first.runtime.revision)
    }

    func testVertexTranslateRejectsEmptyStaleAndNonFiniteRequests() throws {
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        let empty = try VertexSelection(table: table)
        XCTAssertThrowsError(try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: empty, transform: .identity))
        var selected = empty
        XCTAssertTrue(try selected.apply(.add, vertexID: 0))
        let replacement = EditableMesh(vertices: source.vertices, indices: source.indices)
        XCTAssertThrowsError(try VertexTranslateGeometry.begin(
            mesh: replacement, table: table, selection: selected, transform: .identity))
        var transaction = try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selected, transform: .identity)
        XCTAssertThrowsError(try VertexTranslateGeometry.candidate(
            sourceMesh: source, transaction: &transaction,
            worldDelta: SIMD3(.nan, 0, 0)))
    }

    func testVertexTranslateTransactionRejectsRuntimeSelectionAndTransformChanges() throws {
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, vertexID: 0))
        let transaction = try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: .identity)
        XCTAssertTrue(transaction.matches(
            mesh: source, table: table, selection: selection, transform: .identity))
        var vertexEdited = source
        _ = vertexEdited.updatePositions([0: SIMD3(0.1, 0, 0)])
        XCTAssertFalse(transaction.matches(
            mesh: vertexEdited, table: table, selection: selection, transform: .identity))
        var changedSelection = selection
        XCTAssertTrue(try changedSelection.apply(.add, vertexID: 1))
        XCTAssertFalse(transaction.matches(
            mesh: source, table: table, selection: changedSelection, transform: .identity))
        XCTAssertFalse(transaction.matches(
            mesh: source, table: table, selection: selection,
            transform: ObjectTransform(translation: SIMD3(1, 0, 0))))
        let replacement = EditableMesh(vertices: source.vertices, indices: source.indices)
        XCTAssertFalse(transaction.matches(
            mesh: replacement, table: table, selection: selection, transform: .identity))
    }

    func testVertexTranslateWorkingMemoryPreflightIncludesSourceAndPreview() throws {
        let bytes = try VertexTranslateGeometry.estimatedPeakBytes(
            vertexCount: 100, indexCount: 300, selectedCount: 20)
        XCTAssertGreaterThan(bytes, 100 * MemoryLayout<MeshVertex>.stride * 2)
        XCTAssertThrowsError(try VertexTranslateGeometry.estimatedPeakBytes(
            vertexCount: Int.max, indexCount: Int.max, selectedCount: Int.max))
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(selection.selectAll())
        XCTAssertThrowsError(try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selection,
            transform: .identity, memoryLimit: 1))
    }

    func testWorkspaceVertexTranslatePreviewDoesNotMutateProjectAndCancelIsAtomic() throws {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        model.selectAllVertices()
        let mesh = model.mesh, transform = model.objectTransform
        let bytes = try model.projectData(), generation = model.projectMutationGeneration
        let history = (model.undoCount, model.redoCount)
        let start = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: start, cameraDirection: SIMD3(0, 0, -1)))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3(0.8, 0.6, 5), direction: SIMD3(0, 0, -1)),
            cameraDirection: SIMD3(0, 0, -1))
        XCTAssertNotNil(model.vertexTranslatePreviewMesh)
        XCTAssertNotEqual(model.renderedMesh, model.mesh)
        XCTAssertEqual(model.mesh, mesh)
        XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(try model.projectData(), bytes)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        model.cancelTranslationGizmoDrag()
        XCTAssertNil(model.vertexTranslatePreviewMesh)
        XCTAssertEqual(model.renderedMesh, mesh)
        XCTAssertFalse(model.isGizmoDragging)
        XCTAssertEqual(try model.projectData(), bytes)
    }

    func testWorkspaceVertexTranslateCommitRecordsOneUndoAndPreservesTopologyAndSelection() throws {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        let before = model.mesh
        let topology = before.runtime.topologyID
        let topologyRevision = before.runtime.topologyRevision
        let selection = model.vertexSelection
        let start = Ray(origin: SIMD3<Float>(-0.5257, 0.8506, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: start, cameraDirection: SIMD3(0, 0, -1)))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: start.origin + SIMD3(0.5, 0.25, 0), direction: start.direction),
            cameraDirection: SIMD3(0, 0, -1))
        model.endTranslationGizmoDrag()
        XCTAssertEqual(model.undoCount, 1)
        XCTAssertNotEqual(model.mesh.vertices[0].position, before.vertices[0].position)
        XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertEqual(model.mesh.runtime.topologyRevision, topologyRevision)
        XCTAssertEqual(model.mesh.indices, before.indices)
        XCTAssertEqual(model.vertexSelection, selection)
        XCTAssertTrue(model.objectTransform.isIdentity)
        model.undo()
        XCTAssertEqual(model.mesh, before)
        XCTAssertEqual(model.vertexSelection, selection)
        model.redo()
        XCTAssertNotEqual(model.mesh, before)
        XCTAssertEqual(model.vertexSelection, selection)
    }

    func testWorkspaceVertexTranslateNoOpDoesNotRecordHistory() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        model.selectAllVertices()
        let start = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: start, cameraDirection: SIMD3(0, 0, -1)))
        model.updateTranslationGizmoDrag(ray: start, cameraDirection: SIMD3(0, 0, -1))
        model.endTranslationGizmoDrag()
        XCTAssertEqual(model.undoCount, 0)
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.vertexTranslatePreviewMesh)
    }

    func testWorkspaceModeChangeCancelsVertexTranslatePreview() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        model.selectAllVertices()
        let start = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: start, cameraDirection: SIMD3(0, 0, -1)))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3(0.7, 0.5, 5), direction: SIMD3(0, 0, -1)),
            cameraDirection: SIMD3(0, 0, -1))
        XCTAssertNotNil(model.vertexTranslatePreviewMesh)
        model.setInteractionMode(.sculpt)
        XCTAssertNil(model.vertexTranslatePreviewMesh)
        XCTAssertFalse(model.isGizmoDragging)
        XCTAssertEqual(model.undoCount, 0)
    }

    func testVertexTranslateRendererUploadsVerticesWithoutIndicesOrSelectionIDs() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let profiler = PerformanceProfiler()
        guard let renderer = MetalRenderer(view: view, profiler: profiler) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = quad(), table = try MeshVertexTopologyTable.build(mesh: source)
        var selection = try VertexSelection(table: table)
        XCTAssertTrue(try selection.apply(.replace, vertexIDs: [0, 1]))
        renderer.update(mesh: source)
        _ = renderer.updateVertexSelection(
            mesh: source, table: table, selection: selection, hover: VertexHoverState())
        let before = profiler.snapshot()
        let selectionUploads = renderer.vertexSelectionOverlaySelectedUploadCount
        var transaction = try VertexTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: .identity)
        let preview = try XCTUnwrap(VertexTranslateGeometry.candidate(
            sourceMesh: source, transaction: &transaction, worldDelta: SIMD3(0.25, 0, 0)))
        renderer.update(mesh: preview)
        _ = renderer.updateVertexSelection(
            mesh: preview, table: table, selection: selection, hover: VertexHoverState())
        let after = profiler.snapshot()
        XCTAssertEqual(after[.vertexUpload].sampleCount, before[.vertexUpload].sampleCount + 1)
        XCTAssertEqual(after[.indexUpload].sampleCount, before[.indexUpload].sampleCount)
        XCTAssertEqual(renderer.vertexSelectionOverlaySelectedUploadCount, selectionUploads)
    }

    private func assertEqual(
        _ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float = 0.000_01,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }

    private func quad() -> EditableMesh {
        mesh([SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0)], [0,1,2, 0,2,3])
    }
    private func isolatedVertices(_ count: Int) -> EditableMesh {
        mesh((0..<count).map { SIMD3(Float($0), 0, 0) }, [])
    }
    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var value = EditableMesh(vertices: positions.map {
            MeshVertex(position: $0, normal: SIMD3(0,0,1))
        }, indices: indices)
        value.recalculateNormals(recordChange: false)
        return value
    }
}

private final class FaultVertexAllocator: VertexSelectionIDBufferAllocating {
    var failNext = false
    var failCopyNumber: Int?
    private var copyCount = 0
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        if failNext { failNext = false; return nil }
        return device.makeBuffer(length: length, options: .storageModeShared)
    }
    func copy(_ ids: [UInt32], byteCount: Int, to buffer: MTLBuffer) -> Bool {
        copyCount += 1
        if failCopyNumber == copyCount { return false }
        return ids.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress, buffer.length >= byteCount else { return false }
            buffer.contents().copyMemory(from: base, byteCount: byteCount)
            return true
        }
    }
}
