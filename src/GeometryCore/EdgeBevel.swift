import Foundation
import simd

private func canonicalFloatBitPattern(_ value: Float) -> UInt32 {
    value == 0 ? 0 : value.bitPattern
}

struct EdgeBevelOptions: Equatable {
    static let defaultWidthMillimeters = 0.5
    static let minimumWidthMillimeters = 0.001
    static let maximumWidthMillimeters = 1_000.0
    var widthMillimeters = defaultWidthMillimeters
}

final class EdgeBevelMemoryInstrumentation {
    private(set) var stageACount = 0
    private(set) var diagnosticsCount = 0
    private(set) var stageBCount = 0
    fileprivate func recordStageA() { stageACount += 1 }
    fileprivate func recordDiagnostics() { diagnosticsCount += 1 }
    fileprivate func recordStageB() { stageBCount += 1 }
}

private struct ExactPositionKey: Hashable {
    let x: UInt32
    let y: UInt32
    let z: UInt32
    init(_ position: SIMD3<Float>) {
        x=canonicalFloatBitPattern(position.x)
        y=canonicalFloatBitPattern(position.y)
        z=canonicalFloatBitPattern(position.z)
    }
}

enum EdgeBevelAffectedPositionKind: Equatable {
    case source(vertexID: UInt32)
    case offset(edgeID: Int, slot: Int)
}

struct EdgeBevelAffectedPosition: Equatable {
    let edgeID: Int
    let kind: EdgeBevelAffectedPositionKind
    let localPosition: SIMD3<Float>
}
struct EdgeBevelEstimate: Equatable {
    let selectedEdgeCount: Int
    let affectedFaceCount: Int
    let supportFaceCount: Int
    let selectedEndpointCount: Int
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let minimumSelectedEdgeLengthMillimeters: Double
    let maximumSelectedEdgeLengthMillimeters: Double
    let minimumIncidentAltitudeMillimeters: Double
    let maximumSafeWidthMillimeters: Double
    let limitingEdgeID: Int
    let limitingFaceID: Int
    let widthToleranceMillimeters: Double
    let maximumMeasuredWidthErrorMillimeters: Double
    let estimatedWorkingByteCount: Int
    let sourceLocalBounds: AxisAlignedBoundingBox
    let resultLocalBounds: AxisAlignedBoundingBox
    let sourceWorldBounds: AxisAlignedBoundingBox
    let resultWorldBounds: AxisAlignedBoundingBox
    let sourceComponentCount: Int
    let resultComponentCount: Int
    let sourceBoundaryEdgeCount: Int
    let resultBoundaryEdgeCount: Int
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
    case endpointMiterRequired, affectedNeighborhoodsOverlap, invalidBevelCavity
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
        case .endpointMiterRequired: "Endpoint valence or support topology requires a corner miter, which is not supported."
        case .affectedNeighborhoodsOverlap: "Selected edge one-ring neighborhoods must be completely disjoint."
        case .invalidBevelCavity: "The affected faces do not form one simple six-edge bevel cavity."
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
    private struct Support {
        let sideEdge: MeshEdgeKey
        let incidentFace: Int
        let supportFace: Int
        let thirdVertex: UInt32
        let insertedVertexSlot: Int
    }
    private struct Item {
        let record: MeshEdgeRecord
        let faces: [Int]
        let opposite: [UInt32]
        let supports: [Support]
        let local: [SIMD3<Float>]
        let maxWidth: Double
        let minimumAltitude: Double
        let edgeLength: Double
        let widthTolerance: Double
        let maximumWidthError: Double
        let affectedSourceVertices: [UInt32]
    }
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
                         transform: ObjectTransform, options: EdgeBevelOptions,
                         memoryLimit: Int = maximumWorkingBytes,
                         instrumentation: EdgeBevelMemoryInstrumentation? = nil) throws -> EdgeBevelEstimate {
        try makePlan(mesh: mesh, table: table, selection: selection, transform: transform,
                     options: options, memoryLimit: memoryLimit,
                     instrumentation: instrumentation).estimate
    }

    static func bevel(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                      transform: ObjectTransform, options: EdgeBevelOptions) throws -> EdgeBevelResult {
        let plan = try makePlan(mesh: mesh, table: table, selection: selection, transform: transform, options: options)
        var vertices = mesh.vertices
        vertices.reserveCapacity(plan.estimate.resultingVertexCount)
        for item in plan.items {
            for p in item.local { vertices.append(MeshVertex(position: p, normal: .zero)) }
        }
        let indices = try plannedIndices(mesh: mesh, items: plan.items)
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals(recordChange: false); _ = result.adjacency()
        let report = MeshTopologyDiagnostics.analyze(result)
        guard report.degenerateTriangleCount == 0, report.duplicateTriangleCount == 0,
              report.nonManifoldEdgeCount == 0, report.inconsistentWindingEdgeCount == 0,
              report.invalidIndexTriangleCount == 0, report.isolatedVertexCount == 0,
              report.connectedComponentCount == plan.estimate.sourceComponentCount,
              report.boundaryEdgeCount == plan.estimate.sourceBoundaryEdgeCount,
              MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(result) == false
        else { throw EdgeBevelError.validationFailed }
        var affected = Set<UInt32>()
        var affectedPositions: [EdgeBevelAffectedPosition] = []
        for (itemIndex, item) in plan.items.enumerated() {
            affected.formUnion(item.affectedSourceVertices)
            let base = UInt32(mesh.vertices.count + itemIndex * 4)
            affected.formUnion([base, base + 1, base + 2, base + 3])
            for vertexID in item.affectedSourceVertices.sorted() {
                affectedPositions.append(EdgeBevelAffectedPosition(
                    edgeID: item.record.id, kind: .source(vertexID: vertexID),
                    localPosition: result.vertices[Int(vertexID)].position))
            }
            for slot in 0..<4 {
                affectedPositions.append(EdgeBevelAffectedPosition(
                    edgeID: item.record.id, kind: .offset(edgeID: item.record.id, slot: slot),
                    localPosition: result.vertices[Int(base) + slot].position))
            }
        }
        try validateExactAffectedPositions(affectedPositions, transform: transform)
        try validateAffectedVertexFans(mesh: result, affectedVertexIDs: affected)
        return EdgeBevelResult(mesh: result, estimate: plan.estimate, analysisFingerprint: plan.fingerprint)
    }

    private static func makePlan(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                                 transform: ObjectTransform, options: EdgeBevelOptions,
                                 memoryLimit: Int = maximumWorkingBytes,
                                 instrumentation: EdgeBevelMemoryInstrumentation? = nil) throws -> Plan {
        guard options.widthMillimeters.isFinite else { throw EdgeBevelError.invalidWidth }
        guard options.widthMillimeters >= EdgeBevelOptions.minimumWidthMillimeters else { throw EdgeBevelError.widthTooSmall }
        guard options.widthMillimeters <= EdgeBevelOptions.maximumWidthMillimeters else { throw EdgeBevelError.widthLimitExceeded }
        guard table.matches(mesh), selection.matches(table) else { throw EdgeBevelError.staleSelection }
        let ids = selection.selectedEdgeIDs(); guard !ids.isEmpty else { throw EdgeBevelError.noSelection }
        guard transform.isFinite, transform.translation.allFinite,
              transform.rotation.x.isFinite, transform.rotation.y.isFinite,
              transform.rotation.z.isFinite, transform.rotation.w.isFinite,
              transform.scale.allFinite,
              transform.scale.x > 0, transform.scale.y > 0, transform.scale.z > 0,
              mesh.indices.count.isMultiple(of: 3),
              mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite })
        else { throw EdgeBevelError.nonFiniteValue }
        instrumentation?.recordStageA()
        let preflight = try memoryPreflight(
            mesh: mesh, table: table, selectedEdgeCount: ids.count,
            memoryLimit: memoryLimit)
        let localBounds=mesh.bounds
        guard localBounds.minimum.allFinite, localBounds.maximum.allFinite else {
            throw EdgeBevelError.nonFiniteValue
        }
        var sourceWorldBounds=AxisAlignedBoundingBox()
        for vertex in mesh.vertices {
            let worldPosition=transform.worldPosition(fromLocal:vertex.position)
            guard worldPosition.allFinite else { throw EdgeBevelError.nonFiniteValue }
            sourceWorldBounds.include(worldPosition)
        }
        guard sourceWorldBounds.minimum.allFinite, sourceWorldBounds.maximum.allFinite else {
            throw EdgeBevelError.nonFiniteValue
        }
        instrumentation?.recordDiagnostics()
        let sourceReport = MeshTopologyDiagnostics.analyze(mesh)
        guard sourceReport.invalidIndexTriangleCount == 0, sourceReport.degenerateTriangleCount == 0,
              sourceReport.duplicateTriangleCount == 0, sourceReport.nonManifoldEdgeCount == 0,
              sourceReport.inconsistentWindingEdgeCount == 0, sourceReport.isolatedVertexCount == 0,
              MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(mesh) == false
        else { throw EdgeBevelError.invalidMesh }
        var selectedVertices=Set<UInt32>(), affectedFaces=Set<Int>(), affectedVertices=Set<UInt32>()
        var items:[Item]=[]
        var maxWidth=Double.greatestFiniteMagnitude, limitingEdge = -1, limitingFace = -1
        var minLength=Double.greatestFiniteMagnitude, maxLength=0.0
        var minAltitude=Double.greatestFiniteMagnitude, maxError=0.0, sharedTolerance=0.0
        for id in ids.sorted() {
            guard table.edges.indices.contains(id) else { throw EdgeBevelError.staleSelection }
            let edge=table.edges[id]; guard edge.classification == .manifoldInterior else {
                throw edge.classification == .boundary ? EdgeBevelError.boundaryEdge : EdgeBevelError.nonManifoldEdge }
            guard selectedVertices.insert(edge.key.low).inserted, selectedVertices.insert(edge.key.high).inserted else { throw EdgeBevelError.adjacentSelectedEdges }
            let faces=edge.incidentFaceIDs.sorted()
            guard faces.count == 2 else { throw EdgeBevelError.nonManifoldEdge }
            for endpoint in [edge.key.low, edge.key.high] {
                let valence = try validateEndpointFan(endpoint, table: table)
                guard valence >= 4 else { throw EdgeBevelError.endpointMiterRequired }
            }
            let face0Use = try directedUse(mesh, face: faces[0], edge: edge.key)
            let face1Use = try directedUse(mesh, face: faces[1], edge: edge.key)
            guard face0Use != face1Use else { throw EdgeBevelError.validationFailed }
            let opposite = try faces.map { try oppositeVertex(mesh, face: $0, edge: edge.key) }
            guard opposite[0] != opposite[1] else { throw EdgeBevelError.endpointMiterRequired }
            let sideDefinitions: [(UInt32, UInt32, Int, Int)] = [
                (edge.key.low, opposite[0], faces[0], 0),
                (edge.key.high, opposite[0], faces[0], 1),
                (edge.key.low, opposite[1], faces[1], 2),
                (edge.key.high, opposite[1], faces[1], 3)
            ]
            var supports: [Support] = []
            var localSupportFaces = Set<Int>()
            for (endpoint, oppositeVertexID, incidentFace, slot) in sideDefinitions {
                guard let sideKey = MeshEdgeKey(endpoint, oppositeVertexID),
                      let sideID = table.edgeIDByKey[sideKey],
                      table.edges.indices.contains(sideID)
                else { throw EdgeBevelError.invalidBevelCavity }
                let side = table.edges[sideID]
                guard side.classification == .manifoldInterior, side.incidentFaceIDs.count == 2,
                      side.incidentFaceIDs.contains(incidentFace),
                      let supportFace = side.incidentFaceIDs.first(where: { $0 != incidentFace })
                else { throw EdgeBevelError.endpointMiterRequired }
                guard localSupportFaces.insert(supportFace).inserted,
                      !faces.contains(supportFace)
                else { throw EdgeBevelError.endpointMiterRequired }
                let incidentUse = try directedUse(mesh, face: incidentFace, edge: sideKey)
                let supportUse = try directedUse(mesh, face: supportFace, edge: sideKey)
                guard incidentUse != supportUse else { throw EdgeBevelError.invalidBevelCavity }
                let third = try oppositeVertex(mesh, face: supportFace, edge: sideKey)
                supports.append(Support(
                    sideEdge: sideKey, incidentFace: incidentFace,
                    supportFace: supportFace, thirdVertex: third,
                    insertedVertexSlot: slot))
            }
            let localFaces = Set(faces).union(localSupportFaces)
            guard localFaces.count == 6 else { throw EdgeBevelError.endpointMiterRequired }
            guard localFaces.isDisjoint(with: affectedFaces) else { throw EdgeBevelError.affectedNeighborhoodsOverlap }
            var localAffectedVertices = Set<UInt32>()
            for face in localFaces {
                localAffectedVertices.formUnion(try triangle(mesh, face: face))
            }
            guard localAffectedVertices.isDisjoint(with: affectedVertices) else {
                throw EdgeBevelError.affectedNeighborhoodsOverlap
            }
            affectedFaces.formUnion(localFaces)
            affectedVertices.formUnion(localAffectedVertices)

            let wa=world(mesh.vertices[Int(edge.key.low)].position, transform), wb=world(mesh.vertices[Int(edge.key.high)].position, transform)
            let e=wb-wa, el=simd_length(e); guard el.isFinite,el>1e-9 else { throw EdgeBevelError.collapsedGeometry }; let u=e/el
            minLength=min(minLength,el); maxLength=max(maxLength,el)
            var local:[SIMD3<Float>]=[]; var normals:[SIMD3<Double>]=[]
            var edgeMax=Double.greatestFiniteMagnitude, edgeMinimumAltitude=Double.greatestFiniteMagnitude
            var edgeTolerance=0.0, edgeMaximumError=0.0
            for (side, o) in opposite.enumerated() {
                let wc=world(mesh.vertices[Int(o)].position,transform); let rel=wc-wa; let perp=rel-u*simd_dot(rel,u); let altitude=simd_length(perp)
                guard altitude.isFinite, altitude > 1e-9 else { throw EdgeBevelError.collapsedGeometry }
                let coordinateTolerance = max(
                    floatULP(at: wa), floatULP(at: wb), floatULP(at: wc)) * 4
                let tolerance=max(max(max(altitude, el) * 1e-6, coordinateTolerance), 1e-6)
                let candidateMaximum=altitude-tolerance
                if candidateMaximum < edgeMax {
                    edgeMax=candidateMaximum
                    if candidateMaximum < maxWidth { limitingEdge=id; limitingFace=faces[side] }
                }
                edgeMinimumAltitude=min(edgeMinimumAltitude,altitude)
                edgeTolerance=max(edgeTolerance,tolerance)
                normals.append(simd_normalize(simd_cross(e,wc-wa)))
                let t = options.widthMillimeters / altitude
                guard t > 0, t < 1 else { throw EdgeBevelError.widthExceedsSafeMaximum }
                for ideal in [wa + (wc - wa) * t, wb + (wc - wb) * t] {
                    let stored = try storedLocalFloat(idealWorld: ideal, transform: transform)
                    let actual=world(stored,transform)
                    guard actual.x.isFinite, actual.y.isFinite, actual.z.isFinite else {
                        throw EdgeBevelError.storedFloatPrecisionFailure
                    }
                    let d=simd_length((actual-wa)-u*simd_dot(actual-wa,u))
                    let error=abs(d-options.widthMillimeters)
                    guard error<=tolerance else { throw EdgeBevelError.storedFloatPrecisionFailure }
                    guard actual != wa, actual != wb else { throw EdgeBevelError.collapsedGeometry }
                    edgeMaximumError=max(edgeMaximumError,error)
                    local.append(stored)
                }
            }
            guard abs(simd_dot(normals[0],normals[1])) < 0.999_9 else { throw EdgeBevelError.coplanarEdge }
            if edgeMax < maxWidth { maxWidth=edgeMax; limitingEdge=id }
            minAltitude=min(minAltitude,edgeMinimumAltitude)
            sharedTolerance=max(sharedTolerance,edgeTolerance)
            maxError=max(maxError,edgeMaximumError)
            items.append(Item(
                record: edge, faces: faces, opposite: opposite, supports: supports,
                local: local, maxWidth: edgeMax, minimumAltitude: edgeMinimumAltitude,
                edgeLength: el, widthTolerance: edgeTolerance,
                maximumWidthError: edgeMaximumError,
                affectedSourceVertices: localAffectedVertices.sorted()))
        }
        var affectedPositions: [EdgeBevelAffectedPosition] = []
        for item in items.sorted(by: { $0.record.id < $1.record.id }) {
            for vertexID in item.affectedSourceVertices.sorted() {
                affectedPositions.append(EdgeBevelAffectedPosition(
                    edgeID: item.record.id, kind: .source(vertexID: vertexID),
                    localPosition: mesh.vertices[Int(vertexID)].position))
            }
            for (slot, position) in item.local.enumerated() {
                affectedPositions.append(EdgeBevelAffectedPosition(
                    edgeID: item.record.id, kind: .offset(edgeID: item.record.id, slot: slot),
                    localPosition: position))
            }
        }
        try validateExactAffectedPositions(affectedPositions, transform: transform)
        guard options.widthMillimeters < maxWidth else { throw EdgeBevelError.widthExceedsSafeMaximum }
        instrumentation?.recordStageB()
        let refinedBytes = try refinedWorkingByteCount(
            mesh: mesh, table: table, selectedEdgeCount: ids.count,
            affectedFaceCount: affectedFaces.count,
            affectedVertexCount: affectedVertices.count,
            endpointIncidentEdgeCount: selectedVertices.reduce(0) {
                $0 + table.edgeIDsByVertexID[Int($1)].count
            }, resultVertexCount: preflight.vertices,
            resultTriangleCount: preflight.triangles, memoryLimit: memoryLimit)
        var resultLocalBounds=mesh.bounds, resultWorldBounds=sourceWorldBounds
        for item in items { for p in item.local {
            resultLocalBounds.include(p)
            resultWorldBounds.include(transform.worldPosition(fromLocal:p))
        }}
        var fp=fingerprint(ids)
        mix(options.widthMillimeters.bitPattern, into: &fp)
        for item in items {
            mix(UInt64(item.record.id), into: &fp)
            item.faces.forEach { mix(UInt64($0), into: &fp) }
            item.supports.forEach {
                mix(UInt64($0.supportFace), into: &fp)
                mix(UInt64($0.sideEdge.low), into: &fp)
                mix(UInt64($0.sideEdge.high), into: &fp)
                mix(UInt64($0.thirdVertex), into: &fp)
                mix((try? directedUse(mesh, face: $0.incidentFace, edge: $0.sideEdge)) == true ? 1 : 0, into: &fp)
                mix((try? directedUse(mesh, face: $0.supportFace, edge: $0.sideEdge)) == true ? 1 : 0, into: &fp)
            }
            item.affectedSourceVertices.forEach {
                mix(UInt64($0), into: &fp)
                let actual = transform.worldPosition(fromLocal: mesh.vertices[Int($0)].position)
                mix(UInt64(canonicalFloatBitPattern(actual.x)), into: &fp)
                mix(UInt64(canonicalFloatBitPattern(actual.y)), into: &fp)
                mix(UInt64(canonicalFloatBitPattern(actual.z)), into: &fp)
            }
            item.local.forEach {
                mix(UInt64(canonicalFloatBitPattern($0.x)), into: &fp)
                mix(UInt64(canonicalFloatBitPattern($0.y)), into: &fp)
                mix(UInt64(canonicalFloatBitPattern($0.z)), into: &fp)
            }
            mix(item.maxWidth.bitPattern, into: &fp)
            mix(item.widthTolerance.bitPattern, into: &fp)
            mix(item.maximumWidthError.bitPattern, into: &fp)
        }
        let resultIndices = try plannedIndices(mesh: mesh, items: items)
        resultIndices.forEach { mix(UInt64($0), into: &fp) }
        affectedFaces.sorted().forEach { mix(UInt64($0), into: &fp) }
        affectedVertices.sorted().forEach { mix(UInt64($0), into: &fp) }
        mix(UInt64(refinedBytes), into: &fp)
        return Plan(items:items, estimate:EdgeBevelEstimate(
            selectedEdgeCount:ids.count, affectedFaceCount:affectedFaces.count,
            supportFaceCount:ids.count * 4, selectedEndpointCount:ids.count * 2,
            originalVertexCount:mesh.vertices.count, originalTriangleCount:mesh.indices.count/3,
            resultingVertexCount:preflight.vertices, resultingTriangleCount:preflight.triangles,
            minimumSelectedEdgeLengthMillimeters:minLength, maximumSelectedEdgeLengthMillimeters:maxLength,
            minimumIncidentAltitudeMillimeters:minAltitude, maximumSafeWidthMillimeters:maxWidth,
            limitingEdgeID:limitingEdge, limitingFaceID:limitingFace,
            widthToleranceMillimeters:sharedTolerance,
            maximumMeasuredWidthErrorMillimeters:maxError,
            estimatedWorkingByteCount:refinedBytes,
            sourceLocalBounds:mesh.bounds, resultLocalBounds:resultLocalBounds,
            sourceWorldBounds:sourceWorldBounds, resultWorldBounds:resultWorldBounds,
            sourceComponentCount:sourceReport.connectedComponentCount,
            resultComponentCount:sourceReport.connectedComponentCount,
            sourceBoundaryEdgeCount:sourceReport.boundaryEdgeCount,
            resultBoundaryEdgeCount:sourceReport.boundaryEdgeCount), fingerprint:fp)
    }

    private static func world(_ p: SIMD3<Float>, _ t:ObjectTransform)->SIMD3<Double>{let q=t.worldPosition(fromLocal:p);return SIMD3(Double(q.x),Double(q.y),Double(q.z))}
    private static func storedLocalFloat(
        idealWorld point: SIMD3<Double>, transform: ObjectTransform
    ) throws -> SIMD3<Float> {
        let matrix = transform.inverseModelMatrix
        let matrixValues = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
        guard matrixValues.allSatisfy(\.isFinite)
        else { throw EdgeBevelError.storedFloatPrecisionFailure }
        let x = Double(matrix.columns.0.x) * point.x + Double(matrix.columns.1.x) * point.y
            + Double(matrix.columns.2.x) * point.z + Double(matrix.columns.3.x)
        let y = Double(matrix.columns.0.y) * point.x + Double(matrix.columns.1.y) * point.y
            + Double(matrix.columns.2.y) * point.z + Double(matrix.columns.3.y)
        let z = Double(matrix.columns.0.z) * point.x + Double(matrix.columns.1.z) * point.y
            + Double(matrix.columns.2.z) * point.z + Double(matrix.columns.3.z)
        let w = Double(matrix.columns.0.w) * point.x + Double(matrix.columns.1.w) * point.y
            + Double(matrix.columns.2.w) * point.z + Double(matrix.columns.3.w)
        guard [x, y, z, w].allSatisfy(\.isFinite), abs(w) > 1e-12 else {
            throw EdgeBevelError.storedFloatPrecisionFailure
        }
        let stored = SIMD3<Float>(Float(x / w), Float(y / w), Float(z / w))
        guard stored.allFinite else { throw EdgeBevelError.storedFloatPrecisionFailure }
        return stored
    }
    private static func validateEndpointFan(_ vertexID: UInt32, table: MeshEdgeTable) throws -> Int {
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
        return edgeIDs.count
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
    private static func triangle(_ mesh: EditableMesh, face: Int) throws -> [UInt32] {
        let offset = face * 3
        guard face >= 0, offset >= 0, offset + 2 < mesh.indices.count else {
            throw EdgeBevelError.invalidMesh
        }
        return Array(mesh.indices[offset..<(offset + 3)])
    }
    private static func oppositeVertex(_ m:EditableMesh,face:Int,edge:MeshEdgeKey)throws->UInt32{guard let v=try triangle(m,face:face).first(where:{$0 != edge.low && $0 != edge.high})else{throw EdgeBevelError.invalidMesh};return v}
    private static func faceNormal(_ m:EditableMesh,_ f:Int)->SIMD3<Float>{let o=f*3,a=m.vertices[Int(m.indices[o])].position,b=m.vertices[Int(m.indices[o+1])].position,c=m.vertices[Int(m.indices[o+2])].position;return simd_cross(b-a,c-a)}
    private static func splitSupportFace(
        mesh: EditableMesh, face: Int, edge: MeshEdgeKey, inserted: UInt32
    ) throws -> (first: [UInt32], second: [UInt32]) {
        let source = try triangle(mesh, face: face)
        for index in 0..<3 {
            let x = source[index], y = source[(index + 1) % 3]
            if MeshEdgeKey(x, y) == edge {
                let z = source[(index + 2) % 3]
                return ([x, inserted, z], [inserted, y, z])
            }
        }
        throw EdgeBevelError.invalidBevelCavity
    }

    private static func plannedIndices(mesh: EditableMesh, items: [Item]) throws -> [UInt32] {
        var indices = mesh.indices
        let extraIndexCount = try checkedProduct(items.count, 8 * 3)
        let capacity = try checkedSum(indices.count, extraIndexCount)
        indices.reserveCapacity(capacity)
        for (itemIndex, item) in items.enumerated() {
            let baseValue = try checkedSum(mesh.vertices.count, try checkedProduct(itemIndex, 4))
            guard baseValue <= Int(UInt32.max) else { throw EdgeBevelError.vertexLimitExceeded }
            let base = UInt32(baseValue)
            for side in 0..<2 {
                let face=item.faces[side], offset=face*3
                let lowOffset=side == 0 ? base : base+2
                let highOffset=side == 0 ? base+1 : base+3
                let source=try triangle(mesh,face:face)
                let trimmed=source.map { index -> UInt32 in
                    if index == item.record.key.low { return lowOffset }
                    if index == item.record.key.high { return highOffset }
                    return index
                }
                indices.replaceSubrange(offset..<(offset+3),with:trimmed)
            }
            var extras:[[UInt32]]=[]
            for support in item.supports {
                let inserted=base+UInt32(support.insertedVertexSlot)
                let children=try splitSupportFace(
                    mesh:mesh,face:support.supportFace,
                    edge:support.sideEdge,inserted:inserted)
                let offset=support.supportFace*3
                indices.replaceSubrange(offset..<(offset+3),with:children.first)
                extras.append(children.second)
            }
            extras.forEach { indices.append(contentsOf:$0) }
            let low=item.record.key.low, high=item.record.key.high
            let cavity:Set<UInt32>=[low,base,base+1,high,base+3,base+2]
            let boundary=try cavityBoundary(indices:indices,vertices:cavity)
            let candidates:[[UInt32]]=[
                [base,base+1,base+3],[base,base+3,base+2],
                [low,base,base+2],[high,base+3,base+1]
            ]
            try orientClosure(candidates,boundary:boundary).forEach {
                indices.append(contentsOf:$0)
            }
        }
        return indices
    }

    private static func cavityBoundary(
        indices: [UInt32], vertices: Set<UInt32>
    ) throws -> [MeshEdgeKey: (UInt32, UInt32)] {
        var uses: [MeshEdgeKey: [(UInt32, UInt32)]] = [:]
        for offset in stride(from: 0, to: indices.count, by: 3) {
            let triangle = [indices[offset], indices[offset + 1], indices[offset + 2]]
            for index in 0..<3 {
                let from = triangle[index], to = triangle[(index + 1) % 3]
                guard vertices.contains(from), vertices.contains(to),
                      let key = MeshEdgeKey(from, to) else { continue }
                uses[key, default: []].append((from, to))
            }
        }
        let boundary = uses.filter { $0.value.count == 1 }.mapValues { $0[0] }
        guard boundary.count == 6 else { throw EdgeBevelError.invalidBevelCavity }
        var degree: [UInt32: Int] = [:]
        boundary.keys.forEach {
            degree[$0.low, default: 0] += 1
            degree[$0.high, default: 0] += 1
        }
        guard degree.count == 6, degree.values.allSatisfy({ $0 == 2 }) else {
            throw EdgeBevelError.invalidBevelCavity
        }
        var visited: Set<UInt32> = []
        let start = degree.keys.min()!
        var current = start
        var previous: UInt32?
        for _ in 0..<6 {
            guard visited.insert(current).inserted else { throw EdgeBevelError.invalidBevelCavity }
            let neighbors = boundary.keys.compactMap { key -> UInt32? in
                if key.low == current { return key.high }
                if key.high == current { return key.low }
                return nil
            }.sorted()
            guard neighbors.count == 2,
                  let next = neighbors.first(where: { $0 != previous }) else {
                throw EdgeBevelError.invalidBevelCavity
            }
            previous = current
            current = next
        }
        guard current == start, visited.count == 6 else {
            throw EdgeBevelError.invalidBevelCavity
        }
        return boundary
    }

    private static func orientClosure(
        _ candidates: [[UInt32]], boundary: [MeshEdgeKey: (UInt32, UInt32)]
    ) throws -> [[UInt32]] {
        for reverse in [false, true] {
            let triangles = reverse ? candidates.map { [$0[0], $0[2], $0[1]] } : candidates
            var fillUses: [MeshEdgeKey: [(UInt32, UInt32)]] = [:]
            for triangle in triangles {
                for index in 0..<3 {
                    let from=triangle[index], to=triangle[(index+1)%3]
                    guard let key=MeshEdgeKey(from,to) else { continue }
                    fillUses[key,default:[]].append((from,to))
                }
            }
            let boundaryOK = boundary.allSatisfy { key, sourceUse in
                fillUses[key]?.count == 1
                    && fillUses[key]![0].0 == sourceUse.1
                    && fillUses[key]![0].1 == sourceUse.0
            }
            let internalOK = fillUses.filter { boundary[$0.key] == nil }.allSatisfy { _, values in
                values.count == 2 && values[0].0 == values[1].1 && values[0].1 == values[1].0
            }
            if boundaryOK && internalOK { return triangles }
        }
        throw EdgeBevelError.invalidBevelCavity
    }

    static func validateExactAffectedPositions(
        _ owners: [EdgeBevelAffectedPosition], transform: ObjectTransform
    ) throws {
        var localOwners: [ExactPositionKey: EdgeBevelAffectedPosition] = [:]
        var worldOwners: [ExactPositionKey: EdgeBevelAffectedPosition] = [:]
        func register(
            _ owner: EdgeBevelAffectedPosition, key: ExactPositionKey,
            in registry: inout [ExactPositionKey: EdgeBevelAffectedPosition]
        ) throws {
            if let existing = registry[key] {
                throw existing.edgeID == owner.edgeID
                    ? EdgeBevelError.collapsedGeometry
                    : EdgeBevelError.affectedNeighborhoodsOverlap
            }
            registry[key] = owner
        }
        for owner in owners {
            guard owner.localPosition.allFinite else { throw EdgeBevelError.nonFiniteValue }
            let worldPosition = transform.worldPosition(fromLocal: owner.localPosition)
            guard worldPosition.allFinite else { throw EdgeBevelError.nonFiniteValue }
            try register(owner, key: ExactPositionKey(owner.localPosition), in: &localOwners)
            try register(owner, key: ExactPositionKey(worldPosition), in: &worldOwners)
        }
        guard localOwners.count == owners.count, worldOwners.count == owners.count else {
            throw EdgeBevelError.collapsedGeometry
        }
    }

    static func validateAffectedVertexFans(
        mesh: EditableMesh, affectedVertexIDs: Set<UInt32>
    ) throws {
        guard !affectedVertexIDs.isEmpty else { throw EdgeBevelError.validationFailed }
        var facesByVertex: [UInt32: [Int]] = [:]
        var facesByVertexEdge: [UInt32: [MeshEdgeKey: [Int]]] = [:]
        for face in 0..<(mesh.indices.count / 3) {
            let values=try triangle(mesh,face:face)
            for vertex in values where affectedVertexIDs.contains(vertex) {
                facesByVertex[vertex,default:[]].append(face)
                for neighbor in values where neighbor != vertex {
                    guard let key=MeshEdgeKey(vertex,neighbor) else {
                        throw EdgeBevelError.validationFailed
                    }
                    facesByVertexEdge[vertex,default:[:]][key,default:[]].append(face)
                }
            }
        }
        for vertex in affectedVertexIDs.sorted() {
            guard let faces=facesByVertex[vertex], !faces.isEmpty,
                  let edgeUses=facesByVertexEdge[vertex],
                  edgeUses.values.allSatisfy({ $0.count == 2 })
            else { throw EdgeBevelError.validationFailed }
            var adjacency:[Int:Set<Int>]=[:]
            for uses in edgeUses.values {
                let a=uses[0], b=uses[1]
                adjacency[a,default:[]].insert(b)
                adjacency[b,default:[]].insert(a)
            }
            guard faces.allSatisfy({ adjacency[$0]?.count == 2 }),
                  let seed=faces.min() else { throw EdgeBevelError.validationFailed }
            var visited:Set<Int>=[seed], queue=[seed], cursor=0
            while cursor<queue.count {
                let face=queue[cursor]; cursor+=1
                for neighbor in adjacency[face,default:[]].sorted()
                    where visited.insert(neighbor).inserted { queue.append(neighbor) }
            }
            guard visited.count == Set(faces).count else { throw EdgeBevelError.validationFailed }
        }
    }

    private static func memoryPreflight(
        mesh: EditableMesh, table: MeshEdgeTable, selectedEdgeCount: Int,
        memoryLimit: Int = maximumWorkingBytes
    ) throws -> (vertices: Int, triangles: Int, bytes: Int) {
        try stageAWorkingCounts(
            sourceVertexCount: mesh.vertices.count, sourceIndexCount: mesh.indices.count,
            edgeCount: table.edges.count, selectedEdgeCount: selectedEdgeCount,
            memoryLimit: memoryLimit)
    }

    static func stageAWorkingCountsForTesting(
        sourceVertexCount: Int, sourceIndexCount: Int, edgeCount: Int,
        selectedEdgeCount: Int, memoryLimit: Int = Int.max
    ) throws -> (vertices: Int, triangles: Int, bytes: Int) {
        try stageAWorkingCounts(
            sourceVertexCount: sourceVertexCount, sourceIndexCount: sourceIndexCount,
            edgeCount: edgeCount, selectedEdgeCount: selectedEdgeCount,
            memoryLimit: memoryLimit)
    }

    private static func stageAWorkingCounts(
        sourceVertexCount: Int, sourceIndexCount: Int, edgeCount: Int,
        selectedEdgeCount: Int, memoryLimit: Int
    ) throws -> (vertices: Int, triangles: Int, bytes: Int) {
        guard sourceVertexCount >= 0, sourceIndexCount >= 0, edgeCount >= 0,
              selectedEdgeCount >= 0, sourceIndexCount.isMultiple(of: 3)
        else { throw EdgeBevelError.arithmeticOverflow }
        let (addVertices, overflow1)=selectedEdgeCount.multipliedReportingOverflow(by:4)
        let (addTriangles, overflow2)=selectedEdgeCount.multipliedReportingOverflow(by:8)
        let (vertices, overflow3)=sourceVertexCount.addingReportingOverflow(addVertices)
        let (triangles, overflow4)=(sourceIndexCount/3).addingReportingOverflow(addTriangles)
        guard !overflow1,!overflow2,!overflow3,!overflow4 else { throw EdgeBevelError.arithmeticOverflow }
        guard vertices<=maximumVertices else { throw EdgeBevelError.vertexLimitExceeded }
        guard triangles<=maximumTriangles else { throw EdgeBevelError.triangleLimitExceeded }
        var bytes=0
        func account(_ count:Int,_ stride:Int)throws {
            let (part,o1)=count.multipliedReportingOverflow(by:stride)
            let (sum,o2)=bytes.addingReportingOverflow(part)
            guard !o1,!o2 else { throw EdgeBevelError.arithmeticOverflow }
            bytes=sum
        }
        try account(sourceVertexCount,64)         // source mesh and history snapshot
        try account(sourceIndexCount,16)          // source indices and diagnostics
        try account(vertices,96)                  // result, normals, bounds, BVH, spatial staging
        try account(triangles,120)                // result indices, adjacency, duplicate/fan diagnostics
        try account(edgeCount,64)                 // current table and incidence staging
        try account(selectedEdgeCount,1_536)       // plans, world Double geometry, cavities, Preview
        guard bytes<=memoryLimit else { throw EdgeBevelError.workingMemoryLimitExceeded }
        return (vertices,triangles,bytes)
    }

    private static func refinedWorkingByteCount(
        mesh: EditableMesh, table: MeshEdgeTable, selectedEdgeCount: Int,
        affectedFaceCount: Int, affectedVertexCount: Int,
        endpointIncidentEdgeCount: Int, resultVertexCount: Int,
        resultTriangleCount: Int, memoryLimit: Int
    ) throws -> Int {
        var bytes=0
        func account(_ count:Int,_ stride:Int)throws {
            guard count>=0 else { throw EdgeBevelError.arithmeticOverflow }
            let (part,o1)=count.multipliedReportingOverflow(by:stride)
            let (sum,o2)=bytes.addingReportingOverflow(part)
            guard !o1,!o2 else { throw EdgeBevelError.arithmeticOverflow }
            bytes=sum
        }
        try account(mesh.vertices.count,64)
        try account(mesh.indices.count,20)
        try account(resultVertexCount,128)
        try account(resultTriangleCount,160)
        try account(table.edges.count,80)
        try account(selectedEdgeCount,2_048)
        try account(affectedFaceCount,384)
        try account(affectedVertexCount,320)
        try account(endpointIncidentEdgeCount,128)
        guard bytes<=memoryLimit else { throw EdgeBevelError.workingMemoryLimitExceeded }
        return bytes
    }

    private static func checkedProduct(_ lhs:Int,_ rhs:Int)throws->Int {
        let (value,overflow)=lhs.multipliedReportingOverflow(by:rhs)
        guard !overflow else { throw EdgeBevelError.arithmeticOverflow }
        return value
    }
    private static func checkedSum(_ lhs:Int,_ rhs:Int)throws->Int {
        let (value,overflow)=lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw EdgeBevelError.arithmeticOverflow }
        return value
    }

    private static func mix(_ value: UInt64, into fingerprint: inout UInt64) {
        fingerprint = (fingerprint ^ value) &* 1099511628211
    }
    private static func floatULP(at point: SIMD3<Double>) -> Double {
        [point.x, point.y, point.z].reduce(0) { current, component in
            let value = Float(component)
            guard value.isFinite else { return .infinity }
            return max(current, Double(abs(value.nextUp - value)))
        }
    }
    private static func fingerprint(_ ids:[Int])->UInt64{ids.reduce(1469598103934665603){($0 ^ UInt64($1)) &* 1099511628211}}
}
