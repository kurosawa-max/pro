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

    func testHoverVersionChangesOnlyWhenValueChanges() {
        let initial = VertexHoverState(vertexID: 1)
        XCTAssertEqual(initial.updating(1).version, initial.version)
        XCTAssertNotEqual(initial.updating(2).version, initial.version)
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

    func testWorkspaceKeepsSelectionAcrossVertexOnlyChange() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        let selected = model.vertexSelection
        model.mesh.vertices[0].position.x += 0.01
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

    func testSelectedVertexSuppressesHover() {
        let model = WorkspaceModel()
        model.setInteractionMode(.vertexSelect)
        XCTAssertTrue(model.applyVertexSelectionHit(0))
        model.clearVertexHover()
        XCTAssertNil(model.vertexHover.vertexID)
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
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        if failNext { failNext = false; return nil }
        return device.makeBuffer(length: length, options: .storageModeShared)
    }
    func copy(_ ids: [UInt32], byteCount: Int, to buffer: MTLBuffer) -> Bool {
        ids.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress, buffer.length >= byteCount else { return false }
            buffer.contents().copyMemory(from: base, byteCount: byteCount)
            return true
        }
    }
}
