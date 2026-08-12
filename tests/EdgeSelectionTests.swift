import XCTest
import Combine
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
        XCTAssertEqual(EdgeClipProjection.metalNearPlaneZ, 0)
        XCTAssertEqual(EdgeClipProjection.minimumW, 1e-6)
        XCTAssertEqual(EdgeClipProjection.clippedOutClipPosition, SIMD4(2, 2, 2, 1))
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
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .unavailable(.allocationFailed), hover: .unchanged))
        let firstStatus = model.status
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .unavailable(.allocationFailed), hover: .unchanged))
        XCTAssertEqual(model.status, firstStatus)
        XCTAssertNotNil(model.edgeSelectionError)
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .updated, hover: .unchanged))
        XCTAssertNil(model.edgeSelectionError)
        XCTAssertEqual(model.status, "Selected 0 of \(model.totalEdgeCount) edges")
    }

    func testUnchangedOverlaySummaryDoesNotRepublishNilError() {
        let model = WorkspaceModel()
        var publicationCount = 0
        let observation = model.objectWillChange.sink { publicationCount += 1 }
        model.handleEdgeSelectionOverlayUpdate(.unchanged)
        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }
    func testOverlayComponentErrorsRecoverIndependentlyWithoutClearingRegularErrors() {
        let model = WorkspaceModel()
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .unavailable(.allocationFailed),
            hover: .unavailable(.copyFailed)))
        XCTAssertTrue(model.edgeSelectionError?.contains("selected") == true)
        XCTAssertTrue(model.edgeSelectionError?.contains("hover") == true)
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .updated, hover: .unchanged))
        XCTAssertFalse(model.edgeSelectionError?.contains("selected") == true)
        XCTAssertTrue(model.edgeSelectionError?.contains("hover") == true)
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .unchanged, hover: .updated))
        XCTAssertNil(model.edgeSelectionError)

        model.status = "Unrelated workspace status"
        model.handleEdgeSelectionOverlayUpdate(EdgeSelectionOverlayUpdateSummary(
            selected: .updated, hover: .unchanged))
        XCTAssertEqual(model.status, "Unrelated workspace status")
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
            EdgeSelectionOverlayUpdateSummary(
                selected: .cleared, hover: .unavailable(.allocationFailed)))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 0)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 0)
        XCTAssertNil(renderer.edgeSelectionOverlaySelectedUploadedKey)
        XCTAssertNil(renderer.edgeSelectionOverlayHoverUploadedKey)
        XCTAssertFalse(renderer.edgeSelectionOverlayHasSelectedBuffer)
        XCTAssertFalse(renderer.edgeSelectionOverlayHasHoverBuffer)

        allocator.failAllocationNumber = nil
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2),
            EdgeSelectionOverlayUpdateSummary(selected: .updated, hover: .updated))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 1)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 1)
        XCTAssertNotNil(renderer.edgeSelectionOverlaySelectedUploadedKey)
        XCTAssertNotNil(renderer.edgeSelectionOverlayHoverUploadedKey)
        XCTAssertTrue(renderer.edgeSelectionOverlayHasSelectedBuffer)
        XCTAssertTrue(renderer.edgeSelectionOverlayHasHoverBuffer)
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
            EdgeSelectionOverlayUpdateSummary(
                selected: .unavailable(.copyFailed), hover: .cleared))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 0)
        XCTAssertNil(renderer.edgeSelectionOverlaySelectedUploadedKey)

        allocator.failCopyNumber = nil
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1),
            EdgeSelectionOverlayUpdateSummary(selected: .updated, hover: .cleared))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 1)
    }

    func testHoverOnlyUpdatesNeverRegenerateSelectedPairsAndNilClearsHover() throws {
        let (renderer, source, table, allocator) = try makeInstrumentedEdgeRenderer()
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        let selectionVersion = selection.version
        _ = renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2)
        let selectedCounters = (
            renderer.edgeSelectionOverlaySelectedPairGenerationCount,
            renderer.edgeSelectionOverlaySelectedAllocationCount,
            renderer.edgeSelectionOverlaySelectedCopyCount,
            renderer.edgeSelectionOverlaySelectedUploadCount)

        for hoverID in [2, 3, 4] {
            XCTAssertEqual(renderer.updateEdgeSelection(
                mesh: source, table: table, selection: selection, hoveredEdgeID: hoverID,
                drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2),
                EdgeSelectionOverlayUpdateSummary(selected: .unchanged, hover: .updated))
        }
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedPairGenerationCount, selectedCounters.0)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedAllocationCount, selectedCounters.1)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedCopyCount, selectedCounters.2)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, selectedCounters.3)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, 4)
        XCTAssertEqual(selection.version, selectionVersion)
        XCTAssertEqual(allocator.allocationCount, 5)

        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2),
            EdgeSelectionOverlayUpdateSummary(selected: .unchanged, hover: .cleared))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 1)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 0)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, 1)
    }

    func testSelectionOnlyUpdateDoesNotRegenerateHoverPairs() throws {
        let (renderer, source, table, _) = try makeInstrumentedEdgeRenderer()
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        _ = renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2)
        let hoverCounters = (
            renderer.edgeSelectionOverlayHoverPairGenerationCount,
            renderer.edgeSelectionOverlayHoverAllocationCount,
            renderer.edgeSelectionOverlayHoverCopyCount,
            renderer.edgeSelectionOverlayHoverUploadCount)
        XCTAssertTrue(try selection.apply(.add, edgeID: 2))
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 200, height: 200), displayScale: 2),
            EdgeSelectionOverlayUpdateSummary(selected: .updated, hover: .unchanged))
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverPairGenerationCount, hoverCounters.0)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverAllocationCount, hoverCounters.1)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCopyCount, hoverCounters.2)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, hoverCounters.3)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 1)
    }

    func testComponentFailurePreservesUnchangedPeerAndRetries() throws {
        let (renderer, source, table, allocator) = try makeInstrumentedEdgeRenderer()
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        _ = renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)

        allocator.failAllocationNumber = allocator.allocationCount + 1
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 2,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1),
            EdgeSelectionOverlayUpdateSummary(
                selected: .unchanged, hover: .unavailable(.allocationFailed)))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 1)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 0)
        XCTAssertNotNil(renderer.edgeSelectionOverlaySelectedUploadedKey)
        XCTAssertTrue(renderer.edgeSelectionOverlayHasSelectedBuffer)
        XCTAssertFalse(renderer.edgeSelectionOverlayHasHoverBuffer)
        allocator.failAllocationNumber = nil
        allocator.beforeAllocation = {
            XCTAssertTrue(renderer.edgeSelectionOverlayHasSelectedBuffer)
            XCTAssertFalse(renderer.edgeSelectionOverlayHasHoverBuffer)
        }
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 2,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1),
            EdgeSelectionOverlayUpdateSummary(selected: .unchanged, hover: .updated))
        allocator.beforeAllocation = nil

        XCTAssertTrue(try selection.apply(.add, edgeID: 3))
        allocator.failAllocationNumber = allocator.allocationCount + 1
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 2,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1),
            EdgeSelectionOverlayUpdateSummary(
                selected: .unavailable(.allocationFailed), hover: .unchanged))
        XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 0)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 1)
        XCTAssertFalse(renderer.edgeSelectionOverlayHasSelectedBuffer)
        XCTAssertTrue(renderer.edgeSelectionOverlayHasHoverBuffer)
        XCTAssertNil(renderer.edgeSelectionOverlaySelectedUploadedKey)
        XCTAssertNotNil(renderer.edgeSelectionOverlayHoverUploadedKey)
        allocator.failAllocationNumber = nil
        allocator.beforeAllocation = {
            XCTAssertFalse(renderer.edgeSelectionOverlayHasSelectedBuffer)
            XCTAssertTrue(renderer.edgeSelectionOverlayHasHoverBuffer)
        }
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 2,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1),
            EdgeSelectionOverlayUpdateSummary(selected: .updated, hover: .unchanged))
        allocator.beforeAllocation = nil
    }

    func testInvalidInputsReleaseBothOverlayBuffersAndCanRecover() throws {
        let (renderer, source, table, _) = try makeInstrumentedEdgeRenderer()
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))

        func install() {
            _ = renderer.updateEdgeSelection(
                mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
                drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
            XCTAssertTrue(renderer.edgeSelectionOverlayHasSelectedBuffer)
            XCTAssertTrue(renderer.edgeSelectionOverlayHasHoverBuffer)
        }
        func assertReleased() {
            XCTAssertFalse(renderer.edgeSelectionOverlayHasSelectedBuffer)
            XCTAssertFalse(renderer.edgeSelectionOverlayHasHoverBuffer)
            XCTAssertEqual(renderer.edgeSelectionOverlayEdgeCount, 0)
            XCTAssertEqual(renderer.edgeSelectionOverlayHoverCount, 0)
            XCTAssertNil(renderer.edgeSelectionOverlaySelectedUploadedKey)
            XCTAssertNil(renderer.edgeSelectionOverlayHoverUploadedKey)
            XCTAssertTrue(selection.contains(0))
        }

        install()
        _ = renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: .zero, displayScale: 1)
        assertReleased()

        install()
        _ = renderer.updateEdgeSelection(
            mesh: source, table: nil, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        assertReleased()

        install()
        let replacement = EditableMesh(vertices: source.vertices, indices: source.indices)
        _ = renderer.updateEdgeSelection(
            mesh: replacement, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        assertReleased()

        install()
        let otherMesh = EditableMesh(vertices: source.vertices, indices: source.indices)
        let otherTable = try MeshEdgeTable.build(mesh: otherMesh)
        var staleSelection = try EdgeSelection(table: otherTable)
        XCTAssertTrue(try staleSelection.apply(.add, edgeID: 0))
        _ = renderer.updateEdgeSelection(
            mesh: source, table: table, selection: staleSelection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        assertReleased()

        install()
    }
    func testCameraTransformAndSculptReuseBothPairBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let profiler = PerformanceProfiler()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultInjectingEdgePairAllocator()
        guard let renderer = MetalRenderer(
            view: view, profiler: profiler, edgeSelectionBufferAllocator: allocator) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        renderer.update(mesh: source)
        _ = renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        let selectedUploads = renderer.edgeSelectionOverlaySelectedUploadCount
        let hoverUploads = renderer.edgeSelectionOverlayHoverUploadCount
        let meshUploads = profiler.snapshot()

        renderer.camera.yaw += 0.2
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1), .unchanged)
        renderer.objectTransform = ObjectTransform(
            translation: SIMD3(1, 2, 3), rotation: SIMD4(0, 0, 0, 1),
            scale: SIMD3(repeating: 1))
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: source, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1), .unchanged)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount,
                       meshUploads[.vertexUpload].sampleCount)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount,
                       meshUploads[.indexUpload].sampleCount)

        var sculpted = source
        _ = sculpted.updatePositions([0: SIMD3(-0.1, 0, 0)])
        renderer.update(mesh: sculpted)
        XCTAssertEqual(renderer.updateEdgeSelection(
            mesh: sculpted, table: table, selection: selection, hoveredEdgeID: 1,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1), .unchanged)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, selectedUploads)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, hoverUploads)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount,
                       meshUploads[.vertexUpload].sampleCount + 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount,
                       meshUploads[.indexUpload].sampleCount)
        XCTAssertTrue(selection.contains(0))
    }

    func testPickerNearPlaneIntegrationSkipsOnlyClippedEdges() throws {
        let source = mesh(
            [SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, -0.5, 0.5), SIMD3(0, 0.5, 0.5)],
            [0, 1, 2])
        let table = try MeshEdgeTable.build(mesh: source)
        let cache = MeshBVHCache()
        let result = MeshEdgePicker.pick(
            worldRay: Ray(origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, -1)),
            screenPoint: CGPoint(x: 125, y: 100),
            viewportSize: CGSize(width: 200, height: 200),
            mesh: source, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: table, cache: cache, threshold: 80)
        guard case .hit = result else { return XCTFail("Visible near-plane edge should remain pickable") }

        let behind = mesh(
            [SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, -0.5, -0.5), SIMD3(0, 0.5, -0.5)],
            [0, 1, 2])
        XCTAssertEqual(MeshEdgePicker.pick(
            worldRay: Ray(origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, -1)),
            screenPoint: CGPoint(x: 100, y: 100),
            viewportSize: CGSize(width: 200, height: 200),
            mesh: behind, transform: .identity, viewProjection: matrix_identity_float4x4,
            table: try MeshEdgeTable.build(mesh: behind), cache: MeshBVHCache()), .miss)

        var invalidMatrix = matrix_identity_float4x4
        invalidMatrix.columns.0.x = .nan
        XCTAssertEqual(MeshEdgePicker.pick(
            worldRay: Ray(origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, -1)),
            screenPoint: CGPoint(x: 100, y: 100),
            viewportSize: CGSize(width: 200, height: 200),
            mesh: source, transform: .identity, viewProjection: invalidMatrix,
            table: table, cache: cache), .unavailable)
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
                       [.mesh, .faceSelection, .edgeSelection, .vertexSelection, .diagnostics, .gizmo])
        XCTAssertEqual(MemoryLayout<EdgeSelectionOverlayUniforms>.stride, 160)
    }

    func testEdgeTranslateDeduplicatesEndpointsAndUsesLocalAABBCenter() throws {
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        let first = try XCTUnwrap(table.edgeIDByKey[try XCTUnwrap(MeshEdgeKey(0, 2))])
        let second = try XCTUnwrap(table.edgeIDByKey[try XCTUnwrap(MeshEdgeKey(0, 1))])
        XCTAssertTrue(try selection.apply(.add, edgeID: first))
        XCTAssertTrue(try selection.apply(.add, edgeID: second))
        XCTAssertEqual(try EdgeTranslateGeometry.affectedVertexIDs(table: table, selection: selection), [0, 1, 2])
        let pivot = try EdgeTranslateGeometry.pivot(
            mesh: source, table: table, selection: selection, transform: .identity)
        XCTAssertEqual(pivot.local, SIMD3<Float>(0.5, 0.5, 0))
        XCTAssertEqual(pivot.world, pivot.local)
    }

    func testEdgeTranslateUsesAbsoluteStartPositionsAndWorldDirectionVector() throws {
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        let transform = ObjectTransform(
            translation: SIMD3<Float>(1_000_000, -2_000_000, 3_000_000),
            rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)).vector,
            scale: SIMD3<Float>(2, 3, 4))
        var transaction = try EdgeTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: transform,
            projectSessionID: UUID(), projectGeneration: MutationGeneration())
        let first = try XCTUnwrap(try EdgeTranslateGeometry.candidate(
            sourceMesh: source, transaction: &transaction, worldDelta: SIMD3<Float>(3, 0, 0)))
        let second = try XCTUnwrap(try EdgeTranslateGeometry.candidate(
            sourceMesh: first, transaction: &transaction, worldDelta: SIMD3<Float>(6, 0, 0)))
        for (offset, id) in transaction.vertexIDs.enumerated() {
            XCTAssertEqual(second.vertices[Int(id)].position,
                           transaction.startPositions[offset] + transaction.localDelta)
        }
        XCTAssertEqual(transaction.worldDelta, SIMD3<Float>(6, 0, 0))
        XCTAssertTrue(second.vertices.allSatisfy { $0.position.allFinite && $0.normal.allFinite })
    }

    func testEdgeTranslateStaleSelectionNoOpAndMemoryPreflight() throws {
        let source = twoTriangleQuad()
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertThrowsError(try EdgeTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: .identity,
            projectSessionID: UUID(), projectGeneration: MutationGeneration())) {
            XCTAssertEqual($0 as? EdgeTranslateError, .emptySelection)
        }
        XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        var transaction = try EdgeTranslateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: .identity,
            projectSessionID: UUID(), projectGeneration: MutationGeneration())
        XCTAssertNil(try EdgeTranslateGeometry.candidate(
            sourceMesh: source, transaction: &transaction, worldDelta: .zero))
        XCTAssertThrowsError(try EdgeTranslateGeometry.estimatedPeakBytes(
            vertexCount: Int.max, indexCount: Int.max,
            selectedEdgeCount: Int.max, affectedVertexCount: Int.max))
    }

    func testEdgeTranslateRepeatedIdenticalUpdateRemainsAbsoluteFromStart() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        var transaction = try EdgeTranslateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: UUID(), projectGeneration: MutationGeneration())
        let delta = SIMD3<Float>(0.4, -0.2, 0.1)
        let first = try XCTUnwrap(try EdgeTranslateGeometry.candidate(sourceMesh: source, transaction: &transaction, worldDelta: delta))
        let second = try XCTUnwrap(try EdgeTranslateGeometry.candidate(sourceMesh: source, transaction: &transaction, worldDelta: delta))
        let third = try XCTUnwrap(try EdgeTranslateGeometry.candidate(sourceMesh: source, transaction: &transaction, worldDelta: delta))
        XCTAssertEqual(first, second); XCTAssertEqual(second, third)
    }

    func testEdgeTranslateUpdateSequenceEqualsFreshFinalDelta() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(selection.selectAll())
        let session = UUID(), generation = MutationGeneration()
        var sequenced = try EdgeTranslateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: session, projectGeneration: generation)
        for delta in [SIMD3<Float>(0.1,0,0), SIMD3(0.2,0.1,0), SIMD3(0.4,0.3,-0.2)] {
            _ = try EdgeTranslateGeometry.candidate(sourceMesh: source, transaction: &sequenced, worldDelta: delta)
        }
        var fresh = try EdgeTranslateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: session, projectGeneration: generation)
        let final = SIMD3<Float>(0.4,0.3,-0.2)
        XCTAssertEqual(try EdgeTranslateGeometry.candidate(sourceMesh: source, transaction: &sequenced, worldDelta: final),
                       try EdgeTranslateGeometry.candidate(sourceMesh: source, transaction: &fresh, worldDelta: final))
    }

    func testEdgeTranslateChangedThenRestoredSelectionRemainsStale() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        let session = UUID(), generation = MutationGeneration()
        let transaction = try EdgeTranslateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: session, projectGeneration: generation)
        XCTAssertTrue(try selection.apply(.add, edgeID: 1)); XCTAssertTrue(try selection.apply(.remove, edgeID: 1))
        XCTAssertEqual(selection.selectedEdgeIDs(), [0])
        XCTAssertFalse(transaction.matches(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: session, projectGeneration: generation))
    }

    func testEdgeTranslateMemoryExactBoundaryAndConservativePreflight() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(selection.selectAll())
        let required = try EdgeTranslateGeometry.estimatedPeakBytes(vertexCount: source.vertices.count,
            indexCount: source.indices.count, selectedEdgeCount: selection.selectedCount,
            affectedVertexCount: source.vertices.count)
        XCTAssertNoThrow(try EdgeTranslateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: UUID(), projectGeneration: MutationGeneration(), memoryLimit: required))
        XCTAssertThrowsError(try EdgeTranslateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: UUID(), projectGeneration: MutationGeneration(), memoryLimit: required - 1))
    }

    func testEdgeTranslatePreparedBeginResolvesEachConflictIndependently() throws {
        for conflicts in [(true,false,false), (false,true,false), (false,false,true)] {
            let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
            model.installEdgeTranslateBeginConflictsForTesting(sculpt: conflicts.0, transformPanel: conflicts.1, objectMove: conflicts.2)
            let ray = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
            XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray, cameraDirection: SIMD3(0,0,-1)))
            XCTAssertTrue(model.edgeTranslateTransactionActiveForTesting)
            XCTAssertFalse(model.isStrokeActive); XCTAssertFalse(model.isTransformPanelEditing)
            model.cancelTranslationGizmoDrag()
        }
    }

    func testEdgeTranslateLateBeginFailurePreservesEachConflict() throws {
        for conflicts in [(true,false,false), (false,true,false), (false,false,true)] {
            let model = WorkspaceModel(edgeTranslateFailureInjector: .init { $0 == .beginCommitBoundary })
            model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
            model.installEdgeTranslateBeginConflictsForTesting(sculpt: conflicts.0, transformPanel: conflicts.1, objectMove: conflicts.2)
            let mesh = model.mesh, transform = model.objectTransform, selection = model.edgeSelection
            let generation = model.projectMutationGeneration, status = model.status
            let ray = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
            XCTAssertFalse(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray, cameraDirection: SIMD3(0,0,-1)))
            XCTAssertEqual(model.mesh, mesh); XCTAssertEqual(model.objectTransform, transform)
            XCTAssertEqual(model.edgeSelection, selection); XCTAssertEqual(model.projectMutationGeneration, generation)
            XCTAssertEqual(model.status, status); XCTAssertEqual(model.isStrokeActive, conflicts.0)
            XCTAssertEqual(model.isTransformPanelEditing, conflicts.1)
            XCTAssertEqual(model.translationGizmoState.isDragging, conflicts.2)
        }
    }

    func testEmptyEdgeSelectionNeverFallsBackToObjectTranslation() {
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect); let transform = model.objectTransform
        let ray = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
        XCTAssertFalse(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray, cameraDirection: SIMD3(0,0,-1)))
        XCTAssertEqual(model.objectTransform, transform); XCTAssertFalse(model.isGizmoDragging)
    }

    func testWorkspaceEdgeTranslatePreviewCommitUndoRedoAndIsolation() throws {
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0))
        let before = model.mesh, transform = model.objectTransform, selection = model.edgeSelection
        let tableFingerprint = try XCTUnwrap(model.meshEdgeTable).fingerprint
        let projectBefore = try model.projectData(), stlBefore = try model.stlData()
        let generation = model.projectMutationGeneration
        let affected = Set(try EdgeTranslateGeometry.affectedVertexIDs(
            table: XCTUnwrap(model.meshEdgeTable), selection: selection).map(Int.init))
        let start = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
        let end = Ray(origin: SIMD3<Float>(0.8,0.6,5), direction: SIMD3<Float>(0,0,-1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
        model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0,0,-1))
        XCTAssertNotNil(model.edgeTranslatePreviewMesh); XCTAssertNotEqual(model.renderedMesh, model.mesh)
        XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.edgeSelection, selection)
        XCTAssertEqual(try model.projectData(), projectBefore)
        XCTAssertThrowsError(try model.stlData()) {
            XCTAssertEqual($0 as? WorkspaceError, .activeEditInProgress)
        }
        model.endTranslationGizmoDrag()
        let committed = model.mesh
        XCTAssertNil(model.edgeTranslatePreviewMesh); XCTAssertFalse(model.edgeTranslateTransactionActiveForTesting)
        XCTAssertTrue(model.lastUndoIsEdgeTranslateForTesting); XCTAssertEqual(model.undoCount, 1)
        XCTAssertEqual(model.projectMutationGeneration.value, generation.value + 1)
        XCTAssertTrue(model.isDirty); XCTAssertEqual(committed.indices, before.indices)
        XCTAssertEqual(committed.runtime.topologyID, before.runtime.topologyID)
        XCTAssertEqual(committed.runtime.topologyRevision, before.runtime.topologyRevision)
        XCTAssertEqual(model.edgeSelection, selection); XCTAssertEqual(model.meshEdgeTable?.fingerprint, tableFingerprint)
        for index in before.vertices.indices where !affected.contains(index) {
            XCTAssertEqual(committed.vertices[index].position, before.vertices[index].position)
        }
        XCTAssertNotEqual(try model.projectData(), projectBefore); XCTAssertNotEqual(try model.stlData(), stlBefore)
        model.undo(); XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.edgeSelection, selection)
        model.redo(); XCTAssertEqual(model.mesh, committed); XCTAssertEqual(model.edgeSelection, selection)
    }

    func testWorkspaceEdgeTranslateCancelAndZeroDeltaAreNoOps() throws {
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
        let before = model.mesh, transform = model.objectTransform, selection = model.edgeSelection
        let generation = model.projectMutationGeneration, history = (model.undoCount, model.redoCount)
        let start = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
        let end = Ray(origin: SIMD3<Float>(0.8,0.6,5), direction: SIMD3<Float>(0,0,-1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
        model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0,0,-1)); XCTAssertNotNil(model.edgeTranslatePreviewMesh)
        model.cancelTranslationGizmoDrag()
        XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.edgeSelection, selection); XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, history.0); XCTAssertEqual(model.redoCount, history.1)
        XCTAssertNil(model.edgeTranslatePreviewMesh); XCTAssertFalse(model.edgeTranslateTransactionActiveForTesting)
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
        model.updateTranslationGizmoDrag(ray: start, cameraDirection: SIMD3(0,0,-1)); model.endTranslationGizmoDrag()
        XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, history.0); XCTAssertEqual(model.redoCount, history.1)
    }

    func testWorkspaceEdgeTranslatePreviewFailurePointsAreAtomic() throws {
        for point in [EdgeTranslateFailurePoint.candidateAllocation, .normalRebuild,
                      .candidateValidation, .rendererPreparation, .previewBVHPreparation] {
            var active: EdgeTranslateFailurePoint? = point
            let model = WorkspaceModel(edgeTranslateFailureInjector: .init { $0 == active })
            model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
            let before = model.mesh, selection = model.edgeSelection, generation = model.projectMutationGeneration
            let start = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
            let end = Ray(origin: SIMD3<Float>(0.8,0.6,5), direction: SIMD3<Float>(0,0,-1))
            XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
            model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0,0,-1))
            XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.edgeSelection, selection)
            XCTAssertEqual(model.projectMutationGeneration, generation); XCTAssertEqual(model.undoCount, 0)
            XCTAssertNil(model.edgeTranslatePreviewMesh); XCTAssertFalse(model.edgeTranslateTransactionActiveForTesting)
            active = nil
            XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
            model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0,0,-1)); model.endTranslationGizmoDrag()
            XCTAssertEqual(model.undoCount, 1)
        }
    }

    func testWorkspaceEdgeTranslateCommitFailurePointsAreAtomicAndRetryable() throws {
        for point in [EdgeTranslateFailurePoint.commitBVHPreparation, .commitBoundary] {
            var active: EdgeTranslateFailurePoint? = point
            let model = WorkspaceModel(edgeTranslateFailureInjector: .init { $0 == active })
            model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
            let before = model.mesh, selection = model.edgeSelection, generation = model.projectMutationGeneration
            let start = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3<Float>(0,0,-1))
            let end = Ray(origin: SIMD3<Float>(0.8,0.6,5), direction: SIMD3<Float>(0,0,-1))
            XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
            model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0,0,-1)); model.endTranslationGizmoDrag()
            XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.edgeSelection, selection)
            XCTAssertEqual(model.projectMutationGeneration, generation); XCTAssertEqual(model.undoCount, 0)
            active = nil
            XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start, cameraDirection: SIMD3(0,0,-1)))
            model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0,0,-1)); model.endTranslationGizmoDrag()
            XCTAssertEqual(model.undoCount, 1)
        }
    }

    func testWorkspaceEdgeTranslateSourceSnapshotFailureIsAtomicAndRetryable() throws {
        var failSnapshot = true
        let model = WorkspaceModel(edgeTranslateFailureInjector: .init {
            $0 == .sourceSnapshot && failSnapshot
        })
        model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0))
        let before = model.mesh
        let selection = model.edgeSelection
        let generation = model.projectMutationGeneration
        let ray = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertFalse(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: ray, cameraDirection: SIMD3(0, 0, -1)))
        XCTAssertEqual(model.mesh, before)
        XCTAssertEqual(model.edgeSelection, selection)
        XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(model.undoCount, 0)
        XCTAssertNil(model.edgeTranslatePreviewMesh)
        XCTAssertFalse(model.edgeTranslateTransactionActiveForTesting)
        failSnapshot = false
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: ray, cameraDirection: SIMD3(0, 0, -1)))
        model.cancelTranslationGizmoDrag()
    }

    func testWorkspaceEdgeTranslateRendererUploadsOnlyVerticesAndZeroDeltaSkips() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let profiler = PerformanceProfiler()
        guard let renderer = MetalRenderer(view: view, profiler: profiler) else {
            throw XCTSkip("Renderer unavailable")
        }
        let model = WorkspaceModel()
        model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0))
        let table = try XCTUnwrap(model.meshEdgeTable)
        renderer.update(mesh: model.mesh)
        _ = renderer.updateEdgeSelection(
            mesh: model.mesh, table: table, selection: model.edgeSelection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        let before = profiler.snapshot()
        let selectedUploads = renderer.edgeSelectionOverlaySelectedUploadCount
        let hoverUploads = renderer.edgeSelectionOverlayHoverUploadCount
        let start = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        let end = Ray(origin: SIMD3<Float>(0.8, 0.6, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: start, cameraDirection: SIMD3(0, 0, -1)))
        model.updateTranslationGizmoDrag(ray: end, cameraDirection: SIMD3(0, 0, -1))
        model.endTranslationGizmoDrag()
        renderer.update(mesh: model.mesh)
        _ = renderer.updateEdgeSelection(
            mesh: model.mesh, table: try XCTUnwrap(model.meshEdgeTable),
            selection: model.edgeSelection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        let committed = profiler.snapshot()
        XCTAssertEqual(committed[.vertexUpload].sampleCount, before[.vertexUpload].sampleCount + 1)
        XCTAssertEqual(committed[.indexUpload].sampleCount, before[.indexUpload].sampleCount)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, selectedUploads)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, hoverUploads)

        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: start, cameraDirection: SIMD3(0, 0, -1)))
        model.updateTranslationGizmoDrag(ray: start, cameraDirection: SIMD3(0, 0, -1))
        model.endTranslationGizmoDrag()
        renderer.update(mesh: model.mesh)
        _ = renderer.updateEdgeSelection(
            mesh: model.mesh, table: try XCTUnwrap(model.meshEdgeTable),
            selection: model.edgeSelection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        let noOp = profiler.snapshot()
        XCTAssertEqual(noOp[.vertexUpload].sampleCount, committed[.vertexUpload].sampleCount)
        XCTAssertEqual(noOp[.indexUpload].sampleCount, committed[.indexUpload].sampleCount)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, selectedUploads)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, hoverUploads)
    }

    private func makeInstrumentedEdgeRenderer() throws -> (
        MetalRenderer, EditableMesh, MeshEdgeTable, FaultInjectingEdgePairAllocator
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let allocator = FaultInjectingEdgePairAllocator()
        guard let renderer = MetalRenderer(
            view: view, profiler: nil, edgeSelectionBufferAllocator: allocator) else {
            throw XCTSkip("Renderer unavailable")
        }
        let source = twoTriangleQuad()
        return (renderer, source, try MeshEdgeTable.build(mesh: source), allocator)
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

    func testEdgeRotateBeginDeduplicatesEndpointsAndUsesSafeLocalAABBCenter() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertTrue(try selection.apply(.add, edgeID: 0))
        XCTAssertTrue(try selection.apply(.add, edgeID: 1))
        let transaction = try EdgeRotateGeometry.begin(
            mesh: source, table: table, selection: selection, transform: .identity,
            axis: SIMD3(0, 0, 1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        XCTAssertEqual(transaction.selectedEdgeCount, 2)
        XCTAssertEqual(transaction.vertexIDs, Array(Set(transaction.vertexIDs)).sorted())
        XCTAssertEqual(transaction.affectedVertexCount, transaction.vertexIDs.count)
        let positions = transaction.vertexIDs.map { source.vertices[Int($0)].position }
        let minimum = positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude), simd_min)
        let maximum = positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude), simd_max)
        XCTAssertEqual(transaction.pivotLocal, minimum * 0.5 + maximum * 0.5)
    }

    func testWorkspaceEdgeRotateRendererUploadsOnlyVerticesAndZeroAngleSkips() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let profiler = PerformanceProfiler()
        guard let renderer = MetalRenderer(view: view, profiler: profiler) else { throw XCTSkip("Renderer unavailable") }
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0)); model.setGizmoMode(.rotate)
        renderer.update(mesh: model.mesh)
        _ = renderer.updateEdgeSelection(mesh: model.mesh, table: try XCTUnwrap(model.meshEdgeTable),
            selection: model.edgeSelection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        let before = profiler.snapshot()
        let selectedUploads = renderer.edgeSelectionOverlaySelectedUploadCount
        let hoverUploads = renderer.edgeSelectionOverlayHoverUploadCount
        let start = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
        let end = Ray(origin: SIMD3<Float>(0,1,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: end); model.endRotationGizmoDrag()
        renderer.update(mesh: model.mesh)
        _ = renderer.updateEdgeSelection(mesh: model.mesh, table: try XCTUnwrap(model.meshEdgeTable),
            selection: model.edgeSelection, hoveredEdgeID: nil,
            drawableSizePixels: CGSize(width: 100, height: 100), displayScale: 1)
        let committed = profiler.snapshot()
        XCTAssertEqual(committed[.vertexUpload].sampleCount, before[.vertexUpload].sampleCount + 1)
        XCTAssertEqual(committed[.indexUpload].sampleCount, before[.indexUpload].sampleCount)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, selectedUploads)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, hoverUploads)

        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: start); model.endRotationGizmoDrag()
        renderer.update(mesh: model.mesh)
        let noOp = profiler.snapshot()
        XCTAssertEqual(noOp[.vertexUpload].sampleCount, committed[.vertexUpload].sampleCount)
        XCTAssertEqual(noOp[.indexUpload].sampleCount, committed[.indexUpload].sampleCount)
        XCTAssertEqual(renderer.edgeSelectionOverlaySelectedUploadCount, selectedUploads)
        XCTAssertEqual(renderer.edgeSelectionOverlayHoverUploadCount, hoverUploads)
    }

    func testEdgeRotatePivotUsesEndpointAABBCenterTransformedToWorld() throws {
        let source = mesh([SIMD3(-4,1,2), SIMD3(1,8,-1), SIMD3(10,-2,5)], [0,1,2])
        let table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        let ab = try XCTUnwrap(table.edgeIDByKey[try XCTUnwrap(MeshEdgeKey(0,1))])
        let bc = try XCTUnwrap(table.edgeIDByKey[try XCTUnwrap(MeshEdgeKey(1,2))])
        XCTAssertTrue(try selection.apply(.replace, edgeID: ab)); XCTAssertTrue(try selection.apply(.add, edgeID: bc))
        let transform = ObjectTransform(
            translation: SIMD3(20,-30,40),
            rotation: ObjectTransform.rotation(degrees: SIMD3(20,-35,15)),
            scale: SIMD3(2,0.5,3))
        let transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: transform, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        let expectedLocal = SIMD3<Float>(3,3,2)
        let position0: SIMD3<Float> = source.vertices[0].position
        let position1: SIMD3<Float> = source.vertices[1].position
        let position2: SIMD3<Float> = source.vertices[2].position
        let centroid: SIMD3<Float> = (position0 + position1 + position2) / 3
        let midpoint01: SIMD3<Float> = (position0 + position1) * 0.5
        let midpoint12: SIMD3<Float> = (position1 + position2) * 0.5
        let midpointAverage: SIMD3<Float> = (midpoint01 + midpoint12) * 0.5
        XCTAssertNotEqual(expectedLocal, centroid); XCTAssertNotEqual(expectedLocal, midpointAverage)
        XCTAssertNotEqual(expectedLocal, .zero); XCTAssertEqual(transaction.pivotLocal, expectedLocal)
        XCTAssertEqual(transaction.pivotWorld, transform.worldPosition(fromLocal: expectedLocal))

        let model = WorkspaceModel(); model.mesh = source; model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(ab)); model.setEdgeSelectionOperation(.add)
        XCTAssertTrue(model.applyEdgeSelectionHit(bc)); model.updateTransform(transform); model.setGizmoMode(.rotate)
        XCTAssertEqual(model.edgeRotatePivotWorld, transaction.pivotWorld)
    }

    func testEdgeRotateIsAbsoluteFromStartAndPreservesUnselectedVertices() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        var transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        _ = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: .pi / 4))
        let second = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: .pi / 2))
        var fresh = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        let expected = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &fresh, accumulatedAngle: .pi / 2))
        XCTAssertEqual(second, expected)
        XCTAssertEqual(second.runtime.revision, expected.runtime.revision)
        XCTAssertEqual(second.indices, source.indices)
        XCTAssertEqual(second.runtime.topologyID, source.runtime.topologyID)
        XCTAssertEqual(second.runtime.topologyRevision, source.runtime.topologyRevision)
        let affected = Set(transaction.vertexIDs.map(Int.init))
        for index in source.vertices.indices where !affected.contains(index) {
            XCTAssertEqual(second.vertices[index].position, source.vertices[index].position)
        }
    }

    func testEdgeRotateWorldDirectionIsTranslationIndependentWithNonUniformScale() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        let rotation = ObjectTransform.rotation(degrees: SIMD3(25, -30, 15))
        let base = ObjectTransform(rotation: rotation, scale: SIMD3(2, 0.5, 3))
        let translated = ObjectTransform(translation: SIMD3(100_000_000, -80_000_000, 50_000_000), rotation: rotation, scale: SIMD3(2, 0.5, 3))
        var a = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: base, axis: SIMD3(1,0,0), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        var b = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: translated, axis: SIMD3(1,0,0), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        XCTAssertEqual(try EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &a, accumulatedAngle: 0.7),
                       try EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &b, accumulatedAngle: 0.7))
    }

    func testEdgeRotateRepeatedIdenticalAbsoluteAngleHasStableRevisionAndGeometry() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        var transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        let angle = Float.pi / 4
        let first = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: angle))
        let second = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: angle))
        let third = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: angle))
        XCTAssertEqual(first, second); XCTAssertEqual(second, third)
        XCTAssertEqual(first.runtime.revision, second.runtime.revision)
        XCTAssertEqual(second.runtime.revision, third.runtime.revision)
        XCTAssertEqual(third.indices, source.indices)
        XCTAssertEqual(third.runtime.topologyID, source.runtime.topologyID)
        XCTAssertEqual(third.runtime.topologyRevision, source.runtime.topologyRevision)
    }

    func testEdgeRotateFullTurnsAreNoOpsAndMultiTurnResultIsFinite() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(selection.selectAll())
        var transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        XCTAssertNil(try EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: .pi * 2))
        XCTAssertNil(try EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: .pi * 4))
        let candidate = try XCTUnwrap(EdgeRotateGeometry.candidate(sourceMesh: source, transaction: &transaction, accumulatedAngle: .pi * 4 + 0.2))
        XCTAssertTrue(candidate.vertices.allSatisfy { $0.position.allFinite && $0.normal.allFinite })
    }

    func testEdgeRotateUsesRotationGizmoUnwrapAcrossMultiTurnBoundary() throws {
        var raw: Float = 0, accumulated: Float = 0
        for degrees in [170, -170, -90] as [Float] {
            let update = try XCTUnwrap(RotationGizmoGeometry.unwrap(
                rawAngle: degrees * .pi / 180, lastRawAngle: raw,
                accumulatedAngle: accumulated))
            raw = update.rawAngle; accumulated = update.accumulatedAngle
        }
        XCTAssertEqual(accumulated, Float(270) * .pi / 180, accuracy: 0.000_1)
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        var transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        let candidate = try XCTUnwrap(EdgeRotateGeometry.candidate(
            sourceMesh: source, transaction: &transaction, accumulatedAngle: accumulated))
        let rotation = simd_quatf(angle: accumulated, axis: SIMD3<Float>(0,0,1))
        for (offset, id) in transaction.vertexIDs.enumerated() {
            let expected = transaction.pivotLocal
                + rotation.act(transaction.startLocalPositions[offset] - transaction.pivotLocal)
            XCTAssertEqual(candidate.vertices[Int(id)].position.x, expected.x, accuracy: 0.000_01)
            XCTAssertEqual(candidate.vertices[Int(id)].position.y, expected.y, accuracy: 0.000_01)
        }
    }

    func testEdgeRotateRejectsEmptyInvalidAndOversizedInputs() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table)
        XCTAssertThrowsError(try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration()))
        XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        XCTAssertThrowsError(try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: .zero, projectSessionID: UUID(), projectGeneration: MutationGeneration()))
        XCTAssertThrowsError(try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration(), memoryLimit: 1))
        XCTAssertThrowsError(try EdgeRotateGeometry.estimatedPeakBytes(vertexCount: Int.max, indexCount: Int.max,
            selectedEdgeCount: Int.max, affectedVertexCount: Int.max))
    }

    func testEdgeRotateMemoryExactBoundaryAndConservativeEndpointPreflight() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(selection.selectAll())
        let maximumAffected = min(source.vertices.count, selection.selectedCount * 2)
        let required = try EdgeRotateGeometry.estimatedPeakBytes(
            vertexCount: source.vertices.count, indexCount: source.indices.count,
            selectedEdgeCount: selection.selectedCount, affectedVertexCount: maximumAffected)
        XCTAssertNoThrow(try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(),
            projectGeneration: MutationGeneration(), memoryLimit: required))
        XCTAssertThrowsError(try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(),
            projectGeneration: MutationGeneration(), memoryLimit: required - 1)) {
                XCTAssertEqual($0 as? EdgeRotateError, .workingMemoryLimitExceeded)
            }
    }

    func testEdgeRotateEndpointDedupeForSingleDisjointSharedAndChainSelections() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        func captured(_ edgeIDs: [Int]) throws -> EdgeRotateTransaction {
            var selection = try EdgeSelection(table: table)
            for (offset, edgeID) in edgeIDs.enumerated() {
                XCTAssertTrue(try selection.apply(offset == 0 ? .replace : .add, edgeID: edgeID))
            }
            return try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
                transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
        }
        let single = try captured([0]); XCTAssertEqual(single.affectedVertexCount, 2)
        let disjoint = try captured([0, 4]); XCTAssertEqual(disjoint.affectedVertexCount, 4)
        let shared = try captured([0, 1]); XCTAssertEqual(shared.affectedVertexCount, 3)
        XCTAssertEqual(shared.vertexIDs, shared.vertexIDs.sorted())
        let chain = try captured([0, 1, 3]); XCTAssertEqual(chain.vertexIDs, chain.vertexIDs.sorted())
        XCTAssertEqual(Set(chain.vertexIDs).count, chain.affectedVertexCount)
    }

    func testEdgeRotateChangedThenRestoredSelectionRemainsStaleWithoutPointerRescan() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        let session = UUID(), generation = MutationGeneration()
        let transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: session, projectGeneration: generation)
        XCTAssertTrue(try selection.apply(.add, edgeID: 1)); XCTAssertTrue(try selection.apply(.remove, edgeID: 1))
        XCTAssertEqual(selection.selectedEdgeIDs(), transaction.selectedEdgeIDs)
        XCTAssertFalse(transaction.matches(mesh: source, table: table, selection: selection,
            transform: .identity, projectSessionID: session, projectGeneration: generation))
    }

    func testEdgeRotateTransactionRejectsEveryRuntimeBindingIndependently() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        let session = UUID(), generation = MutationGeneration()
        let base = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
            transform: .identity, axis: SIMD3(0,0,1), projectSessionID: session, projectGeneration: generation)
        func copy(topologyID: UUID? = nil, topologyRevision: UInt64? = nil,
                  fingerprint: UInt64? = nil, vertexRevision: UInt64? = nil,
                  vertexCount: Int? = nil, indexCount: Int? = nil,
                  selectionVersion: EdgeSelectionVersion? = nil, selectedCount: Int? = nil,
                  transform: ObjectTransform? = nil, projectSessionID: UUID? = nil,
                  projectGeneration: MutationGeneration? = nil) -> EdgeRotateTransaction {
            EdgeRotateTransaction(
                id: base.id, topologyID: topologyID ?? base.topologyID,
                topologyRevision: topologyRevision ?? base.topologyRevision,
                edgeTableFingerprint: fingerprint ?? base.edgeTableFingerprint,
                sourceVertexRevision: vertexRevision ?? base.sourceVertexRevision,
                sourceVertexCount: vertexCount ?? base.sourceVertexCount,
                sourceIndexCount: indexCount ?? base.sourceIndexCount,
                selectionVersion: selectionVersion ?? base.selectionVersion,
                selectedEdgeCount: selectedCount ?? base.selectedEdgeCount,
                affectedVertexCount: base.affectedVertexCount,
                selectedEdgeIDs: base.selectedEdgeIDs, vertexIDs: base.vertexIDs,
                startLocalPositions: base.startLocalPositions, pivotLocal: base.pivotLocal,
                pivotWorld: base.pivotWorld, transform: transform ?? base.transform,
                axis: base.axis, projectSessionID: projectSessionID ?? base.projectSessionID,
                projectGeneration: projectGeneration ?? base.projectGeneration)
        }
        func matches(_ value: EdgeRotateTransaction) -> Bool {
            value.matches(mesh: source, table: table, selection: selection, transform: .identity,
                          projectSessionID: session, projectGeneration: generation)
        }
        XCTAssertTrue(matches(base))
        XCTAssertFalse(matches(copy(topologyID: UUID())))
        XCTAssertFalse(matches(copy(topologyRevision: base.topologyRevision + 1)))
        XCTAssertFalse(matches(copy(fingerprint: base.edgeTableFingerprint &+ 1)))
        XCTAssertFalse(matches(copy(vertexRevision: base.sourceVertexRevision + 1)))
        XCTAssertFalse(matches(copy(vertexCount: base.sourceVertexCount + 1)))
        XCTAssertFalse(matches(copy(indexCount: base.sourceIndexCount + 3)))
        XCTAssertFalse(matches(copy(selectionVersion: EdgeSelectionVersion(identity: UUID()))))
        XCTAssertFalse(matches(copy(selectedCount: base.selectedEdgeCount + 1)))
        XCTAssertFalse(matches(copy(transform: ObjectTransform(translation: SIMD3(1,0,0)))))
        XCTAssertFalse(matches(copy(transform: ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3(0,10,0))))))
        XCTAssertFalse(matches(copy(transform: ObjectTransform(scale: SIMD3(2,1,1)))))
        XCTAssertFalse(matches(copy(projectSessionID: UUID())))
        var changedGeneration = generation; changedGeneration.advance()
        XCTAssertFalse(matches(copy(projectGeneration: changedGeneration)))
    }

    func testEdgeRotateCandidateFailurePointsAreAtomic() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        for point in [EdgeRotateFailurePoint.candidateAllocation, .normalRebuild,
                      .candidateValidation, .candidatePostUpdate, .rendererPreparation] {
            var transaction = try EdgeRotateGeometry.begin(mesh: source, table: table, selection: selection,
                transform: .identity, axis: SIMD3(0,0,1), projectSessionID: UUID(), projectGeneration: MutationGeneration())
            XCTAssertThrowsError(try EdgeRotateGeometry.candidate(sourceMesh: source,
                transaction: &transaction, accumulatedAngle: .pi / 4,
                failureInjector: .init { $0 == point }))
            XCTAssertEqual(source, twoTriangleQuad())
            let result = try XCTUnwrap(EdgeRotateGeometry.candidate(
                sourceMesh: source, transaction: &transaction, accumulatedAngle: .pi / 4))
            XCTAssertTrue(result.vertices.allSatisfy { vertex in
                vertex.position.x.isFinite && vertex.position.y.isFinite && vertex.position.z.isFinite
            })
            XCTAssertEqual(result.indices, source.indices)
            XCTAssertEqual(result.runtime.topologyID, source.runtime.topologyID)
            XCTAssertEqual(result.runtime.topologyRevision, source.runtime.topologyRevision)
        }
    }

    func testUnifiedVertexAndEdgeTransformHistoryPreservesExactChronology() {
        let model = WorkspaceModel()
        let s0 = model.mesh
        model.setInteractionMode(.vertexSelect); model.selectAllVertices(); model.setGizmoMode(.translate)
        let vertexMoveStart = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: vertexMoveStart, cameraDirection: SIMD3(0,0,-1)))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3(0.8,0.5,5), direction: SIMD3(0,0,-1)),
            cameraDirection: SIMD3(0,0,-1)); model.endTranslationGizmoDrag()
        let s1 = model.mesh
        model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
        let edgeMoveStart = Ray(origin: SIMD3<Float>(0.3,0.3,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(
            handle: .xyPlane, ray: edgeMoveStart, cameraDirection: SIMD3(0,0,-1)))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3(0.7,0.6,5), direction: SIMD3(0,0,-1)),
            cameraDirection: SIMD3(0,0,-1)); model.endTranslationGizmoDrag()
        let s2 = model.mesh
        model.setInteractionMode(.vertexSelect); model.setGizmoMode(.rotate)
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis,
            ray: Ray(origin: SIMD3(1,0,5), direction: SIMD3(0,0,-1))))
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3(0,1,5), direction: SIMD3(0,0,-1)))
        model.endRotationGizmoDrag(); let s3 = model.mesh
        model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis,
            ray: Ray(origin: SIMD3(1,0,5), direction: SIMD3(0,0,-1))))
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3(0,1,5), direction: SIMD3(0,0,-1)))
        model.endRotationGizmoDrag(); let s4 = model.mesh
        model.setInteractionMode(.vertexSelect); model.setGizmoMode(.scale)
        let scaleStart = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: scaleStart,
            cameraDirection: SIMD3(0,0,-1), referenceLength: 1))
        model.updateScaleGizmoDrag(ray: Ray(origin: SIMD3(1.5,0,5), direction: SIMD3(0,0,-1)),
            cameraDirection: SIMD3(0,0,-1)); model.endScaleGizmoDrag()
        let s5 = model.mesh
        XCTAssertEqual(model.undoCount, 5); XCTAssertEqual(model.redoCount, 0)
        for expected in [s4, s3, s2, s1, s0] { model.undo(); XCTAssertEqual(model.mesh, expected) }
        XCTAssertEqual(model.undoCount, 0); XCTAssertEqual(model.redoCount, 5)
        for expected in [s1, s2, s3, s4, s5] { model.redo(); XCTAssertEqual(model.mesh, expected) }
        XCTAssertEqual(model.undoCount, 5); XCTAssertEqual(model.redoCount, 0)
    }

    func testEdgeRotateSnapshotCopyAndRoundTripFailureInjectionRetries() throws {
        let source = twoTriangleQuad(), table = try MeshEdgeTable.build(mesh: source)
        var selection = try EdgeSelection(table: table); XCTAssertTrue(try selection.apply(.replace, edgeID: 0))
        for point in [EdgeRotateFailurePoint.sourceSnapshot, .selectedPositionCopy] {
            XCTAssertThrowsError(try EdgeRotateGeometry.begin(mesh: source, table: table,
                selection: selection, transform: .identity, axis: SIMD3(0,0,1),
                projectSessionID: UUID(), projectGeneration: MutationGeneration(),
                failureInjector: .init { $0 == point }))
            XCTAssertNoThrow(try EdgeRotateGeometry.begin(mesh: source, table: table,
                selection: selection, transform: .identity, axis: SIMD3(0,0,1),
                projectSessionID: UUID(), projectGeneration: MutationGeneration()))
        }
        var transaction = try EdgeRotateGeometry.begin(mesh: source, table: table,
            selection: selection, transform: .identity, axis: SIMD3(0,0,1),
            projectSessionID: UUID(), projectGeneration: MutationGeneration())
        XCTAssertThrowsError(try EdgeRotateGeometry.candidate(sourceMesh: source,
            transaction: &transaction, accumulatedAngle: .pi / 4,
            failureInjector: .init { $0 == .roundTripValidation })) {
                XCTAssertEqual($0 as? EdgeRotateError, .precisionLoss)
            }
        XCTAssertNotNil(try EdgeRotateGeometry.candidate(sourceMesh: source,
            transaction: &transaction, accumulatedAngle: .pi / 4))
        XCTAssertEqual(source, twoTriangleQuad())
    }

    func testWorkspaceEdgeRotatePreviewCommitUndoRedoCancelAndIsolation() throws {
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0)); model.setGizmoMode(.rotate)
        let original = model.mesh, selection = model.edgeSelection, transform = model.objectTransform
        let generation = model.projectMutationGeneration, project = try model.projectData()
        let stlBefore = try model.stlData(), edgeFingerprint = model.meshEdgeTable?.fingerprint
        let selectedIDs = model.edgeSelection.selectedEdgeIDs()
        let start = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
        let end = Ray(origin: SIMD3<Float>(0,1,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start)); model.updateRotationGizmoDrag(ray: end)
        XCTAssertNotNil(model.edgeRotatePreviewMesh); XCTAssertNotEqual(model.renderedMesh, model.mesh)
        XCTAssertTrue(model.edgeRotatePreviewPickingHasIndexForTesting)
        XCTAssertEqual(model.edgeRotatePreviewPickingRevisionForTesting,
                       model.edgeRotatePreviewMesh?.runtime.revision)
        XCTAssertEqual(model.mesh, original); XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.edgeSelection, selection); XCTAssertEqual(try model.projectData(), project)
        XCTAssertThrowsError(try model.stlData()) {
            XCTAssertEqual($0 as? WorkspaceError, .activeEditInProgress)
        }
        model.cancelRotationGizmoDrag(); XCTAssertEqual(model.mesh, original); XCTAssertNil(model.edgeRotatePreviewMesh)
        XCTAssertFalse(model.edgeRotatePreviewPickingHasIndexForTesting)
        XCTAssertEqual(try model.stlData(), stlBefore)
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: end); model.endRotationGizmoDrag()
        let committed = model.mesh
        XCTAssertNotEqual(committed, original); XCTAssertTrue(model.lastUndoIsEdgeRotateForTesting)
        XCTAssertTrue(model.pickingCacheHasIndexForTesting)
        XCTAssertEqual(model.pickingCacheTopologyIDForTesting, committed.runtime.topologyID)
        XCTAssertFalse(model.edgeRotatePreviewPickingHasIndexForTesting)
        XCTAssertEqual(model.edgeSelection, selection); XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(committed.runtime.topologyID, original.runtime.topologyID)
        XCTAssertEqual(committed.runtime.topologyRevision, original.runtime.topologyRevision)
        XCTAssertEqual(committed.indices, original.indices)
        XCTAssertEqual(model.meshEdgeTable?.fingerprint, edgeFingerprint)
        XCTAssertEqual(model.edgeSelection.version, selection.version)
        XCTAssertEqual(model.edgeSelection.selectedEdgeIDs(), selectedIDs)
        XCTAssertNotEqual(try model.projectData(), project); XCTAssertNotEqual(try model.stlData(), stlBefore)
        XCTAssertEqual(model.projectMutationGeneration.value, generation.value + 1)
        model.undo(); XCTAssertEqual(model.mesh, original); XCTAssertEqual(model.edgeSelection, selection)
        XCTAssertEqual(try model.projectData(), project); XCTAssertEqual(try model.stlData(), stlBefore)
        model.redo(); XCTAssertEqual(model.mesh, committed); XCTAssertEqual(model.edgeSelection, selection)
        XCTAssertNotEqual(try model.projectData(), project); XCTAssertNotEqual(try model.stlData(), stlBefore)
    }

    func testEmptyEdgeSelectionNeverFallsBackToObjectRotation() {
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect); model.setGizmoMode(.rotate)
        let transform = model.objectTransform
        XCTAssertFalse(model.beginRotationGizmoDrag(handle: .zAxis,
            ray: Ray(origin: SIMD3(1,0,5), direction: SIMD3(0,0,-1))))
        XCTAssertEqual(model.objectTransform, transform); XCTAssertFalse(model.isGizmoDragging)
    }

    func testRotationGizmoRoutesEdgeVertexAndOrdinaryModesWithoutCrossRouting() {
        let ray = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
        let edge = WorkspaceModel(); edge.setInteractionMode(.edgeSelect)
        XCTAssertTrue(edge.applyEdgeSelectionHit(0)); edge.setGizmoMode(.rotate)
        let edgeTransform = edge.objectTransform
        XCTAssertTrue(edge.beginRotationGizmoDrag(handle: .zAxis, ray: ray))
        XCTAssertTrue(edge.edgeRotateTransactionActiveForTesting)
        XCTAssertFalse(edge.vertexRotateTransactionActiveForTesting)
        XCTAssertEqual(edge.objectTransform, edgeTransform); edge.cancelRotationGizmoDrag()

        let vertex = WorkspaceModel(); vertex.setInteractionMode(.vertexSelect)
        XCTAssertTrue(vertex.applyVertexSelectionHit(0)); vertex.setGizmoMode(.rotate)
        XCTAssertTrue(vertex.beginRotationGizmoDrag(handle: .zAxis, ray: ray))
        XCTAssertTrue(vertex.vertexRotateTransactionActiveForTesting)
        XCTAssertFalse(vertex.edgeRotateTransactionActiveForTesting); vertex.cancelRotationGizmoDrag()

        let ordinary = WorkspaceModel(); ordinary.setGizmoMode(.rotate)
        XCTAssertTrue(ordinary.beginRotationGizmoDrag(handle: .zAxis, ray: ray))
        XCTAssertFalse(ordinary.edgeRotateTransactionActiveForTesting)
        XCTAssertFalse(ordinary.vertexRotateTransactionActiveForTesting)
        XCTAssertTrue(ordinary.rotationGizmoState.isDragging); ordinary.cancelRotationGizmoDrag()
    }

    func testWorkspaceEdgeRotateCommitFailureIsAtomicAndRetryable() throws {
        var active: EdgeRotateFailurePoint? = .commitBoundary
        let model = WorkspaceModel(edgeRotateFailureInjector: .init { $0 == active })
        model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0)); model.setGizmoMode(.rotate)
        let original = model.mesh, selection = model.edgeSelection, generation = model.projectMutationGeneration
        let start = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
        let end = Ray(origin: SIMD3<Float>(0,1,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: end); model.endRotationGizmoDrag()
        XCTAssertEqual(model.mesh, original); XCTAssertEqual(model.edgeSelection, selection)
        XCTAssertEqual(model.projectMutationGeneration, generation); XCTAssertEqual(model.undoCount, 0)
        active = nil
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: end); model.endRotationGizmoDrag()
        XCTAssertNotEqual(model.mesh, original); XCTAssertTrue(model.lastUndoIsEdgeRotateForTesting)
    }

    func testWorkspaceEdgeRotateZeroAnglePreservesRedoAndAllRuntimeIdentity() throws {
        let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect)
        XCTAssertTrue(model.applyEdgeSelectionHit(0)); model.setGizmoMode(.rotate)
        let start = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
        let end = Ray(origin: SIMD3<Float>(0,1,5), direction: SIMD3(0,0,-1))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: end); model.endRotationGizmoDrag(); model.undo()
        XCTAssertEqual(model.redoCount, 1)
        let mesh = model.mesh, selection = model.edgeSelection
        let generation = model.projectMutationGeneration, history = (model.undoCount, model.redoCount)
        let dirty = model.isDirty, revision = model.mesh.runtime.revision
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
        model.updateRotationGizmoDrag(ray: start); model.endRotationGizmoDrag()
        XCTAssertEqual(model.mesh, mesh); XCTAssertEqual(model.mesh.runtime.revision, revision)
        XCTAssertEqual(model.mesh.runtime.topologyID, mesh.runtime.topologyID)
        XCTAssertEqual(model.mesh.runtime.topologyRevision, mesh.runtime.topologyRevision)
        XCTAssertEqual(model.mesh.indices, mesh.indices); XCTAssertEqual(model.edgeSelection, selection)
        XCTAssertEqual(model.edgeSelection.version, selection.version)
        XCTAssertEqual(model.undoCount, history.0); XCTAssertEqual(model.redoCount, history.1)
        XCTAssertEqual(model.projectMutationGeneration, generation); XCTAssertEqual(model.isDirty, dirty)
    }

    func testEdgeRotatePreparedBeginResolvesProjectedConflictsIndependently() {
        for conflicts in [(true,false,false), (false,true,false), (false,false,true)] {
            let model = WorkspaceModel(); model.setInteractionMode(.edgeSelect)
            XCTAssertTrue(model.applyEdgeSelectionHit(0)); model.setGizmoMode(.rotate)
            model.installEdgeRotateBeginConflictsForTesting(
                sculpt: conflicts.0, transformPanel: conflicts.1, objectRotate: conflicts.2)
            let ray = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3<Float>(0,0,-1))
            XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: ray))
            XCTAssertTrue(model.edgeRotateTransactionActiveForTesting)
            XCTAssertFalse(model.isStrokeActive); XCTAssertFalse(model.isTransformPanelEditing)
            model.cancelRotationGizmoDrag()
        }
    }

    func testWorkspaceEdgeRotatePreviewAndCommitBVHFailuresAreAtomicAndRetryable() {
        for point in [EdgeRotateFailurePoint.previewBVHPreparation, .commitBVHPreparation] {
            var active: EdgeRotateFailurePoint? = point
            let model = WorkspaceModel(edgeRotateFailureInjector: .init { $0 == active })
            model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0)); model.setGizmoMode(.rotate)
            let original = model.mesh, generation = model.projectMutationGeneration
            let start = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3(0,0,-1))
            let end = Ray(origin: SIMD3<Float>(0,1,5), direction: SIMD3(0,0,-1))
            XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
            model.updateRotationGizmoDrag(ray: end)
            if point == .commitBVHPreparation { model.endRotationGizmoDrag() }
            XCTAssertEqual(model.mesh, original); XCTAssertEqual(model.projectMutationGeneration, generation)
            XCTAssertEqual(model.undoCount, 0); XCTAssertFalse(model.isGizmoDragging)
            active = nil
            XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: start))
            model.updateRotationGizmoDrag(ray: end); model.endRotationGizmoDrag()
            XCTAssertNotEqual(model.mesh, original); XCTAssertTrue(model.lastUndoIsEdgeRotateForTesting)
        }
    }

    func testEdgeRotateBeginBoundaryFailurePreservesEachConflictAndRetries() {
        for conflicts in [(true,false,false), (false,true,false), (false,false,true)] {
            var fail = true
            let model = WorkspaceModel(edgeRotateFailureInjector: .init {
                fail && $0 == .beginCommitBoundary
            })
            model.setInteractionMode(.edgeSelect); XCTAssertTrue(model.applyEdgeSelectionHit(0))
            model.setGizmoMode(.rotate)
            model.installEdgeRotateBeginConflictsForTesting(
                sculpt: conflicts.0, transformPanel: conflicts.1, objectRotate: conflicts.2)
            let mesh = model.mesh, transform = model.objectTransform, selection = model.edgeSelection
            let generation = model.projectMutationGeneration, status = model.status
            let ray = Ray(origin: SIMD3<Float>(1,0,5), direction: SIMD3<Float>(0,0,-1))
            XCTAssertFalse(model.beginRotationGizmoDrag(handle: .zAxis, ray: ray))
            XCTAssertEqual(model.mesh, mesh); XCTAssertEqual(model.objectTransform, transform)
            XCTAssertEqual(model.edgeSelection, selection); XCTAssertEqual(model.projectMutationGeneration, generation)
            XCTAssertEqual(model.status, status); XCTAssertEqual(model.isStrokeActive, conflicts.0)
            XCTAssertEqual(model.isTransformPanelEditing, conflicts.1)
            XCTAssertEqual(model.rotationGizmoState.isDragging, conflicts.2)
            fail = false
            XCTAssertTrue(model.beginRotationGizmoDrag(handle: .zAxis, ray: ray))
            model.cancelRotationGizmoDrag()
        }
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
    private(set) var allocationCount = 0
    private(set) var copyCount = 0
    var beforeAllocation: (() -> Void)?

    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        allocationCount += 1
        beforeAllocation?()
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
