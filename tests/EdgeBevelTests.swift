import XCTest
import SwiftUI
import simd
@testable import Forge3D
#if canImport(UIKit)
import UIKit
import MetalKit
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
        XCTAssertEqual(result.estimate.affectedFaceCount, 6)
        XCTAssertEqual(result.estimate.supportFaceCount, 4)
        XCTAssertEqual(result.estimate.selectedEndpointCount, 2)
        XCTAssertEqual(result.mesh.vertices.count, source.vertices.count + 4)
        XCTAssertEqual(result.mesh.indices.count / 3, source.indices.count / 3 + 8)
        XCTAssertEqual(
            result.mesh.vertices.prefix(source.vertices.count).map(\.position),
            source.vertices.map(\.position))
        let faces = table.edges[edgeID].incidentFaceIDs
        XCTAssertEqual(faces.count, 2)
        let unchangedFaces = (0..<(source.indices.count / 3)).filter {
            Array(result.mesh.indices[($0 * 3)..<($0 * 3 + 3)])
                == Array(source.indices[($0 * 3)..<($0 * 3 + 3)])
        }
        XCTAssertEqual(unchangedFaces.count, 2)
        let appendedStart = source.indices.count
        XCTAssertEqual(
            Array(result.mesh.indices[appendedStart..<(appendedStart + 12)]),
            [6,0,3, 7,4,2, 8,5,3, 9,1,2])
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
        let (table, selection, _) = try selected(source, keys: [try key(0, 1), try key(0, 4)])
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

    func testDisjointComponentsBevelTogetherAndPreserveComponents() throws {
        let source = twoOctahedra()
        let (table, selection, _) = try selected(
            source, keys: [try key(0, 1), try key(6, 7)])
        let result = try EdgeBevel.bevel(
            mesh: source, table: table, selection: selection, transform: .identity,
            options: .init(widthMillimeters: 0.1))
        XCTAssertEqual(result.mesh.vertices.count, source.vertices.count + 8)
        XCTAssertEqual(result.mesh.indices.count / 3, source.indices.count / 3 + 16)
        let report = MeshTopologyDiagnostics.analyze(result.mesh)
        XCTAssertEqual(report.connectedComponentCount, 2)
        XCTAssertEqual(report.boundaryEdgeCount, 0)
        XCTAssertEqual(report.nonManifoldEdgeCount, 0)
        XCTAssertEqual(report.inconsistentWindingEdgeCount, 0)
    }

    func testVertexDisjointEdgesWithTouchingOneRingsAreRejected() throws {
        let source = octahedron()
        let (table, selection, _) = try selected(
            source, keys: [try key(0, 1), try key(2, 3)])
        XCTAssertThrowsError(try EdgeBevel.estimate(
            mesh: source, table: table, selection: selection, transform: .identity,
            options: .init(widthMillimeters: 0.1))) {
            XCTAssertEqual($0 as? EdgeBevelError, .affectedNeighborhoodsOverlap)
        }
    }

    func testMemoryStageAAndStageBUseIndependentCheckedLimits() throws {
        let source=octahedron()
        let (table,selection,_)=try selected(source,keys:[try key(0,1)])
        let stageA=EdgeBevelMemoryInstrumentation()
        XCTAssertThrowsError(try EdgeBevel.estimate(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1),memoryLimit:1,
            instrumentation:stageA)) {
            XCTAssertEqual($0 as? EdgeBevelError,.workingMemoryLimitExceeded)
        }
        XCTAssertEqual(stageA.stageACount,1)
        XCTAssertEqual(stageA.diagnosticsCount,0)
        XCTAssertEqual(stageA.stageBCount,0)

        let full=try EdgeBevel.estimate(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1))
        let stageB=EdgeBevelMemoryInstrumentation()
        XCTAssertThrowsError(try EdgeBevel.estimate(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            memoryLimit:full.estimatedWorkingByteCount-1,
            instrumentation:stageB)) {
            XCTAssertEqual($0 as? EdgeBevelError,.workingMemoryLimitExceeded)
        }
        XCTAssertEqual(stageB.stageACount,1)
        XCTAssertEqual(stageB.diagnosticsCount,1)
        XCTAssertEqual(stageB.stageBCount,1)
        XCTAssertNoThrow(try EdgeBevel.estimate(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            memoryLimit:full.estimatedWorkingByteCount))
    }

    func testStageABoundariesAndArithmeticOverflowWithoutLargeAllocation() throws {
        let counts=try EdgeBevel.stageAWorkingCountsForTesting(
            sourceVertexCount:6,sourceIndexCount:24,edgeCount:12,selectedEdgeCount:1)
        XCTAssertNoThrow(try EdgeBevel.stageAWorkingCountsForTesting(
            sourceVertexCount:6,sourceIndexCount:24,edgeCount:12,selectedEdgeCount:1,
            memoryLimit:counts.bytes))
        XCTAssertThrowsError(try EdgeBevel.stageAWorkingCountsForTesting(
            sourceVertexCount:6,sourceIndexCount:24,edgeCount:12,selectedEdgeCount:1,
            memoryLimit:counts.bytes-1)) {
            XCTAssertEqual($0 as? EdgeBevelError,.workingMemoryLimitExceeded)
        }
        XCTAssertThrowsError(try EdgeBevel.stageAWorkingCountsForTesting(
            sourceVertexCount:0,sourceIndexCount:0,edgeCount:0,
            selectedEdgeCount:Int.max)) {
            XCTAssertEqual($0 as? EdgeBevelError,.arithmeticOverflow)
        }
        XCTAssertThrowsError(try EdgeBevel.stageAWorkingCountsForTesting(
            sourceVertexCount:Int.max,sourceIndexCount:0,edgeCount:0,
            selectedEdgeCount:1)) {
            XCTAssertEqual($0 as? EdgeBevelError,.arithmeticOverflow)
        }
    }

    func testExactAffectedPositionRegistryClassifiesLocalCollisions() throws {
        let sourceA=EdgeBevelAffectedPosition(
            edgeID:1,kind:.source(vertexID:10),localPosition:SIMD3(1,2,3))
        let sourceB=EdgeBevelAffectedPosition(
            edgeID:1,kind:.source(vertexID:11),localPosition:SIMD3(1,2,3))
        XCTAssertThrowsError(try EdgeBevel.validateExactAffectedPositions(
            [sourceA,sourceB],transform:.identity)) {
            XCTAssertEqual($0 as? EdgeBevelError,.collapsedGeometry)
        }
        let crossSource=EdgeBevelAffectedPosition(
            edgeID:2,kind:.source(vertexID:20),localPosition:SIMD3(1,2,3))
        XCTAssertThrowsError(try EdgeBevel.validateExactAffectedPositions(
            [sourceA,crossSource],transform:.identity)) {
            XCTAssertEqual($0 as? EdgeBevelError,.affectedNeighborhoodsOverlap)
        }
        let sameOffset=EdgeBevelAffectedPosition(
            edgeID:1,kind:.offset(edgeID:1,slot:0),localPosition:SIMD3(1,2,3))
        XCTAssertThrowsError(try EdgeBevel.validateExactAffectedPositions(
            [sourceA,sameOffset],transform:.identity)) {
            XCTAssertEqual($0 as? EdgeBevelError,.collapsedGeometry)
        }
        let crossOffset=EdgeBevelAffectedPosition(
            edgeID:2,kind:.offset(edgeID:2,slot:0),localPosition:SIMD3(1,2,3))
        XCTAssertThrowsError(try EdgeBevel.validateExactAffectedPositions(
            [sameOffset,crossOffset],transform:.identity)) {
            XCTAssertEqual($0 as? EdgeBevelError,.affectedNeighborhoodsOverlap)
        }
    }

    func testExactAffectedPositionRegistryCanonicalizesSignedZeroAndRenderedWorld() throws {
        for axis in 0..<3 {
            var positive=SIMD3<Float>(1,2,3), negative=positive
            positive[axis]=0
            negative[axis] = -0.0
            let first=EdgeBevelAffectedPosition(
                edgeID:1,kind:.source(vertexID:1),localPosition:positive)
            XCTAssertNoThrow(try EdgeBevel.validateExactAffectedPositions(
                [first],transform:.identity))
            let second=EdgeBevelAffectedPosition(
                edgeID:2,kind:.source(vertexID:2),localPosition:negative)
            XCTAssertThrowsError(try EdgeBevel.validateExactAffectedPositions(
                [first,second],transform:.identity)) {
                XCTAssertEqual($0 as? EdgeBevelError,.affectedNeighborhoodsOverlap)
            }
        }
        let first=EdgeBevelAffectedPosition(
            edgeID:1,kind:.offset(edgeID:1,slot:0),localPosition:SIMD3(0,0,0))
        let second=EdgeBevelAffectedPosition(
            edgeID:2,kind:.offset(edgeID:2,slot:0),localPosition:SIMD3(1,0,0))
        XCTAssertThrowsError(try EdgeBevel.validateExactAffectedPositions(
            [first,second],transform:ObjectTransform(translation:SIMD3(100_000_000,0,0)))) {
            XCTAssertEqual($0 as? EdgeBevelError,.affectedNeighborhoodsOverlap)
        }
    }

    func testAffectedVertexFanValidatorAcceptsCycleAndRejectsDisconnectedAndOpenFans() throws {
        let healthy=octahedron()
        XCTAssertNoThrow(try EdgeBevel.validateAffectedVertexFans(
            mesh:healthy,affectedVertexIDs:[0]))

        let first=tetrahedron(), offset=UInt32(first.vertices.count-1)
        let secondPositions=Array(first.vertices.dropFirst().map(\.position))
        let bowTie=mesh(
            first.vertices.map(\.position)+secondPositions,
            first.indices+first.indices.map { $0 == 0 ? 0 : $0+offset })
        XCTAssertThrowsError(try EdgeBevel.validateAffectedVertexFans(
            mesh:bowTie,affectedVertexIDs:[0])) {
            XCTAssertEqual($0 as? EdgeBevelError,.validationFailed)
        }

        let open=mesh([SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0)],[0,1,2])
        XCTAssertThrowsError(try EdgeBevel.validateAffectedVertexFans(
            mesh:open,affectedVertexIDs:[0])) {
            XCTAssertEqual($0 as? EdgeBevelError,.validationFailed)
        }

        let nonManifold=mesh(
            [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,-1,0),SIMD3(0,0,1)],
            [0,1,2, 1,0,3, 0,1,4])
        XCTAssertThrowsError(try EdgeBevel.validateAffectedVertexFans(
            mesh:nonManifold,affectedVertexIDs:[0])) {
            XCTAssertEqual($0 as? EdgeBevelError,.validationFailed)
        }
    }

    func testRefinedMemoryAndFingerprintGrowDeterministically() throws {
        let source=octahedron()
        let (table,selection,_)=try selected(source,keys:[try key(0,1)])
        let first=try EdgeBevel.makePreview(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:.init(),transformChangeVersion:.init())
        let repeated=try EdgeBevel.makePreview(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:first.source.meshChangeVersion,
            transformChangeVersion:first.source.transformChangeVersion)
        XCTAssertEqual(first.source.analysisFingerprint,repeated.source.analysisFingerprint)

        let multiple=twoOctahedra()
        let (multipleTable,multipleSelection,_)=try selected(
            multiple,keys:[try key(0,1),try key(6,7)])
        let multipleEstimate=try EdgeBevel.estimate(
            mesh:multiple,table:multipleTable,selection:multipleSelection,
            transform:.identity,options:.init(widthMillimeters:0.1))
        XCTAssertGreaterThan(
            multipleEstimate.estimatedWorkingByteCount,
            first.estimate.estimatedWorkingByteCount)
    }

    func testFingerprintTracksGeometryAndCanonicalizesSelectionOrderAndSignedZero() throws {
        let source=octahedron()
        let (table,selection,_)=try selected(source,keys:[try key(0,1)])
        let original=try EdgeBevel.makePreview(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:.init(),transformChangeVersion:.init())

        var changedPositions=source.vertices.map(\.position)
        changedPositions[2].x = -1.25
        let changed=mesh(changedPositions,source.indices)
        let (changedTable,changedSelection,_)=try selected(changed,keys:[try key(0,1)])
        let changedPreview=try EdgeBevel.makePreview(
            mesh:changed,table:changedTable,selection:changedSelection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:.init(),transformChangeVersion:.init())
        XCTAssertNotEqual(
            original.source.analysisFingerprint,
            changedPreview.source.analysisFingerprint)

        var signedZeroPositions=source.vertices.map(\.position)
        signedZeroPositions[0].y = -0.0
        let signedZero=mesh(signedZeroPositions,source.indices)
        let (zeroTable,zeroSelection,_)=try selected(signedZero,keys:[try key(0,1)])
        let zeroPreview=try EdgeBevel.makePreview(
            mesh:signedZero,table:zeroTable,selection:zeroSelection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:.init(),transformChangeVersion:.init())
        XCTAssertEqual(original.source.analysisFingerprint,zeroPreview.source.analysisFingerprint)

        let multiple=twoOctahedra()
        let (forwardTable,forwardSelection,_)=try selected(
            multiple,keys:[try key(0,1),try key(6,7)])
        let (reverseTable,reverseSelection,_)=try selected(
            multiple,keys:[try key(6,7),try key(0,1)])
        let forward=try EdgeBevel.makePreview(
            mesh:multiple,table:forwardTable,selection:forwardSelection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:.init(),transformChangeVersion:.init())
        let reverse=try EdgeBevel.makePreview(
            mesh:multiple,table:reverseTable,selection:reverseSelection,transform:.identity,
            options:.init(widthMillimeters:0.1),
            meshChangeVersion:.init(),transformChangeVersion:.init())
        XCTAssertEqual(forward.source.analysisFingerprint,reverse.source.analysisFingerprint)
    }

    func testNonFiniteSourceNormalIsRejectedBeforePlanning() throws {
        let healthy=octahedron()
        var vertices=healthy.vertices
        vertices[0]=MeshVertex(position:vertices[0].position,normal:SIMD3(.nan,0,0))
        let source=EditableMesh(vertices:vertices,indices:healthy.indices)
        let table=try MeshEdgeTable.build(mesh:source)
        var selection=try EdgeSelection(table:table)
        let edgeID=try XCTUnwrap(table.edgeIDByKey[try key(0,1)])
        _=try selection.apply(.add,edgeID:edgeID)
        XCTAssertThrowsError(try EdgeBevel.estimate(
            mesh:source,table:table,selection:selection,transform:.identity,
            options:.init(widthMillimeters:0.1))) {
            XCTAssertEqual($0 as? EdgeBevelError,.nonFiniteValue)
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

    @MainActor
    func testApplyUndoRedoAutosaveOrderingUsesCompletedMeshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeBevelAutosave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ProjectAutosaveCoordinator(
            storage: ProjectRecoveryStorage(directoryURL: directory),
            scheduler: EdgeBevelImmediateScheduler(), debounceNanoseconds: 0)
        let model = WorkspaceModel(autosaveCoordinator: coordinator)
        await model.inspectRecoveryOnLaunch(force: true)
        model.mesh = octahedron()
        model.setInteractionMode(.edgeSelect)
        model.setEdgeSelectionOperation(.add)
        XCTAssertTrue(model.applyEdgeSelectionHit(
            try selectedEdgeID(model.mesh, key: key(0, 1))))
        let before = model.mesh
        try model.prepareForEdgeBevel()
        let preview = try model.previewEdgeBevel(options: .init(widthMillimeters: 0.1))
        let after = try model.applyEdgeBevel(preview: preview).mesh
        await waitForWriteCount(1, coordinator: coordinator)
        let recoveryAfterApply = try await coordinator.inspectRecovery()
        XCTAssertEqual(recoveryAfterApply.project.mesh, after)
        model.undo()
        await waitForWriteCount(2, coordinator: coordinator)
        let recoveryAfterUndo = try await coordinator.inspectRecovery()
        XCTAssertEqual(recoveryAfterUndo.project.mesh, before)
        model.redo()
        await waitForWriteCount(3, coordinator: coordinator)
        let recoveryAfterRedo = try await coordinator.inspectRecovery()
        XCTAssertEqual(recoveryAfterRedo.project.mesh, after)
        let writeCount = await coordinator.successfulWriteCount
        XCTAssertEqual(writeCount, 3)
    }

    #if canImport(UIKit)
    @MainActor
    func testSuccessfulInstallUploadsTopologyOnce() throws {
        #if targetEnvironment(simulator)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let profiler = PerformanceProfiler()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        let model = try configuredModel()
        renderer.update(mesh: model.mesh)
        profiler.reset(
            vertexCount: model.mesh.vertices.count,
            triangleCount: model.mesh.indices.count / 3)
        try model.prepareForEdgeBevel()
        let preview = try model.previewEdgeBevel(options: .init(widthMillimeters: 0.1))
        _ = try model.applyEdgeBevel(preview: preview)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: model.mesh)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        #endif
    }
    #endif

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
    private func twoOctahedra() -> EditableMesh {
        let first = octahedron()
        let offset = UInt32(first.vertices.count)
        let secondPositions = first.vertices.map { $0.position + SIMD3<Float>(4, 0, 0) }
        return mesh(
            first.vertices.map(\.position) + secondPositions,
            first.indices + first.indices.map { $0 + offset })
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

private struct EdgeBevelImmediateScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
