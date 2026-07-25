import Foundation
import simd

struct EdgeBevelOptions: Equatable {
    static let defaultWidthMillimeters = 0.5
    static let minimumWidthMillimeters = 0.001
    static let maximumWidthMillimeters = 1_000.0
    var widthMillimeters = defaultWidthMillimeters
}

struct EdgeBevelEstimate: Equatable {
    let selectedEdgeCount: Int
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let componentCount: Int
    let boundaryEdgeCount: Int
    let maximumSafeWidthMillimeters: Double
    let estimatedWorkingByteCount: Int
    let resultBounds: AxisAlignedBoundingBox
}

struct EdgeBevelSourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: TopologyEditChangeVersion
    let transformChangeVersion: TopologyEditChangeVersion
    let transform: ObjectTransform
    let edgeTableFingerprint: UInt64
    let selectionVersion: EdgeSelectionVersion
    let selectedEdgeIDs: [Int]
    let selectedEdgeFingerprint: UInt64
    let options: EdgeBevelOptions
    let analysisFingerprint: UInt64

    func matchesRuntimeIdentity(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                                transform: ObjectTransform, meshChangeVersion: TopologyEditChangeVersion,
                                transformChangeVersion: TopologyEditChangeVersion,
                                options: EdgeBevelOptions) -> Bool {
        topologyID == mesh.runtime.topologyID && topologyRevision == mesh.runtime.topologyRevision
            && vertexRevision == mesh.runtime.revision && self.meshChangeVersion == meshChangeVersion
            && self.transformChangeVersion == transformChangeVersion && self.transform == transform.sanitized()
            && edgeTableFingerprint == table.fingerprint && selectionVersion == selection.version
            && selectedEdgeIDs == selection.selectedEdgeIDs() && self.options == options
    }
}

struct EdgeBevelPreview: Equatable { let options: EdgeBevelOptions; let estimate: EdgeBevelEstimate; let source: EdgeBevelSourceKey }
struct EdgeBevelResult: Equatable { let mesh: EditableMesh; let estimate: EdgeBevelEstimate; let analysisFingerprint: UInt64 }

enum EdgeBevelError: Error, Equatable, LocalizedError {
    case noSelection, staleSelection, invalidWidth, widthTooSmall, widthLimitExceeded, widthExceedsSafeMaximum
    case invalidMesh, nonFiniteValue, boundaryEdge, nonManifoldEdge, adjacentSelectedEdges, sharedIncidentFace
    case boundaryEndpoint, nonManifoldEndpoint, coplanarEdge, collapsedGeometry, storedFloatPrecisionFailure
    case arithmeticOverflow, vertexLimitExceeded, triangleLimitExceeded, workingMemoryLimitExceeded
    case validationFailed, stalePreview, operationInProgress, activeEdit, unavailable
    var errorDescription: String? {
        switch self {
        case .noSelection: "Select at least one isolated interior edge."
        case .staleSelection: "The edge selection belongs to an older topology."
        case .invalidWidth: "Enter a finite positive bevel width in millimeters."
        case .widthTooSmall: "Edge Bevel width must be at least 0.001 mm."
        case .widthLimitExceeded: "Edge Bevel width must not exceed 1000 mm."
        case .widthExceedsSafeMaximum: "The width exceeds the selected edges' safe face-altitude limit."
        case .invalidMesh: "Edge Bevel requires a valid indexed triangle mesh."
        case .nonFiniteValue: "Edge Bevel requires finite geometry and Transform values."
        case .boundaryEdge: "Boundary edges are not supported."
        case .nonManifoldEdge: "Only manifold interior edges are supported."
        case .adjacentSelectedEdges: "Selected edges must not share a vertex."
        case .sharedIncidentFace: "A face may touch only one selected edge."
        case .boundaryEndpoint: "Selected edge endpoints must not touch a mesh boundary."
        case .nonManifoldEndpoint: "Selected edge endpoints must have one manifold vertex fan."
        case .coplanarEdge: "Coplanar or near-coplanar incident faces are not beveled."
        case .collapsedGeometry: "The bevel would collapse or invert stored geometry."
        case .storedFloatPrecisionFailure: "Stored Float positions cannot preserve the requested world-space width."
        case .arithmeticOverflow: "Edge Bevel size calculation overflowed."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .workingMemoryLimitExceeded: "Edge Bevel would exceed the 768 MiB working-memory limit."
        case .validationFailed: "The bevel result failed topology or geometry validation."
        case .stalePreview: "The mesh, Transform, selection, or width changed. Recalculate Preview."
        case .operationInProgress: "Edge Bevel is already running."
        case .activeEdit: "Finish the active edit before beveling."
        case .unavailable: "Edge Bevel is unavailable during the current operation."
        }
    }
}

enum EdgeBevel {
    static let maximumVertices = 2_000_000, maximumTriangles = 4_000_000
    static let maximumWorkingBytes = 768 * 1_024 * 1_024
    private struct Item { let record: MeshEdgeRecord; let faces: [Int]; let opposite: [UInt32]; let local: [SIMD3<Float>]; let maxWidth: Double; let face0UsesLowToHigh: Bool }
    private struct Plan { let items: [Item]; let estimate: EdgeBevelEstimate; let fingerprint: UInt64 }

    static func makePreview(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                            transform: ObjectTransform, options: EdgeBevelOptions,
                            meshChangeVersion: TopologyEditChangeVersion,
                            transformChangeVersion: TopologyEditChangeVersion) throws -> EdgeBevelPreview {
        let plan = try makePlan(mesh: mesh, table: table, selection: selection, transform: transform, options: options)
        let ids = selection.selectedEdgeIDs()
        return EdgeBevelPreview(options: options, estimate: plan.estimate, source: EdgeBevelSourceKey(
            topologyID: mesh.runtime.topologyID, topologyRevision: mesh.runtime.topologyRevision,
            vertexRevision: mesh.runtime.revision, meshChangeVersion: meshChangeVersion,
            transformChangeVersion: transformChangeVersion, transform: transform.sanitized(),
            edgeTableFingerprint: table.fingerprint, selectionVersion: selection.version,
            selectedEdgeIDs: ids, selectedEdgeFingerprint: fingerprint(ids), options: options,
            analysisFingerprint: plan.fingerprint))
    }

    static func estimate(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                         transform: ObjectTransform, options: EdgeBevelOptions) throws -> EdgeBevelEstimate {
        try makePlan(mesh: mesh, table: table, selection: selection, transform: transform, options: options).estimate
    }

    static func bevel(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                      transform: ObjectTransform, options: EdgeBevelOptions) throws -> EdgeBevelResult {
        let plan = try makePlan(mesh: mesh, table: table, selection: selection, transform: transform, options: options)
        var vertices = mesh.vertices, indices = mesh.indices
        vertices.reserveCapacity(plan.estimate.resultingVertexCount)
        indices.reserveCapacity(plan.estimate.resultingTriangleCount * 3)
        for item in plan.items {
            let base = UInt32(vertices.count)
            for p in item.local { vertices.append(MeshVertex(position: p, normal: .zero)) }
            for side in 0..<2 {
                let face = item.faces[side], offset = face * 3
                let lowOffset = side == 0 ? base : base + 2
                let highOffset = side == 0 ? base + 1 : base + 3
                let source = Array(mesh.indices[offset..<(offset + 3)])
                let trimmed = source.map { index -> UInt32 in
                    if index == item.record.key.low { return lowOffset }
                    if index == item.record.key.high { return highOffset }
                    return index
                }
                indices.replaceSubrange(offset..<(offset + 3), with: trimmed)
            }
            let low = item.record.key.low, high = item.record.key.high
            var appended: [[UInt32]] = [
                [base, base + 1, base + 3], [base, base + 3, base + 2],
                [low, base, base + 2], [high, base + 3, base + 1]
            ]
            if item.face0UsesLowToHigh { appended = appended.map { [$0[0], $0[2], $0[1]] } }
            for triangle in appended { indices.append(contentsOf: triangle) }
        }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals(recordChange: false); _ = result.adjacency()
        let report = MeshTopologyDiagnostics.analyze(result)
        guard report.degenerateTriangleCount == 0, report.duplicateTriangleCount == 0,
              report.nonManifoldEdgeCount == 0, report.inconsistentWindingEdgeCount == 0,
              report.connectedComponentCount == plan.estimate.componentCount,
              report.boundaryEdgeCount == plan.estimate.boundaryEdgeCount else { throw EdgeBevelError.validationFailed }
        return EdgeBevelResult(mesh: result, estimate: plan.estimate, analysisFingerprint: plan.fingerprint)
    }

    private static func makePlan(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                                 transform: ObjectTransform, options: EdgeBevelOptions) throws -> Plan {
        guard options.widthMillimeters.isFinite else { throw EdgeBevelError.invalidWidth }
        guard options.widthMillimeters >= EdgeBevelOptions.minimumWidthMillimeters else { throw EdgeBevelError.widthTooSmall }
        guard options.widthMillimeters <= EdgeBevelOptions.maximumWidthMillimeters else { throw EdgeBevelError.widthLimitExceeded }
        guard table.matches(mesh), selection.matches(table) else { throw EdgeBevelError.staleSelection }
        let ids = selection.selectedEdgeIDs(); guard !ids.isEmpty else { throw EdgeBevelError.noSelection }
        guard transform.isFinite, mesh.indices.count.isMultiple(of: 3), mesh.vertices.allSatisfy({ $0.position.allFinite }) else { throw EdgeBevelError.nonFiniteValue }
        let sourceReport = MeshTopologyDiagnostics.analyze(mesh)
        guard sourceReport.invalidIndexTriangleCount == 0, sourceReport.degenerateTriangleCount == 0,
              sourceReport.duplicateTriangleCount == 0, sourceReport.nonManifoldEdgeCount == 0,
              sourceReport.inconsistentWindingEdgeCount == 0 else { throw EdgeBevelError.invalidMesh }
        var selectedVertices=Set<UInt32>(), selectedFaces=Set<Int>(), items:[Item]=[]; var maxWidth=Double.greatestFiniteMagnitude
        for id in ids.sorted() {
            guard table.edges.indices.contains(id) else { throw EdgeBevelError.staleSelection }
            let edge=table.edges[id]; guard edge.classification == .manifoldInterior else {
                throw edge.classification == .boundary ? EdgeBevelError.boundaryEdge : EdgeBevelError.nonManifoldEdge }
            guard selectedVertices.insert(edge.key.low).inserted, selectedVertices.insert(edge.key.high).inserted else { throw EdgeBevelError.adjacentSelectedEdges }
            let faces=edge.incidentFaceIDs.sorted(); guard faces.allSatisfy({ selectedFaces.insert($0).inserted }) else { throw EdgeBevelError.sharedIncidentFace }
            for endpoint in [edge.key.low, edge.key.high] {
                try validateEndpointFan(endpoint, table: table)
            }
            let face0Use = try directedUse(mesh, face: faces[0], edge: edge.key)
            let face1Use = try directedUse(mesh, face: faces[1], edge: edge.key)
            guard face0Use != face1Use else { throw EdgeBevelError.validationFailed }
            let opposite = try faces.map { try oppositeVertex(mesh, face: $0, edge: edge.key) }
            let wa=world(mesh.vertices[Int(edge.key.low)].position, transform), wb=world(mesh.vertices[Int(edge.key.high)].position, transform)
            let e=wb-wa, el=simd_length(e); guard el.isFinite,el>1e-9 else { throw EdgeBevelError.collapsedGeometry }; let u=e/el
            var local:[SIMD3<Float>]=[]; var normals:[SIMD3<Double>]=[]; var edgeMax=Double.greatestFiniteMagnitude
            for o in opposite {
                let wc=world(mesh.vertices[Int(o)].position,transform); let rel=wc-wa; let perp=rel-u*simd_dot(rel,u); let altitude=simd_length(perp)
                guard altitude.isFinite, altitude > 1e-9 else { throw EdgeBevelError.collapsedGeometry }
                let dir=perp/altitude; edgeMax=min(edgeMax, altitude-max(altitude * 1e-6, 1e-6)); normals.append(simd_normalize(simd_cross(e,wc-wa)))
                let t = options.widthMillimeters / altitude
                guard t > 0, t < 1 else { throw EdgeBevelError.widthExceedsSafeMaximum }
                for p in [wa + (wc - wa) * t, wb + (wc - wb) * t] { let lp=localFloat(p,transform); let actual=world(lp,transform); let d=simd_length((actual-wa)-u*simd_dot(actual-wa,u)); let tol=max(1e-5,options.widthMillimeters*1e-4); guard abs(d-options.widthMillimeters)<=tol else { throw EdgeBevelError.storedFloatPrecisionFailure }; local.append(lp) }
            }
            guard abs(simd_dot(normals[0],normals[1])) < 0.999_9 else { throw EdgeBevelError.coplanarEdge }
            maxWidth=min(maxWidth,edgeMax); let face0UsesLowToHigh = face0Use
            items.append(Item(record: edge, faces: faces, opposite: opposite, local: local, maxWidth: edgeMax, face0UsesLowToHigh: face0UsesLowToHigh))
        }
        guard options.widthMillimeters < maxWidth else { throw EdgeBevelError.widthExceedsSafeMaximum }
        let (addV,ov1)=ids.count.multipliedReportingOverflow(by:4), (addT,ov2)=ids.count.multipliedReportingOverflow(by:4)
        let (rv,ov3)=mesh.vertices.count.addingReportingOverflow(addV), (rt,ov4)=(mesh.indices.count/3).addingReportingOverflow(addT)
        guard !ov1,!ov2,!ov3,!ov4 else { throw EdgeBevelError.arithmeticOverflow }; guard rv<=maximumVertices else { throw EdgeBevelError.vertexLimitExceeded }; guard rt<=maximumTriangles else { throw EdgeBevelError.triangleLimitExceeded }
        let bytes=rv*32+rt*24+table.edges.count*32; guard bytes<=maximumWorkingBytes else { throw EdgeBevelError.workingMemoryLimitExceeded }
        var bounds=AxisAlignedBoundingBox(); for v in mesh.vertices { bounds.include(transform.worldPosition(fromLocal:v.position)) }; for i in items { for p in i.local { bounds.include(transform.worldPosition(fromLocal:p)) } }
        var fp=fingerprint(ids); fp ^= options.widthMillimeters.bitPattern; fp &*= 1099511628211
        return Plan(items:items, estimate:EdgeBevelEstimate(selectedEdgeCount:ids.count,originalVertexCount:mesh.vertices.count,originalTriangleCount:mesh.indices.count/3,resultingVertexCount:rv,resultingTriangleCount:rt,componentCount:sourceReport.connectedComponentCount,boundaryEdgeCount:sourceReport.boundaryEdgeCount,maximumSafeWidthMillimeters:maxWidth,estimatedWorkingByteCount:bytes,resultBounds:bounds), fingerprint:fp)
    }

    private static func world(_ p: SIMD3<Float>, _ t:ObjectTransform)->SIMD3<Double>{let q=t.worldPosition(fromLocal:p);return SIMD3(Double(q.x),Double(q.y),Double(q.z))}
    private static func localFloat(_ point: SIMD3<Double>, _ transform: ObjectTransform) -> SIMD3<Float> {
        let matrix = transform.inverseModelMatrix
        let x = Double(matrix.columns.0.x) * point.x + Double(matrix.columns.1.x) * point.y
            + Double(matrix.columns.2.x) * point.z + Double(matrix.columns.3.x)
        let y = Double(matrix.columns.0.y) * point.x + Double(matrix.columns.1.y) * point.y
            + Double(matrix.columns.2.y) * point.z + Double(matrix.columns.3.y)
        let z = Double(matrix.columns.0.z) * point.x + Double(matrix.columns.1.z) * point.y
            + Double(matrix.columns.2.z) * point.z + Double(matrix.columns.3.z)
        let w = Double(matrix.columns.0.w) * point.x + Double(matrix.columns.1.w) * point.y
            + Double(matrix.columns.2.w) * point.z + Double(matrix.columns.3.w)
        guard [x, y, z, w].allSatisfy(\.isFinite), abs(w) > 1e-12 else { return .zero }
        return SIMD3<Float>(Float(x / w), Float(y / w), Float(z / w))
    }
    private static func validateEndpointFan(_ vertexID: UInt32, table: MeshEdgeTable) throws {
        guard Int(vertexID) < table.edgeIDsByVertexID.count else { throw EdgeBevelError.invalidMesh }
        let edgeIDs = table.edgeIDsByVertexID[Int(vertexID)]
        guard !edgeIDs.isEmpty else { throw EdgeBevelError.nonManifoldEndpoint }
        var incidentFaces = Set<Int>()
        var adjacency: [Int: Set<Int>] = [:]
        for edgeID in edgeIDs {
            guard table.edges.indices.contains(edgeID) else { throw EdgeBevelError.invalidMesh }
            let record = table.edges[edgeID]
            if record.classification == .boundary { throw EdgeBevelError.boundaryEndpoint }
            guard record.classification == .manifoldInterior, record.incidentFaceIDs.count == 2 else {
                throw EdgeBevelError.nonManifoldEndpoint
            }
            let first = record.incidentFaceIDs[0], second = record.incidentFaceIDs[1]
            incidentFaces.insert(first); incidentFaces.insert(second)
            adjacency[first, default: []].insert(second)
            adjacency[second, default: []].insert(first)
        }
        guard let seed = incidentFaces.min() else { throw EdgeBevelError.nonManifoldEndpoint }
        var visited: Set<Int> = [seed], queue = [seed], cursor = 0
        while cursor < queue.count {
            let face = queue[cursor]; cursor += 1
            for neighbor in adjacency[face, default: []].sorted() where visited.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }
        guard visited.count == incidentFaces.count else { throw EdgeBevelError.nonManifoldEndpoint }
    }
    private static func directedUse(_ mesh: EditableMesh, face: Int, edge: MeshEdgeKey) throws -> Bool {
        let offset = face * 3
        guard offset + 2 < mesh.indices.count else { throw EdgeBevelError.invalidMesh }
        let triangle = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
        for index in 0..<3 {
            let first = triangle[index], second = triangle[(index + 1) % 3]
            if first == edge.low && second == edge.high { return true }
            if first == edge.high && second == edge.low { return false }
        }
        throw EdgeBevelError.invalidMesh
    }
    private static func oppositeVertex(_ m:EditableMesh,face:Int,edge:MeshEdgeKey)throws->UInt32{let o=face*3;guard o+2<m.indices.count else{throw EdgeBevelError.invalidMesh};guard let v=[m.indices[o],m.indices[o+1],m.indices[o+2]].first(where:{$0 != edge.low && $0 != edge.high})else{throw EdgeBevelError.invalidMesh};return v}
    private static func faceNormal(_ m:EditableMesh,_ f:Int)->SIMD3<Float>{let o=f*3,a=m.vertices[Int(m.indices[o])].position,b=m.vertices[Int(m.indices[o+1])].position,c=m.vertices[Int(m.indices[o+2])].position;return simd_cross(b-a,c-a)}
    private static func orientedTriangle(_ a:UInt32,_ b:UInt32,_ c:UInt32,reference:SIMD3<Float>,vertices:[MeshVertex])->[UInt32]{let n=simd_cross(vertices[Int(b)].position-vertices[Int(a)].position,vertices[Int(c)].position-vertices[Int(a)].position);return simd_dot(n,reference)>=0 ? [a,b,c]:[a,c,b]}
    private static func stripReference(_ i:Item,_ m:EditableMesh,_ t:ObjectTransform)->SIMD3<Float>{faceNormal(m,i.faces[0])+faceNormal(m,i.faces[1])}
    private static func capReference(_ endpoint:UInt32,_ i:Item,_ m:EditableMesh)->SIMD3<Float>{faceNormal(m,i.faces[0])+faceNormal(m,i.faces[1])}
    private static func fingerprint(_ ids:[Int])->UInt64{ids.reduce(1469598103934665603){($0 ^ UInt64($1)) &* 1099511628211}}
}