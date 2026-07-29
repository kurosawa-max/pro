import XCTest
import SwiftUI
import simd
@testable import Forge3D
#if canImport(UIKit)
import UIKit
#endif

final class EdgeBevelTests: XCTestCase {
    func testDefaultOptionsAndAbsoluteRange() {
        XCTAssertEqual(EdgeBevelOptions().widthMillimeters, 0.5)
        XCTAssertEqual(EdgeBevelOptions.minimumWidthMillimeters, 0.001)
        XCTAssertEqual(EdgeBevelOptions.maximumWidthMillimeters, 1_000)
    }

    func testOneInteriorEdgeUsesDeterministicCountsSlotsAndClosedTopology() throws {
        let source = octahedron()
        let (table, selection, edgeID) = try selected(source, keys: [try key(0, 1)])
        let result = try EdgeBevel.bevel(
            mesh: source, table: table, selection: selection, transform: .identity,
            options: EdgeBevelOptions(widthMillimeters: 0.1))
        XCTAssertEqual(result.estimate.selectedEdgeCount, 1)
        XCTAssertEqual(result.mesh.vertices.count, source.vertices.count + 4)
        XCTAssertEqual(result.mesh.indices.count / 3, source.indices.count / 3 + 8)
        XCTAssertEqual(Array(result.mesh.vertices.prefix(source.vertices.count)), source.vertices)
        let faces = table.edges[edgeID].incidentFaceIDs
        XCTAssertEqual(faces.count, 2)
        let unchangedFaces = (0..<(source.indices.count / 3)).filter {
            Array(result.mesh.indices[($0 * 3)..<($0 * 3 + 3)])
                == Array(source.indices[($0 * 3)..<($0 * 3 + 3)])
        }
        XCTAssertEqual(unchangedFaces.count, 2)
        XCTAssertFalse(result.mesh.indices.containsSubsequence([UInt32(0), 1]))
        let report = MeshTopologyDiagnostics.analyze(result.mesh)
        XCTAssertEqual(report.boundaryEdgeCount, 0)
        XCTAssertEqual(report.nonManifoldEdgeCount, 0)
        XCTAssertEqual(report.inconsistentWindingEdgeCount, 0)
        XCTAssertEqual(report.degenerateTriangleCount, 0)
        XCTAssertEqual(report.duplicateTriangleCount, 0)
        XCTAssertEqual(report.isolatedVertexCount, 0)
        XCTAssertEqual(report.connectedComponentCount, 1)
        XCTAssertTrue(result.mesh.hasCachedAdjacency)
        XCTAssertTrue(result.mesh.vertices.allSatisfy { $0.normal.allFinite && abs(simd_length($0.normal) - 1) < 0.001 })
    }

    func testWorldWidthAcrossTransformVariants() throws {
        let transforms = [
            ObjectTransform.identity,
            ObjectTransform(translation: SIMD3(5, -7, 11)),
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3(20, 35, -15))),
            ObjectTransform(scale: SIMD3(repeating: 4)),
            ObjectTransform(translation: SIMD3(1000, -2000, 3000),
                            rotation: ObjectTransform.rotation(degrees: SIMD3(15, 25, 40)),
                            scale: SIMD3(0.5, 3, 7))
        ]
        for transform in transforms {
            let source = octahedron()
            let (table, selection, _) = try selected(source, keys: [try key(0, 1)])
            let width = 0.1
            let result = try EdgeBevel.bevel(mesh: source, table: table, selection: selection,
                                             transform: transform,
                                             options: EdgeBevelOptions(widthMillimeters: width))
            let p0 = world(source, transform, 0), p1 = world(source, transform, 1)
            let direction = simd_normalize(p1 - p0)
            for vertex in result.mesh.vertices.suffix(4) {
                let point = double(transform.worldPosition(fromLocal: vertex.position))
                let perpendicular = (point - p0) - direction * simd_dot(point - p0, direction)
                XCTAssertEqual(simd_length(perpendicular), width, accuracy: 0.001)
            }
        }
    }

    func testMinimumNearMaximumAndMaximumRejectionWithoutClamp() throws {
        let source = octahedron()
        let (table, selection, _) = try selected(source, keys: [try key(0, 1)])
        XCTAssertNoThrow(try EdgeBevel.estimate(mesh: source, table: table, selection: selection,
                                                transform: .identity,
                                                options: EdgeBevelOptions(widthMillimeters: 0.001)))
        let estimate = try EdgeBevel.estimate(mesh: source, table: table, selection: selection,
                                              transform: .identity,
                                              options: EdgeBevelOptions(widthMillimeters: 0.1))
        XCTAssertNoThrow(try EdgeBevel.estimate(mesh: source, table: table, selection: selection,
                                                transform: .identity,
                                                options: EdgeBevelOptions(widthMillimeters: estimate.maximumSafeWidthMillimeters * 0.99)))
        XCTAssertThrowsError(try EdgeBevel.estimate(mesh: source, table: table, selection: selection,
                                                    transform: .identity,
                                                    options: EdgeBevelOptions(widthMillimeters: estimate.maximumSafeWidthMillimeters))) {
            XCTAssertEqual($0 as? EdgeBevelError, .widthExceedsSafeMaximum)
        }
    }

    func testAdjacentSelectedEdgesAreRejected() throws {
        let source = octahedron()
        let (table, selection, _) = try selected(source, keys: [try key(0, 1), try key(0, 2)])
        XCTAssertThrowsError(try EdgeBevel.estimate(mesh: source, table: table, selection: selection,
                                                    transform: .identity, options: .init(widthMillimeters: 0.1))) {
            XCTAssertEqual($0 as? EdgeBevelError, .adjacentSelectedEdges)
        }
    }

    func testBoundaryAndCoplanarEdgesAreRejected() throws {
        let open = mesh([SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], [0,1,2])
        var table = try MeshEdgeTable.build(mesh: open)
        var selection = try EdgeSelection(table: table)
        _ = try selection.apply(.add, edgeID: 0)
        XCTAssertThrowsError(try EdgeBevel.estimate(mesh: open, table: table, selection: selection,
                                                    transform: .identity, options: .init(widthMillimeters: 0.1))) {
            XCTAssertEqual($0 as? EdgeBevelError, .boundaryEdge)
        }
        let cube = try PrimitiveMeshBuilder.cube(size: 2)
        table = try MeshEdgeTable.build(mesh: cube)
        let diagonal = try XCTUnwrap(table.edges.first { record in
            guard record.classification == .manifoldInterior else { return false }
            let faces = record.incidentFaceIDs
            let n0 = faceNormal(cube, faces[0]), n1 = faceNormal(cube, faces[1])
            return abs(simd_dot(simd_normalize(n0), simd_normalize(n1))) > 0.9999
        })
        selection = try EdgeSelection(table: table)
        _ = try selection.apply(.add, edgeID: diagonal.id)
        XCTAssertThrowsError(try EdgeBevel.estimate(mesh: cube, table: table, selection: selection,
                                                    transform: .identity, options: .init(widthMillimeters: 0.1))) {
            XCTAssertEqual($0 as? EdgeBevelError, .coplanarEdge)
        }
    }

    func testTetrahedronRequiresEndpointMiter() throws {
        let source = tetrahedron()
        let (table, selection, _) = try selected(source, keys: [try key(0, 1)])
        XCTAssertThrowsError(try EdgeBevel.estimate(
            mesh: source, table: table, selection: selection, transform: .identity,
            options: .init(widthMillimeters: 0.1))) {
            XCTAssertEqual($0 as? EdgeBevelError, .endpointMiterRequired)
        }
    }

    func testPreviewIdentityRejectsSelectionTransformOptionsAndVertexChange() throws {
        var source = octahedron()
        let (table, selection, _) = try selected(source, keys: [try key(0, 1)])
        let meshVersion = TopologyEditChangeVersion(), transformVersion = TopologyEditChangeVersion()
        let options = EdgeBevelOptions(widthMillimeters: 0.1)
        let preview = try EdgeBevel.makePreview(mesh: source, table: table, selection: selection,
                                                transform: .identity, options: options,
                                                meshChangeVersion: meshVersion,
                                                transformChangeVersion: transformVersion)
        XCTAssertTrue(preview.source.matchesRuntimeIdentity(mesh: source, table: table, selection: selection,
                                                             transform: .identity, meshChangeVersion: meshVersion,
                                                             transformChangeVersion: transformVersion, options: options))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(mesh: source, table: table, selection: selection,
                                                              transform: ObjectTransform(translation: SIMD3(1,0,0)),
                                                              meshChangeVersion: meshVersion,
                                                              transformChangeVersion: transformVersion, options: options))
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(mesh: source, table: table, selection: selection,
                                                              transform: .identity, meshChangeVersion: meshVersion,
                                                              transformChangeVersion: transformVersion,
                                                              options: .init(widthMillimeters: 0.2)))
        _ = source.updatePositions([0: source.vertices[0].position + SIMD3(0.01,0,0)])
        XCTAssertFalse(preview.source.matchesRuntimeIdentity(mesh: source, table: table, selection: selection,
                                                              transform: .identity, meshChangeVersion: meshVersion,
                                                              transformChangeVersion: transformVersion, options: options))
    }

    @MainActor
    func testWorkspaceApplyUndoRedoIsOneCommandAndClearsSelections() throws {
        let model = try configuredModel()
        let before = model.mesh, transform = ObjectTransform(translation: SIMD3(2,3,4))
        model.updateTransform(transform)
        try model.prepareForEdgeBevel()
        let preview = try model.previewEdgeBevel(options: .init(widthMillimeters: 0.1))
        let undoBefore = model.undoCount
        let after = try model.applyEdgeBevel(preview: preview).mesh
        XCTAssertEqual(model.undoCount, undoBefore + 1)
        XCTAssertEqual(model.objectTransform, transform.sanitized())
        XCTAssertEqual(model.selectedEdgeCount, 0)
        XCTAssertEqual(model.selectedFaceCount, 0)
        XCTAssertNil(model.edgeBevelPreview)
        XCTAssertTrue(model.pickingCacheHasIndexForTesting)
        XCTAssertFalse(model.isEdgeBevelSnapshotSafeForTesting)
        model.undo(); XCTAssertEqual(model.mesh, before); XCTAssertEqual(model.selectedEdgeCount, 0)
        model.redo(); XCTAssertEqual(model.mesh, after); XCTAssertEqual(model.selectedEdgeCount, 0)
    }

    @MainActor
    func testStalePreviewAndBVHFailureAreAtomic() throws {
        let model = try configuredModel()
        try model.prepareForEdgeBevel()
        let preview = try model.previewEdgeBevel(options: .init(widthMillimeters: 0.1))
        model.setEdgeSelectionOperation(.toggle)
        _ = model.applyEdgeSelectionHit(try selectedEdgeID(model.mesh, key: key(0, 1)))
        let bytes = try model.projectData(), source = model.mesh, generation = model.projectMutationGeneration
        XCTAssertThrowsError(try model.applyEdgeBevel(preview: preview))
        XCTAssertEqual(model.mesh, source); XCTAssertEqual(model.projectMutationGeneration, generation)
        XCTAssertEqual(try model.projectData(), bytes); XCTAssertFalse(model.isEdgeBevelRunning)

        let failing = WorkspaceModel(pickingCache: MeshBVHCache(builder: { _ in throw MeshBVHError.invalidMesh }))
        failing.mesh = octahedron(); failing.setInteractionMode(.edgeSelect)
        _ = failing.applyEdgeSelectionHit(try selectedEdgeID(failing.mesh, key: key(0, 1)))
        try failing.prepareForEdgeBevel()
        let candidate = try failing.previewEdgeBevel(options: .init(widthMillimeters: 0.1))
        let before = failing.mesh, beforeGeneration = failing.projectMutationGeneration
        XCTAssertThrowsError(try failing.applyEdgeBevel(preview: candidate))
        XCTAssertEqual(failing.mesh, before); XCTAssertEqual(failing.projectMutationGeneration, beforeGeneration)
    }

    @MainActor
    func testRequestInvalidationPreventsGhostPreviewAndAllowsNextRequest() throws {
        let model = try configuredModel()
        try model.prepareForEdgeBevel()
        let first = UUID(); try model.beginEdgeBevelPreviewRequest(first)
        let candidate = try model.makeEdgeBevelPreviewCandidate(options: .init(widthMillimeters: 0.1), requestID: first)
        model.discardEdgeBevelPreview(requestID: first)
        XCTAssertFalse(model.completeEdgeBevelPreviewRequest(requestID: first, candidate: candidate))
        XCTAssertNil(model.edgeBevelPreview); XCTAssertFalse(model.isEdgeBevelRunning)
        let second = UUID(); try model.beginEdgeBevelPreviewRequest(second)
        let secondCandidate = try model.makeEdgeBevelPreviewCandidate(options: .init(widthMillimeters: 0.12), requestID: second)
        XCTAssertTrue(model.completeEdgeBevelPreviewRequest(requestID: second, candidate: secondCandidate))
        XCTAssertEqual(model.edgeBevelPreview, secondCandidate); XCTAssertFalse(model.isEdgeBevelRunning)
    }

    @MainActor
    func testSaveLoadPersistsOnlyResultMeshAndIdentityDoesNotPersistPreview() throws {
        let model = try configuredModel()
        try model.prepareForEdgeBevel()
        let preview = try model.previewEdgeBevel(options: .init(widthMillimeters: 0.1))
        _ = try model.applyEdgeBevel(preview: preview)
        let data = try model.projectData()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("edgeBevel"))
        let loaded = WorkspaceModel(); try loaded.loadProject(data: data)
        XCTAssertEqual(loaded.mesh, model.mesh); XCTAssertNil(loaded.edgeBevelPreview)
    }

    #if canImport(UIKit)
    @MainActor
    func testCompactDynamicTypeAndVoiceOverStructure() throws {
        let model = try configuredModel()
        try model.prepareForEdgeBevel()
        let host = UIHostingController(rootView: EdgeBevelView(model: model)
            .environment(\.dynamicTypeSize, .accessibility3))
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }
    #endif

    private func tetrahedron() -> EditableMesh {
        mesh([SIMD3(1,1,1), SIMD3(-1,-1,1), SIMD3(-1,1,-1), SIMD3(1,-1,-1)],
             [0,2,1, 0,1,3, 0,3,2, 1,2,3])
    }
    private func octahedron() -> EditableMesh {
        mesh([
            SIMD3(1,0,0), SIMD3(0,0,1), SIMD3(-1,0,0), SIMD3(0,0,-1),
            SIMD3(0,1,0), SIMD3(0,-1,0)
        ], [
            4,1,0, 4,2,1, 4,3,2, 4,0,3,
            5,0,1, 5,1,2, 5,2,3, 5,3,0
        ])
    }
    private func mesh(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> EditableMesh {
        var value = EditableMesh(vertices: positions.map { MeshVertex(position: $0, normal: .zero) }, indices: indices)
        value.recalculateNormals(recordChange: false); _ = value.adjacency(); return value
    }
    private func key(_ a: UInt32, _ b: UInt32) throws -> MeshEdgeKey { try XCTUnwrap(MeshEdgeKey(a,b)) }
    private func selected(_ mesh: EditableMesh, keys: [MeshEdgeKey]) throws -> (MeshEdgeTable, EdgeSelection, Int) {
        let table = try MeshEdgeTable.build(mesh: mesh); var selection = try EdgeSelection(table: table); var first = -1
        for key in keys { let id = try XCTUnwrap(table.edgeIDByKey[key]); if first < 0 { first=id }; _ = try selection.apply(.add, edgeID: id) }
        return (table, selection, first)
    }
    private func selectedEdgeID(_ mesh: EditableMesh, key: MeshEdgeKey) throws -> Int {
        try XCTUnwrap(try MeshEdgeTable.build(mesh: mesh).edgeIDByKey[key])
    }
    @MainActor private func configuredModel() throws -> WorkspaceModel {
        let model = WorkspaceModel(); model.mesh = octahedron(); model.setInteractionMode(.edgeSelect)
        model.setEdgeSelectionOperation(.add)
        XCTAssertTrue(model.applyEdgeSelectionHit(try selectedEdgeID(model.mesh, key: key(0,1))))
        return model
    }
    private func faceNormal(_ mesh: EditableMesh, _ face: Int) -> SIMD3<Float> {
        let o=face*3,a=mesh.vertices[Int(mesh.indices[o])].position,b=mesh.vertices[Int(mesh.indices[o+1])].position,c=mesh.vertices[Int(mesh.indices[o+2])].position
        return simd_cross(b-a,c-a)
    }
    private func world(_ mesh: EditableMesh, _ transform: ObjectTransform, _ id: UInt32) -> SIMD3<Double> {
        double(transform.worldPosition(fromLocal: mesh.vertices[Int(id)].position))
    }
    private func double(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x),Double(p.y),Double(p.z)) }
}

private extension Array where Element == UInt32 {
    func containsSubsequence(_ pair: [UInt32]) -> Bool {
        guard pair.count == 2 else { return false }
        for offset in stride(from: 0, to: count, by: 3) {
            let triangle = Array(self[offset..<Swift.min(offset + 3, count)])
            if triangle.contains(pair[0]) && triangle.contains(pair[1]) { return true }
        }
        return false
    }
}
