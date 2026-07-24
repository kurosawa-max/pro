import XCTest
import MetalKit
import SwiftUI
@testable import Forge3D

@MainActor
final class EdgeSelectionTests: XCTestCase {
    func testCanonicalKeyOrderingIdentityAndSelfEdgeRejection() throws {
        XCTAssertEqual(MeshEdgeKey(7, 2), MeshEdgeKey(2, 7))
        XCTAssertEqual(try XCTUnwrap(MeshEdgeKey(7, 2)).low, 2)
        XCTAssertEqual(try XCTUnwrap(MeshEdgeKey(7, 2)).high, 7)
        XCTAssertNil(MeshEdgeKey(3, 3))
        XCTAssertLessThan(try XCTUnwrap(MeshEdgeKey(0, .max)),
                          try XCTUnwrap(MeshEdgeKey(1, 2)))
    }

    func testSingleTriangleAndQuadBuildCanonicalTables() throws {
        let triangle = try MeshEdgeTable.build(mesh: mesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2]))
        XCTAssertEqual(triangle.edges.count, 3)
        XCTAssertEqual(triangle.boundaryEdgeCount, 3)
        XCTAssertEqual(triangle.manifoldEdgeCount, 0)

        let quad = try MeshEdgeTable.build(mesh: twoTriangleQuad())
        XCTAssertEqual(quad.edges.count, 5)
        XCTAssertEqual(quad.boundaryEdgeCount, 4)
        XCTAssertEqual(quad.manifoldEdgeCount, 1)
        XCTAssertEqual(quad.edgeIDByKey[try XCTUnwrap(MeshEdgeKey(0, 2))].map {
            quad.edges[$0].incidentFaceIDs
        }, [0, 1])
        XCTAssertEqual(quad.edges.map(\.key), quad.edges.map(\.key).sorted())
    }

    func testTableOrderingIgnoresTriangleOrderButFingerprintIncludesFaceIdentity() throws {
        let first = try MeshEdgeTable.build(mesh: twoTriangleQuad())
        let reordered = try MeshEdgeTable.build(mesh: mesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            [0, 2, 3, 0, 1, 2]))
        XCTAssertEqual(first.edges.map(\.key), reordered.edges.map(\.key))
        XCTAssertNotEqual(first.fingerprint, reordered.fingerprint)
        XCTAssertEqual(first.fingerprint,
                       try MeshEdgeTable.build(mesh: twoTriangleQuad()).fingerprint)
    }

    func testTableRejectsInvalidRepeatedAndNonFiniteInputs() {
        XCTAssertThrowsError(try MeshEdgeTable.build(mesh: mesh(
            [SIMD3(0, 0, 0)], [0, 1, 0])))
        XCTAssertThrowsError(try MeshEdgeTable.build(mesh: mesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0)], [0, 0, 1])))
        XCTAssertThrowsError(try MeshEdgeTable.build(mesh: mesh(
            [SIMD3(Float.nan, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], [0, 1, 2])))
    }

    func testMemoryPreflightRunsBeforeTriangleScanAndChecksBoundary() throws {
        let source = twoTriangleQuad()
        let exact = try MeshEdgeTable.estimatedPeakBytes(
            vertexCount: source.vertices.count, indexCount: source.indices.count)
        let rejected = MeshEdgeTableBuildInstrumentation()
        XCTAssertThrowsError(try MeshEdgeTable.build(
            mesh: source, memoryLimit: exact - 1, instrumentation: rejected)) {
            XCTAssertEqual($0 as? EdgeSelectionError, .workingMemoryLimitExceeded)
        }
        XCTAssertEqual(rejected.preflightCount, 1)
        XCTAssertEqual(rejected.triangleScanCount, 0)
        let accepted = MeshEdgeTableBuildInstrumentation()
        XCTAssertNoThrow(try MeshEdgeTable.build(
            mesh: source, memoryLimit: exact, instrumentation: accepted))
        XCTAssertEqual(accepted.triangleScanCount, 1)
        XCTAssertThrowsError(try MeshEdgeTable.estimatedPeakBytes(
            vertexCount: Int.max, indexCount: Int.max))
    }

    func testDenseSelectionOperationsAndNoOpVersion() throws {
        let table = try MeshEdgeTable.build(mesh: twoTriangleQuad())
        var selection = try EdgeSelection(table: table)
        let emptyVersion = selection.version
        XCTAssertFalse(selection.clear())
        XCTAssertEqual(selection.version, emptyVersion)
        XCTAssertTrue(try selection.apply(.replace, edgeID: 2))
        let oneVersion = selection.version
        XCTAssertFalse(try selection.apply(.replace, edgeID: 2))
        XCTAssertEqual(selection.version, oneVersion)
        XCTAssertFalse(try selection.apply(.add, edgeID: 2))
        XCTAssertTrue(try selection.apply(.add, edgeID: 4))
        XCTAssertTrue(try selection.apply(.remove, edgeID: 2))
        XCTAssertTrue(try selection.apply(.toggle, edgeID: 4))
        XCTAssertEqual(selection.selectedCount, 0)
        XCTAssertTrue(selection.selectAll())
        XCTAssertEqual(selection.selectedEdgeIDs(), Array(table.edges.indices))
        XCTAssertTrue(selection.invert())
        XCTAssertEqual(selection.selectedCount, 0)
    }

    func testDenseSelectionMasksFinalWord() throws {
        let source = fanMesh(triangleCount: 22) // 44 perimeter/radial edges, over one partial word.
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(selection.selectAll())
        XCTAssertEqual(selection.selectedCount, table.edges.count)
        XCTAssertEqual(selection.selectedEdgeIDs().last, table.edges.count - 1)
        XCTAssertTrue(selection.invert())
        XCTAssertEqual(selection.selectedEdgeIDs(), [])
    }

    func testConnectedUsesSharedVertexIDsAndStaysLinear() throws {
        let table = try MeshEdgeTable.build(mesh: twoTriangleQuad())
        let instrumentation = EdgeConnectedInstrumentation()
        let connected = try EdgeSelectionConnectivity.connectedEdgeIDs(
            table: table, seeds: [0], instrumentation: instrumentation)
        XCTAssertEqual(connected, Array(table.edges.indices))
        XCTAssertEqual(instrumentation.visitedEdgeCount, table.edges.count)

        let detached = try MeshEdgeTable.build(mesh: mesh(
            [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
             SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0)],
            [0, 1, 2, 3, 4, 5]))
        let firstComponent = try EdgeSelectionConnectivity.connectedEdgeIDs(
            table: detached, seeds: [0])
        XCTAssertEqual(firstComponent.count, 3)
    }

    func testConnectedCanonicalizesDuplicateUnsortedSeeds() throws {
        let table = try MeshEdgeTable.build(mesh: twoTriangleQuad())
        let instrumentation = EdgeConnectedInstrumentation()
        let result = try EdgeSelectionConnectivity.connectedEdgeIDs(
            table: table, seeds: [4, 0, 4, 0], instrumentation: instrumentation)
        XCTAssertEqual(result, Array(table.edges.indices))
        XCTAssertEqual(instrumentation.visitedEdgeCount, table.edges.count)
    }

    func testNearPlaneProjectionVisibleAndClipsEitherEndpoint() {
        let viewport = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            EdgeClipProjection.projectSegment(
                SIMD4(-0.5, 0, 0.5, 1), SIMD4(0.5, 0, 0.5, 1), viewport: viewport),
            .visible(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 50)))

        guard case .visible(let clippedAStart, let clippedAEnd) =
            EdgeClipProjection.projectSegment(
                SIMD4(-1, 0, -1, 1), SIMD4(1, 0, 1, 1), viewport: viewport) else {
            return XCTFail("Expected A endpoint to clip to the Metal near plane")
        }
        XCTAssertEqual(clippedAStart.x, 100, accuracy: 0.001)
        XCTAssertEqual(clippedAEnd.x, 200, accuracy: 0.001)

        guard case .visible(let clippedBStart, let clippedBEnd) =
            EdgeClipProjection.projectSegment(
                SIMD4(-1, 0, 1, 1), SIMD4(1, 0, -1, 1), viewport: viewport) else {
            return XCTFail("Expected B endpoint to clip to the Metal near plane")
        }
        XCTAssertEqual(clippedBStart.x, 0, accuracy: 0.001)
        XCTAssertEqual(clippedBEnd.x, 100, accuracy: 0.001)
    }

    func testNearPlaneProjectionClassifiesInvisibleDegenerateAndInvalidSegments() {
        let viewport = CGSize(width: 100, height: 100)
        XCTAssertEqual(EdgeClipProjection.projectSegment(
            SIMD4(-1, 0, -1, 1), SIMD4(1, 0, -0.1, 1), viewport: viewport), .clippedOut)
        XCTAssertEqual(EdgeClipProjection.projectSegment(
            SIMD4(0, 0, 0, 1), SIMD4(0, 0, 1, 1), viewport: viewport), .clippedOut)
        XCTAssertEqual(EdgeClipProjection.projectSegment(
            SIMD4(0, 0, 1, 0), SIMD4(1, 0, 1, 1), viewport: viewport), .clippedOut)
        XCTAssertEqual(EdgeClipProjection.projectSegment(
            SIMD4(Float.nan, 0, 1, 1), SIMD4(1, 0, 1, 1), viewport: viewport), .invalid)
        XCTAssertEqual(EdgeClipProjection.projectSegment(
            SIMD4(0, 0, 1, 1), SIMD4(1, 0, 1, 1),
            viewport: CGSize(width: 0, height: 100)), .invalid)
    }

    func testNearPlaneProjectionHandlesExtremePerspectiveWithoutNonFiniteOutput() {
        guard case .visible(let start, let end) = EdgeClipProjection.projectSegment(
            SIMD4(-1_000, 20, 1, 10_000), SIMD4(1_000, -20, 1, 10_000),
            viewport: CGSize(width: 3_000, height: 2_000)) else {
            return XCTFail("Expected finite projected segment")
        }
        XCTAssertTrue(start.x.isFinite && start.y.isFinite)
        XCTAssertTrue(end.x.isFinite && end.y.isFinite)
    }

    func testOverlayThicknessConvertsPointsToPixelsForDisplayScale() throws {
        for scale: Float in [1, 2, 3] {
            let selected = try XCTUnwrap(try? EdgeSelectionOverlayMetrics
                .thicknessPixels(thicknessPoints: 2.5, displayScale: scale).get())
            let hover = try XCTUnwrap(try? EdgeSelectionOverlayMetrics
                .thicknessPixels(thicknessPoints: 5, displayScale: scale).get())
            XCTAssertEqual(selected, 2.5 * scale)
            XCTAssertEqual(hover, 5 * scale)
        }
        XCTAssertThrowsError(try EdgeSelectionOverlayMetrics
            .thicknessPixels(thicknessPoints: 2.5, displayScale: 0).get())
        XCTAssertThrowsError(try EdgeSelectionOverlayMetrics
            .thicknessPixels(thicknessPoints: 2.5, displayScale: .nan).get())
    }

    func testOverlayFailureNotificationIsDeduplicatedAndSuccessClearsIt() {
        let model = WorkspaceModel()
        model.handleEdgeSelectionOverlayUpdate(.unavailable(.allocationFailed))
        let firstStatus = model.status
        model.handleEdgeSelectionOverlayUpdate(.unavailable(.allocationFailed))
        XCTAssertEqual(model.status, firstStatus)
        XCTAssertNotNil(model.edgeSelectionError)
        model.handleEdgeSelectionOverlayUpdate(.updated)
        XCTAssertNil(model.edgeSelectionError)
    }

    func testEdgeSelectionPanelFitsCompactRegularAndAccessibilityLayouts() {
        let model = WorkspaceModel()
        model.setInteractionMode(.edgeSelect)
        for width: CGFloat in [320, 744, 1_024] {
            let root = EdgeSelectionPanel(model: model)
                .environment(\.dynamicTypeSize, .accessibility3)
            let host = UIHostingController(rootView: root)
            let size = host.sizeThatFits(in: CGSize(width: width, height: 700))
            XCTAssertLessThanOrEqual(size.width, width + 0.5)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testOverlayAllocationFailureClearsCountsAndRetriesAtomically() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultInjectingEdgePairAllocator()
        guard let renderer = MetalRenderer(
            view: view, profiler: nil, edgeSelectionBufferAllocator: allocator) else {
            return XCTFail("Renderer unavailable")
        }
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        allocator.failAllocationNumber = 2
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2),
            .unavailable(.allocationFailed))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 0)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 0)
        XCTAssertNil(renderer.edgeSelectionOverlayUploadedKey)

        allocator.failAllocationNumber = nil
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2), .updated)
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 1)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 1)
        XCTAssertNotNil(renderer.edgeSelectionOverlayUploadedKey)
    }

    func testOverlayCopyFailureDoesNotInstallStaleKeyAndCanRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultInjectingEdgePairAllocator()
        guard let renderer = MetalRenderer(
            view: view, profiler: nil, edgeSelectionBufferAllocator: allocator) else {
            return XCTFail("Renderer unavailable")
        }
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        allocator.failCopyNumber = 1
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1),
            .unavailable(.copyFailed))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 0)
        XCTAssertNil(renderer.edgeSelectionOverlayUploadedKey)

        allocator.failCopyNumber = nil
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1), .updated)
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 1)
    }

    func testScreenDistanceAndVisibleTrianglePicking() throws {
        let source = mesh(
            [SIMD3(-0.5, -0.5, 0), SIMD3(0.5, -0.5, 0), SIMD3(0, 0.5, 0)],
            [0, 1, 2])
        let table = try MeshEdgeTable.build(mesh: source)
        let cache = MeshBVHCache()
        XCTAssertNotNil(cache.index(for: source))
        let ray = Ray(origin: SIMD3(0, -0.49, 1), direction: SIMD3(0, 0, -1))
        let hit = MeshEdgePicker.pick(
            worldRay: ray, screenPoint: CGPoint(x: 100, y: 149),
            viewportSize: CGSize(width: 200, height: 200), mesh: source,
            transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache)
        guard case .hit(let edgeID, let key) = hit else {
            return XCTFail("Expected visible edge hit")
        }
        XCTAssertEqual(key, MeshEdgeKey(0, 1))
        XCTAssertEqual(edgeID, table.edgeIDByKey[key])
        XCTAssertEqual(MeshEdgePicker.pointSegmentDistance(
            CGPoint(x: 5, y: 4), CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 4)
    }

    func testPickingMissAndUnavailableDoNotSelect() throws {
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        let cache = MeshBVHCache()
        XCTAssertEqual(MeshEdgePicker.pick(
            worldRay: Ray(origin: SIMD3(10, 10, 1), direction: SIMD3(0, 0, -1)),
            screenPoint: .zero, viewportSize: CGSize(width: 100, height: 100),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache), .miss)
        let changed = EditableMesh(vertices: source.vertices, indices: source.indices)
        XCTAssertEqual(MeshEdgePicker.pick(
            worldRay: Ray(origin: SIMD3(0, 0, 1), direction: SIMD3(0, 0, -1)),
            screenPoint: .zero, viewportSize: CGSize(width: 100, height: 100),
            mesh: changed, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache), .unavailable)
    }

    func testWorkspaceSelectionIsIndependentAndTopologyBound() throws {
        let model = WorkspaceModel()
        model.mesh = twoTriangleQuad()
        model.setInteractionMode(.faceSelect)
        _ = model.applyFaceSelectionHit(0)
        let faceSelection = model.faceSelection
        model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0))
        XCTAssertEqual(model.faceSelection, faceSelection)
        let selected = model.edgeSelection
        var sculpted = model.mesh
        _ = sculpted.updatePositions([0: SIMD3(-0.1, 0, 0)])
        model.mesh = sculpted
        XCTAssertEqual(model.edgeSelection, selected)
        model.mesh = EditableMesh.icosphere(subdivisions: 0)
        XCTAssertEqual(model.edgeSelection.selectedCount, 0)
        XCTAssertNil(model.hoveredEdgeID)
    }

    func testEdgeOperationsDoNotMutateProjectHistoryOrBytes() throws {
        let model = WorkspaceModel()
        model.mesh = twoTriangleQuad()
        model.setInteractionMode(.edgeSelect)
        let before = try model.projectData()
        let generation = model.projectMutationGeneration
        let history = (model.undoCount, model.redoCount)
        XCTAssertTrue(model.applyEdgeSelectionHit(0))
        model.selectAllEdges()
        model.invertEdgeSelection()
        model.clearEdgeSelection()
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, history.0)
        XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(try model.projectData(), before)
    }

    func testRendererDrawOrderPlacesEdgeBeforeDiagnostics() {
        XCTAssertEqual(MetalRenderer.drawOrder,
                       [.mesh, .faceSelection, .edgeSelection, .diagnostics, .gizmo])
        XCTAssertEqual(MemoryLayout<EdgeSelectionOverlayUniforms>.stride, 160)
    }

    private func twoTriangleQuad() -> EditableMesh {
        mesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
             [0, 1, 2, 0, 2, 3])
    }

    private func fanMesh(triangleCount: Int) -> EditableMesh {
        var points = [SIMD3<Float>(0, 0, 0)]
        for index in 0...triangleCount {
            let angle = Float(index) / Float(triangleCount) * .pi * 2
            points.append(SIMD3(cos(angle), sin(angle), 0))
        }
        var indices: [UInt32] = []
        for index in 0..<triangleCount {
            indices.append(contentsOf: [0, UInt32(index + 1), UInt32(index + 2)])
        }
        return mesh(points, indices)
    }

    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var value = EditableMesh(
            vertices: positions.map { MeshVertex(position: $0, normal: SIMD3(0, 0, 1)) },
            indices: indices)
        value.recalculateNormals(recordChange: false)
        return value
    }
}

private final class FaultInjectingEdgePairAllocator: EdgeSelectionPairBufferAllocating {
    var failAllocationNumber: Int?
    var failCopyNumber: Int?
    private var allocationCount = 0
    private var copyCount = 0

    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        allocationCount += 1
        if allocationCount == failAllocationNumber { return nil }
        return device.makeBuffer(length: length, options: .storageModeShared)
    }

    func copy(_ pairs: [SIMD2<UInt32>], byteCount: Int, to buffer: MTLBuffer) -> Bool {
        copyCount += 1
        if copyCount == failCopyNumber { return false }
        return pairs.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, buffer.length >= byteCount else { return false }
            buffer.contents().copyMemory(from: base, byteCount: byteCount)
            return true
        }
    }
}
