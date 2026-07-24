import CoreGraphics
import Foundation
import simd

struct MeshEdgeKey: Hashable, Comparable, Sendable {
    let low: UInt32
    let high: UInt32

    init?(_ first: UInt32, _ second: UInt32) {
        guard first != second else { return nil }
        low = min(first, second)
        high = max(first, second)
    }

    static func < (lhs: MeshEdgeKey, rhs: MeshEdgeKey) -> Bool {
        lhs.low != rhs.low ? lhs.low < rhs.low : lhs.high < rhs.high
    }
}

struct MeshEdgeRecord: Equatable, Sendable {
    let id: Int
    let key: MeshEdgeKey
    let incidentFaceIDs: [Int]

    var classification: MeshEdgeClassification {
        switch incidentFaceIDs.count {
        case 1: .boundary
        case 2: .manifoldInterior
        default: .nonManifold
        }
    }
}

enum MeshEdgeClassification: Equatable, Sendable {
    case boundary
    case manifoldInterior
    case nonManifold
}

struct MeshEdgeTable: Equatable {
    static let maximumEdgeCount = 12_000_000
    static let maximumWorkingBytes = 768 * 1_024 * 1_024

    let sourceTopologyID: UUID
    let sourceTopologyRevision: UInt64
    let sourceIndexCount: Int
    let edges: [MeshEdgeRecord]
    let edgeIDByKey: [MeshEdgeKey: Int]
    let edgeIDsByVertexID: [[Int]]
    let boundaryEdgeCount: Int
    let manifoldEdgeCount: Int
    let nonManifoldEdgeCount: Int
    let fingerprint: UInt64

    static func build(
        mesh: EditableMesh,
        memoryLimit: Int = maximumWorkingBytes,
        instrumentation: MeshEdgeTableBuildInstrumentation? = nil
    ) throws -> MeshEdgeTable {
        instrumentation?.recordPreflight()
        let estimate = try estimatedPeakBytes(
            vertexCount: mesh.vertices.count, indexCount: mesh.indices.count)
        guard estimate <= memoryLimit else { throw EdgeSelectionError.workingMemoryLimitExceeded }
        guard mesh.indices.count.isMultiple(of: 3) else { throw EdgeSelectionError.invalidMesh }
        guard mesh.indices.count <= maximumEdgeCount else { throw EdgeSelectionError.edgeLimitExceeded }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite }) else {
            throw EdgeSelectionError.invalidMesh
        }

        instrumentation?.recordTriangleScan()
        var facesByEdge: [MeshEdgeKey: [Int]] = [:]
        facesByEdge.reserveCapacity(mesh.indices.count)
        for faceID in 0..<(mesh.indices.count / 3) {
            let offset = faceID * 3
            let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
            guard Int(a) < mesh.vertices.count, Int(b) < mesh.vertices.count,
                  Int(c) < mesh.vertices.count,
                  let ab = MeshEdgeKey(a, b), let bc = MeshEdgeKey(b, c),
                  let ca = MeshEdgeKey(c, a) else {
                throw EdgeSelectionError.invalidMesh
            }
            for key in [ab, bc, ca] {
                if facesByEdge[key]?.last != faceID {
                    facesByEdge[key, default: []].append(faceID)
                }
            }
        }

        let keys = facesByEdge.keys.sorted()
        guard keys.count <= maximumEdgeCount else { throw EdgeSelectionError.edgeLimitExceeded }
        var records: [MeshEdgeRecord] = []
        records.reserveCapacity(keys.count)
        var idsByKey: [MeshEdgeKey: Int] = [:]
        idsByKey.reserveCapacity(keys.count)
        var idsByVertex = Array(repeating: [Int](), count: mesh.vertices.count)
        var boundary = 0, manifold = 0, nonManifold = 0
        var fingerprint: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) { fingerprint = (fingerprint ^ value) &* 0x100000001b3 }
        for (id, key) in keys.enumerated() {
            let faces = facesByEdge[key]!.sorted()
            let record = MeshEdgeRecord(id: id, key: key, incidentFaceIDs: faces)
            records.append(record)
            idsByKey[key] = id
            idsByVertex[Int(key.low)].append(id)
            idsByVertex[Int(key.high)].append(id)
            switch record.classification {
            case .boundary: boundary += 1
            case .manifoldInterior: manifold += 1
            case .nonManifold: nonManifold += 1
            }
            mix(UInt64(key.low)); mix(UInt64(key.high))
            faces.forEach { mix(UInt64($0)) }
        }
        return MeshEdgeTable(
            sourceTopologyID: mesh.runtime.topologyID,
            sourceTopologyRevision: mesh.runtime.topologyRevision,
            sourceIndexCount: mesh.indices.count,
            edges: records,
            edgeIDByKey: idsByKey,
            edgeIDsByVertexID: idsByVertex,
            boundaryEdgeCount: boundary,
            manifoldEdgeCount: manifold,
            nonManifoldEdgeCount: nonManifold,
            fingerprint: fingerprint)
    }

    func matches(_ mesh: EditableMesh) -> Bool {
        sourceTopologyID == mesh.runtime.topologyID
            && sourceTopologyRevision == mesh.runtime.topologyRevision
            && sourceIndexCount == mesh.indices.count
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0 else { throw EdgeSelectionError.allocationOverflow }
        let edgeCount = indexCount
        var total = 0
        func account(_ count: Int, _ bytes: Int) throws {
            let (part, overflow) = count.multipliedReportingOverflow(by: bytes)
            let (sum, sumOverflow) = total.addingReportingOverflow(part)
            guard !overflow, !sumOverflow else { throw EdgeSelectionError.allocationOverflow }
            total = sum
        }
        try account(edgeCount, 112) // accumulation, sorted keys, records, and key map
        try account(indexCount, 16) // incident face uses
        try account(vertexCount, 24) // vertex-to-edge array
        try account(edgeCount, 16) // vertex-to-edge entries and overlay staging
        let (adjustedEdgeCount, overflow) = edgeCount.addingReportingOverflow(63)
        guard !overflow else { throw EdgeSelectionError.allocationOverflow }
        try account(adjustedEdgeCount / 64, MemoryLayout<UInt64>.stride)
        return total
    }
}

final class MeshEdgeTableBuildInstrumentation {
    private(set) var preflightCount = 0
    private(set) var triangleScanCount = 0
    fileprivate func recordPreflight() { preflightCount += 1 }
    fileprivate func recordTriangleScan() { triangleScanCount += 1 }
}

enum EdgeSelectionOperation: String, CaseIterable, Hashable {
    case replace = "Replace"
    case add = "Add"
    case remove = "Remove"
    case toggle = "Toggle"
}

struct EdgeSelectionVersion: Equatable, Hashable {
    let identity: UUID
}

struct EdgeSelection: Equatable {
    let sourceTopologyID: UUID
    let sourceTopologyRevision: UInt64
    let sourceEdgeTableFingerprint: UInt64
    let edgeCount: Int
    private var words: [UInt64]
    private(set) var selectedCount = 0
    private(set) var version: EdgeSelectionVersion

    init(table: MeshEdgeTable, versionIdentity: UUID = UUID()) throws {
        guard table.edges.count >= 0, table.edges.count <= MeshEdgeTable.maximumEdgeCount else {
            throw EdgeSelectionError.edgeLimitExceeded
        }
        let (adjusted, overflow) = table.edges.count.addingReportingOverflow(63)
        guard !overflow else { throw EdgeSelectionError.allocationOverflow }
        self.sourceTopologyID = table.sourceTopologyID
        self.sourceTopologyRevision = table.sourceTopologyRevision
        sourceEdgeTableFingerprint = table.fingerprint
        edgeCount = table.edges.count
        words = Array(repeating: 0, count: adjusted / 64)
        version = EdgeSelectionVersion(identity: versionIdentity)
    }

    static func unavailable(topologyID: UUID, topologyRevision: UInt64) -> EdgeSelection {
        EdgeSelection(sourceTopologyID: topologyID, sourceTopologyRevision: topologyRevision)
    }

    private init(sourceTopologyID: UUID, sourceTopologyRevision: UInt64) {
        self.sourceTopologyID = sourceTopologyID
        self.sourceTopologyRevision = sourceTopologyRevision
        sourceEdgeTableFingerprint = 0
        edgeCount = 0
        words = []
        version = EdgeSelectionVersion(identity: UUID())
    }

    func matches(_ table: MeshEdgeTable) -> Bool {
        sourceTopologyID == table.sourceTopologyID
            && sourceTopologyRevision == table.sourceTopologyRevision
            && sourceEdgeTableFingerprint == table.fingerprint
            && edgeCount == table.edges.count
    }

    func contains(_ edgeID: Int) -> Bool {
        guard edgeID >= 0, edgeID < edgeCount else { return false }
        return words[edgeID >> 6] & (UInt64(1) << UInt64(edgeID & 63)) != 0
    }

    @discardableResult
    mutating func apply(_ operation: EdgeSelectionOperation, edgeID: Int) throws -> Bool {
        guard edgeID >= 0, edgeID < edgeCount else { throw EdgeSelectionError.invalidEdgeID }
        switch operation {
        case .replace:
            if selectedCount == 1, contains(edgeID) { return false }
            words.indices.forEach { words[$0] = 0 }
            words[edgeID >> 6] = UInt64(1) << UInt64(edgeID & 63)
            selectedCount = 1
        case .add:
            guard !contains(edgeID) else { return false }
            setBit(edgeID, true)
        case .remove:
            guard contains(edgeID) else { return false }
            setBit(edgeID, false)
        case .toggle:
            setBit(edgeID, !contains(edgeID))
        }
        advanceVersion()
        return true
    }

    @discardableResult
    mutating func clear() -> Bool {
        guard selectedCount > 0 else { return false }
        words.indices.forEach { words[$0] = 0 }
        selectedCount = 0
        advanceVersion()
        return true
    }

    @discardableResult
    mutating func selectAll() -> Bool {
        guard edgeCount > 0, selectedCount != edgeCount else { return false }
        words.indices.forEach { words[$0] = .max }
        maskTail()
        selectedCount = edgeCount
        advanceVersion()
        return true
    }

    @discardableResult
    mutating func invert() -> Bool {
        guard edgeCount > 0 else { return false }
        words.indices.forEach { words[$0] = ~words[$0] }
        maskTail()
        selectedCount = edgeCount - selectedCount
        advanceVersion()
        return true
    }

    @discardableResult
    mutating func formUnion(_ edgeIDs: [Int]) throws -> Bool {
        guard edgeIDs.allSatisfy({ $0 >= 0 && $0 < edgeCount }) else {
            throw EdgeSelectionError.invalidEdgeID
        }
        var changed = false
        for edgeID in edgeIDs where !contains(edgeID) {
            setBit(edgeID, true)
            changed = true
        }
        if changed { advanceVersion() }
        return changed
    }

    func selectedEdgeIDs() -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(selectedCount)
        for (wordIndex, stored) in words.enumerated() {
            var word = stored
            while word != 0 {
                let bit = word.trailingZeroBitCount
                let id = wordIndex * 64 + bit
                if id < edgeCount { result.append(id) }
                word &= word - 1
            }
        }
        return result
    }

    private mutating func setBit(_ id: Int, _ selected: Bool) {
        let mask = UInt64(1) << UInt64(id & 63)
        if selected {
            words[id >> 6] |= mask
            selectedCount += 1
        } else {
            words[id >> 6] &= ~mask
            selectedCount -= 1
        }
    }

    private mutating func maskTail() {
        let used = edgeCount & 63
        if used != 0, !words.isEmpty {
            words[words.count - 1] &= (UInt64(1) << UInt64(used)) - 1
        }
    }

    private mutating func advanceVersion() {
        version = EdgeSelectionVersion(identity: UUID())
    }
}

enum EdgeSelectionConnectivity {
    static func connectedEdgeIDs(
        table: MeshEdgeTable,
        seeds: [Int],
        instrumentation: EdgeConnectedInstrumentation? = nil
    ) throws -> [Int] {
        guard !seeds.isEmpty else { return [] }
        guard seeds.allSatisfy({ $0 >= 0 && $0 < table.edges.count }) else {
            throw EdgeSelectionError.invalidEdgeID
        }
        var selected = Array(repeating: false, count: table.edges.count)
        var queue = seeds.sorted(), cursor = 0
        queue.forEach { selected[$0] = true }
        while cursor < queue.count {
            let edgeID = queue[cursor]
            cursor += 1
            instrumentation?.recordVisit()
            let key = table.edges[edgeID].key
            for vertexID in [key.low, key.high] {
                guard Int(vertexID) < table.edgeIDsByVertexID.count else {
                    throw EdgeSelectionError.invalidTable
                }
                for neighbor in table.edgeIDsByVertexID[Int(vertexID)] where !selected[neighbor] {
                    selected[neighbor] = true
                    queue.append(neighbor)
                }
            }
        }
        return selected.indices.filter { selected[$0] }
    }
}

final class EdgeConnectedInstrumentation {
    private(set) var visitedEdgeCount = 0
    fileprivate func recordVisit() { visitedEdgeCount += 1 }
}

enum IndexedMeshEdgePickResult: Equatable {
    case hit(edgeID: Int, key: MeshEdgeKey)
    case miss
    case unavailable
}

enum MeshEdgePicker {
    static let pickRadiusPoints: CGFloat = 14

    static func pick(
        worldRay: Ray,
        screenPoint: CGPoint,
        viewportSize: CGSize,
        mesh: EditableMesh,
        transform: ObjectTransform,
        viewProjection: simd_float4x4,
        table: MeshEdgeTable,
        cache: MeshBVHCache,
        threshold: CGFloat = pickRadiusPoints
    ) -> IndexedMeshEdgePickResult {
        guard table.matches(mesh), viewportSize.width > 0, viewportSize.height > 0,
              threshold.isFinite, threshold >= 0,
              let localRay = transform.localRay(fromWorld: worldRay) else { return .unavailable }
        let trianglePick = MeshPicker.indexedHit(
            ray: localRay, mesh: mesh, culling: .none, cache: cache)
        guard case .hit(let hit) = trianglePick else {
            if case .miss = trianglePick { return .miss }
            return .unavailable
        }
        let offset = hit.triangleStart
        guard offset >= 0, offset + 2 < mesh.indices.count else { return .unavailable }
        let ids = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
        var candidates: [(distance: CGFloat, id: Int, key: MeshEdgeKey)] = []
        for pair in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
            guard let key = MeshEdgeKey(pair.0, pair.1), let id = table.edgeIDByKey[key],
                  Int(key.low) < mesh.vertices.count, Int(key.high) < mesh.vertices.count,
                  let a = project(mesh.vertices[Int(key.low)].position, transform: transform,
                                  viewProjection: viewProjection, viewport: viewportSize),
                  let b = project(mesh.vertices[Int(key.high)].position, transform: transform,
                                  viewProjection: viewProjection, viewport: viewportSize) else {
                return .unavailable
            }
            candidates.append((pointSegmentDistance(screenPoint, a, b), id, key))
        }
        guard let nearest = candidates.min(by: {
            abs($0.distance - $1.distance) > 0.000_1
                ? $0.distance < $1.distance : $0.id < $1.id
        }), nearest.distance <= threshold else { return .miss }
        return .hit(edgeID: nearest.id, key: nearest.key)
    }

    static func pointSegmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared.isFinite, lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(max(projection, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private static func project(
        _ local: SIMD3<Float>,
        transform: ObjectTransform,
        viewProjection: simd_float4x4,
        viewport: CGSize
    ) -> CGPoint? {
        let clip = viewProjection * transform.modelMatrix * SIMD4<Float>(local, 1)
        guard clip.x.isFinite, clip.y.isFinite, clip.z.isFinite, clip.w.isFinite,
              clip.w > 0.000_001 else { return nil }
        let x = clip.x / clip.w, y = clip.y / clip.w
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: (CGFloat(x) + 1) * 0.5 * viewport.width,
                       y: (1 - CGFloat(y)) * 0.5 * viewport.height)
    }
}

enum EdgeSelectionError: Error, LocalizedError, Equatable {
    case invalidEdgeID
    case invalidMesh
    case invalidTable
    case staleTopology
    case edgeLimitExceeded
    case workingMemoryLimitExceeded
    case allocationOverflow
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidEdgeID: "The selected edge is outside the current edge table."
        case .invalidMesh: "The mesh is not valid for edge selection."
        case .invalidTable: "The edge table is invalid."
        case .staleTopology: "The edge selection belongs to an older topology."
        case .edgeLimitExceeded: "The mesh has too many edges for edge selection."
        case .workingMemoryLimitExceeded: "The edge table would exceed the working-memory limit."
        case .allocationOverflow: "The edge selection allocation is not representable."
        case .unavailable: "Edge selection is unavailable during the current operation."
        }
    }
}
