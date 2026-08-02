import CoreGraphics
import Foundation
import simd

typealias MeshVertexID = UInt32

struct MeshVertexTopologyRecord: Equatable {
    let vertexID: MeshVertexID
    let incidentEdgeIDs: [Int]
    let incidentFaceIDs: [Int]
    let neighboringVertexIDs: [MeshVertexID]
    let isBoundary: Bool
    let isIsolated: Bool
    let hasNonManifoldNeighborhood: Bool
}

struct MeshVertexTopologyTable: Equatable {
    static let maximumVertexCount = 2_000_000
    static let maximumWorkingBytes = 768 * 1_024 * 1_024

    let sourceTopologyID: UUID
    let sourceTopologyRevision: UInt64
    let sourceVertexCount: Int
    let sourceIndexCount: Int
    let records: [MeshVertexTopologyRecord]
    let fingerprint: UInt64

    static func build(mesh: EditableMesh, memoryLimit: Int = maximumWorkingBytes) throws -> Self {
        let estimate = try estimatedPeakBytes(
            vertexCount: mesh.vertices.count, indexCount: mesh.indices.count)
        guard estimate <= memoryLimit else { throw VertexSelectionError.workingMemoryLimitExceeded }
        guard mesh.vertices.count <= maximumVertexCount,
              mesh.indices.count.isMultiple(of: 3),
              mesh.vertices.allSatisfy({ $0.position.allFinite })
        else { throw VertexSelectionError.invalidMesh }
        let fingerprint = try topologyFingerprint(mesh: mesh)

        var facesByVertex = Array(repeating: Set<Int>(), count: mesh.vertices.count)
        var neighborsByVertex = Array(repeating: Set<MeshVertexID>(), count: mesh.vertices.count)
        var facesByEdge: [MeshEdgeKey: Set<Int>] = [:]
        for faceID in 0..<(mesh.indices.count / 3) {
            let offset = faceID * 3
            let ids = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
            guard ids.allSatisfy({ Int($0) < mesh.vertices.count }),
                  let ab = MeshEdgeKey(ids[0], ids[1]),
                  let bc = MeshEdgeKey(ids[1], ids[2]),
                  let ca = MeshEdgeKey(ids[2], ids[0])
            else { throw VertexSelectionError.invalidMesh }
            for id in ids { facesByVertex[Int(id)].insert(faceID) }
            for key in [ab, bc, ca] {
                facesByEdge[key, default: []].insert(faceID)
                neighborsByVertex[Int(key.low)].insert(key.high)
                neighborsByVertex[Int(key.high)].insert(key.low)
            }
        }
        let edgeKeys = facesByEdge.keys.sorted()
        var edgeIDsByVertex = Array(repeating: [Int](), count: mesh.vertices.count)
        for (edgeID, key) in edgeKeys.enumerated() {
            edgeIDsByVertex[Int(key.low)].append(edgeID)
            edgeIDsByVertex[Int(key.high)].append(edgeID)
        }
        var records: [MeshVertexTopologyRecord] = []
        records.reserveCapacity(mesh.vertices.count)
        for vertexID in 0..<mesh.vertices.count {
            let edgeIDs = edgeIDsByVertex[vertexID]
            let faceIDs = facesByVertex[vertexID].sorted()
            let neighbors = neighborsByVertex[vertexID].sorted()
            let edgeFaceCounts = edgeIDs.map { facesByEdge[edgeKeys[$0]]!.count }
            let isBoundary = edgeFaceCounts.contains(1)
            let boundaryEdgeCount = edgeFaceCounts.filter { $0 == 1 }.count
            var faceNeighbors: [Int: Set<Int>] = [:]
            for edgeID in edgeIDs {
                let incident = facesByEdge[edgeKeys[edgeID]]!.sorted()
                for face in incident { faceNeighbors[face, default: []].formUnion(incident) }
            }
            var connectedFaces = Set<Int>()
            if let seed = faceIDs.first {
                var queue = [seed], cursor = 0
                connectedFaces.insert(seed)
                while cursor < queue.count {
                    let face = queue[cursor]; cursor += 1
                    for neighbor in faceNeighbors[face, default: []] where connectedFaces.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
            let nonManifold = edgeFaceCounts.contains(where: { $0 > 2 })
                || (!faceIDs.isEmpty && connectedFaces.count != faceIDs.count)
                || (boundaryEdgeCount != 0 && boundaryEdgeCount != 2)
            records.append(MeshVertexTopologyRecord(
                vertexID: MeshVertexID(vertexID), incidentEdgeIDs: edgeIDs,
                incidentFaceIDs: faceIDs, neighboringVertexIDs: neighbors,
                isBoundary: isBoundary, isIsolated: faceIDs.isEmpty,
                hasNonManifoldNeighborhood: nonManifold))
        }
        return Self(
            sourceTopologyID: mesh.runtime.topologyID,
            sourceTopologyRevision: mesh.runtime.topologyRevision,
            sourceVertexCount: mesh.vertices.count, sourceIndexCount: mesh.indices.count,
            records: records, fingerprint: fingerprint)
    }

    func matches(_ mesh: EditableMesh) -> Bool {
        sourceTopologyID == mesh.runtime.topologyID
            && sourceTopologyRevision == mesh.runtime.topologyRevision
            && sourceVertexCount == mesh.vertices.count
            && sourceIndexCount == mesh.indices.count
            && (try? Self.topologyFingerprint(mesh: mesh)) == fingerprint
    }

    static func topologyFingerprint(mesh: EditableMesh) throws -> UInt64 {
        guard mesh.vertices.count <= maximumVertexCount,
              mesh.indices.count.isMultiple(of: 3) else {
            throw VertexSelectionError.invalidMesh
        }
        var value: UInt64 = 0xcbf29ce484222325
        func mix(_ input: UInt64) { value = (value ^ input) &* 0x100000001b3 }
        mix(UInt64(mesh.vertices.count))
        mix(UInt64(mesh.indices.count))
        for index in mesh.indices {
            guard Int(index) < mesh.vertices.count else { throw VertexSelectionError.invalidMesh }
            mix(UInt64(index))
        }
        return value
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0 else { throw VertexSelectionError.allocationOverflow }
        var bytes = 0
        func account(_ count: Int, _ stride: Int) throws {
            let (part, o1) = count.multipliedReportingOverflow(by: stride)
            let (sum, o2) = bytes.addingReportingOverflow(part)
            guard !o1, !o2 else { throw VertexSelectionError.allocationOverflow }
            bytes = sum
        }
        try account(vertexCount, 144)
        try account(indexCount, 80)
        try account(indexCount, MemoryLayout<MeshVertexID>.stride * 2)
        let (adjusted, overflow) = vertexCount.addingReportingOverflow(63)
        guard !overflow else { throw VertexSelectionError.allocationOverflow }
        try account(adjusted / 64, MemoryLayout<UInt64>.stride * 2)
        return bytes
    }
}

enum VertexSelectionOperation: String, CaseIterable, Hashable {
    case replace = "Replace"
    case add = "Add"
    case remove = "Remove"
    case toggle = "Toggle"
}

struct VertexSelectionVersion: Equatable, Hashable { let id: UUID }

struct VertexSelection: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexCount: Int
    let indexCount: Int
    let topologyFingerprint: UInt64
    private var bits: [UInt64]
    private(set) var selectedCount = 0
    private(set) var version: VertexSelectionVersion

    init(table: MeshVertexTopologyTable, versionID: UUID = UUID()) throws {
        guard table.sourceVertexCount <= MeshVertexTopologyTable.maximumVertexCount else {
            throw VertexSelectionError.vertexLimitExceeded
        }
        let (adjusted, overflow) = table.sourceVertexCount.addingReportingOverflow(63)
        guard !overflow else { throw VertexSelectionError.allocationOverflow }
        topologyID = table.sourceTopologyID
        topologyRevision = table.sourceTopologyRevision
        vertexCount = table.sourceVertexCount
        indexCount = table.sourceIndexCount
        topologyFingerprint = table.fingerprint
        bits = Array(repeating: 0, count: adjusted / 64)
        version = VertexSelectionVersion(id: versionID)
    }

    static func unavailable(mesh: EditableMesh) -> Self {
        Self(topologyID: mesh.runtime.topologyID, topologyRevision: mesh.runtime.topologyRevision)
    }

    private init(topologyID: UUID, topologyRevision: UInt64) {
        self.topologyID = topologyID; self.topologyRevision = topologyRevision
        vertexCount = 0; indexCount = 0; topologyFingerprint = 0; bits = []
        version = VertexSelectionVersion(id: UUID())
    }

    func matches(_ table: MeshVertexTopologyTable) -> Bool {
        topologyID == table.sourceTopologyID
            && topologyRevision == table.sourceTopologyRevision
            && vertexCount == table.sourceVertexCount
            && indexCount == table.sourceIndexCount
            && topologyFingerprint == table.fingerprint
    }

    func contains(_ vertexID: MeshVertexID) -> Bool {
        let id = Int(vertexID)
        guard id >= 0, id < vertexCount else { return false }
        return bits[id >> 6] & (UInt64(1) << UInt64(id & 63)) != 0
    }

    @discardableResult
    mutating func apply(_ operation: VertexSelectionOperation, vertexID: MeshVertexID) throws -> Bool {
        try apply(operation, vertexIDs: [vertexID])
    }

    @discardableResult
    mutating func apply(_ operation: VertexSelectionOperation, vertexIDs: [MeshVertexID]) throws -> Bool {
        let canonical = Array(Set(vertexIDs)).sorted()
        guard canonical.allSatisfy({ Int($0) < vertexCount }) else {
            throw VertexSelectionError.invalidVertexID
        }
        var next = bits
        switch operation {
        case .replace:
            next = Array(repeating: 0, count: bits.count)
            canonical.forEach { set($0, selected: true, in: &next) }
        case .add:
            canonical.forEach { set($0, selected: true, in: &next) }
        case .remove:
            canonical.forEach { set($0, selected: false, in: &next) }
        case .toggle:
            canonical.forEach { set($0, selected: !contains($0), in: &next) }
        }
        guard next != bits else { return false }
        bits = next
        selectedCount = bits.reduce(0) { $0 + $1.nonzeroBitCount }
        version = VertexSelectionVersion(id: UUID())
        return true
    }

    @discardableResult mutating func clear() -> Bool { try! apply(.replace, vertexIDs: []) }
    @discardableResult mutating func selectAll() -> Bool {
        guard vertexCount > 0, selectedCount != vertexCount else { return false }
        bits.indices.forEach { bits[$0] = .max }; maskTail()
        selectedCount = vertexCount; version = VertexSelectionVersion(id: UUID()); return true
    }
    @discardableResult mutating func invert() -> Bool {
        guard vertexCount > 0 else { return false }
        bits.indices.forEach { bits[$0] = ~bits[$0] }; maskTail()
        selectedCount = vertexCount - selectedCount
        version = VertexSelectionVersion(id: UUID()); return true
    }

    func selectedVertexIDs() -> [MeshVertexID] {
        var result: [MeshVertexID] = []; result.reserveCapacity(selectedCount)
        for (wordIndex, stored) in bits.enumerated() {
            var word = stored
            while word != 0 {
                let bit = word.trailingZeroBitCount, id = wordIndex * 64 + bit
                if id < vertexCount { result.append(MeshVertexID(id)) }
                word &= word - 1
            }
        }
        return result
    }

    private func set(_ id: MeshVertexID, selected: Bool, in target: inout [UInt64]) {
        let value = Int(id), mask = UInt64(1) << UInt64(value & 63)
        if selected { target[value >> 6] |= mask } else { target[value >> 6] &= ~mask }
    }
    private mutating func maskTail() {
        let used = vertexCount & 63
        if used != 0, !bits.isEmpty { bits[bits.count - 1] &= (UInt64(1) << UInt64(used)) - 1 }
    }
}

enum VertexSelectionConnectivity {
    static func connectedVertexIDs(
        table: MeshVertexTopologyTable, seeds: [MeshVertexID]
    ) throws -> [MeshVertexID] {
        guard seeds.allSatisfy({ Int($0) < table.records.count }) else {
            throw VertexSelectionError.invalidVertexID
        }
        var visited = Array(repeating: false, count: table.records.count)
        var queue = Array(Set(seeds)).sorted(), cursor = 0
        queue.forEach { visited[Int($0)] = true }
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            for neighbor in table.records[Int(current)].neighboringVertexIDs where !visited[Int(neighbor)] {
                visited[Int(neighbor)] = true; queue.append(neighbor)
            }
        }
        return visited.indices.compactMap { visited[$0] ? MeshVertexID($0) : nil }
    }
}

struct VertexHoverState: Equatable {
    let vertexID: MeshVertexID?
    let version: VertexSelectionVersion
    init(vertexID: MeshVertexID? = nil, version: VertexSelectionVersion = .init(id: UUID())) {
        self.vertexID = vertexID; self.version = version
    }
    func updating(_ value: MeshVertexID?) -> Self {
        value == vertexID ? self : Self(vertexID: value)
    }
    func effectiveVertexID(for selection: VertexSelection) -> MeshVertexID? {
        vertexID.flatMap { selection.contains($0) ? nil : $0 }
    }
}

enum IndexedMeshVertexPickResult: Equatable {
    case hit(vertexID: MeshVertexID)
    case miss
    case unavailable
}

enum MeshVertexPicker {
    static let pickRadiusPoints: CGFloat = 16

    struct ScreenCandidate: Equatable {
        let vertexID: MeshVertexID
        let point: CGPoint
    }

    static func nearestCandidate(
        to screenPoint: CGPoint, candidates: [ScreenCandidate], threshold: CGFloat
    ) -> MeshVertexID? {
        guard screenPoint.x.isFinite, screenPoint.y.isFinite,
              threshold.isFinite, threshold >= 0 else { return nil }
        let thresholdSquared = threshold * threshold
        guard thresholdSquared.isFinite else { return nil }
        var best: (distanceSquared: CGFloat, vertexID: MeshVertexID)?
        for candidate in candidates {
            guard candidate.point.x.isFinite, candidate.point.y.isFinite else { continue }
            let dx = candidate.point.x - screenPoint.x
            let dy = candidate.point.y - screenPoint.y
            let distanceSquared = dx * dx + dy * dy
            guard distanceSquared.isFinite, distanceSquared <= thresholdSquared else { continue }
            if best == nil
                || distanceSquared < best!.distanceSquared
                || (distanceSquared == best!.distanceSquared && candidate.vertexID < best!.vertexID) {
                best = (distanceSquared, candidate.vertexID)
            }
        }
        return best?.vertexID
    }

    static func pick(
        worldRay: Ray, screenPoint: CGPoint, viewportSize: CGSize,
        mesh: EditableMesh, transform: ObjectTransform,
        viewProjection: simd_float4x4, table: MeshVertexTopologyTable,
        cache: MeshBVHCache, threshold: CGFloat = pickRadiusPoints
    ) -> IndexedMeshVertexPickResult {
        guard worldRay.origin.allFinite, worldRay.direction.allFinite,
              simd_length_squared(worldRay.direction) > 1e-12,
              screenPoint.x.isFinite, screenPoint.y.isFinite,
              table.matches(mesh), threshold.isFinite, threshold >= 0,
              viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0,
              let localRay = transform.localRay(fromWorld: worldRay)
        else { return .unavailable }
        let pick = MeshPicker.indexedHit(ray: localRay, mesh: mesh, culling: .none, cache: cache)
        guard case .hit(let hit) = pick else {
            if case .miss = pick { return .miss }
            return .unavailable
        }
        guard hit.triangleStart >= 0, hit.triangleStart + 2 < mesh.indices.count else {
            return .unavailable
        }
        let ids = Array(mesh.indices[hit.triangleStart...(hit.triangleStart + 2)])
        guard Set(ids).count == 3, ids.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            return .unavailable
        }
        var candidates: [ScreenCandidate] = []
        for id in ids {
            let world = transform.modelMatrix * SIMD4<Float>(mesh.vertices[Int(id)].position, 1)
            let clip = viewProjection * world
            guard [clip.x, clip.y, clip.z, clip.w].allSatisfy(\.isFinite) else { continue }
            guard clip.w > 1e-6, clip.z >= 0, clip.z <= clip.w else { continue }
            let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
            guard ndc.x.isFinite, ndc.y.isFinite, abs(ndc.x) <= 1, abs(ndc.y) <= 1 else { continue }
            let point = CGPoint(
                x: (CGFloat(ndc.x) + 1) * 0.5 * viewportSize.width,
                y: (1 - CGFloat(ndc.y)) * 0.5 * viewportSize.height)
            candidates.append(ScreenCandidate(vertexID: id, point: point))
        }
        guard let nearest = nearestCandidate(
            to: screenPoint, candidates: candidates, threshold: threshold) else { return .miss }
        return .hit(vertexID: nearest)
    }
}

enum VertexSelectionError: Error, Equatable, LocalizedError {
    case invalidMesh, invalidVertexID, staleTopology, allocationOverflow
    case vertexLimitExceeded, workingMemoryLimitExceeded, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidMesh: "Vertex Selection requires a valid indexed triangle mesh."
        case .invalidVertexID: "The vertex ID is outside the current mesh."
        case .staleTopology: "Vertex Selection belongs to an older topology."
        case .allocationOverflow: "Vertex Selection size calculation overflowed."
        case .vertexLimitExceeded: "Vertex Selection exceeds the vertex limit."
        case .workingMemoryLimitExceeded: "Vertex Selection exceeds the working-memory limit."
        case .unavailable: "Vertex Selection is unavailable during the current operation."
        }
    }
}

struct VertexTranslateTransaction: Equatable {
    let id: UUID
    let topologyID: UUID
    let topologyRevision: UInt64
    let topologyFingerprint: UInt64
    let sourceVertexRevision: UInt64
    let vertexIDs: [MeshVertexID]
    let startPositions: [SIMD3<Float>]
    let pivotLocal: SIMD3<Float>
    let pivotWorld: SIMD3<Float>
    let transform: ObjectTransform
    private(set) var worldDelta: SIMD3<Float> = .zero
    private(set) var localDelta: SIMD3<Float> = .zero

    mutating func update(worldDelta: SIMD3<Float>, localDelta: SIMD3<Float>) {
        self.worldDelta = worldDelta
        self.localDelta = localDelta
    }

    func matches(mesh: EditableMesh, table: MeshVertexTopologyTable,
                 selection: VertexSelection, transform: ObjectTransform) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && topologyFingerprint == table.fingerprint
            && sourceVertexRevision == mesh.runtime.revision
            && table.sourceTopologyID == mesh.runtime.topologyID
            && table.sourceTopologyRevision == mesh.runtime.topologyRevision
            && table.sourceVertexCount == mesh.vertices.count
            && table.sourceIndexCount == mesh.indices.count
            && selection.matches(table)
            && vertexIDs == selection.selectedVertexIDs()
            && self.transform == transform.sanitized()
    }
}

enum VertexTranslateError: Error, Equatable, LocalizedError {
    case emptySelection
    case staleSource
    case invalidTransform
    case nonFiniteDelta
    case workingMemoryLimitExceeded
    case allocationOverflow

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one vertex before moving."
        case .staleSource: "The selected vertices changed before the move completed."
        case .invalidTransform: "The object transform cannot be inverted safely."
        case .nonFiniteDelta: "The requested move is outside the supported numeric range."
        case .workingMemoryLimitExceeded: "The move would exceed the working-memory limit."
        case .allocationOverflow: "The move size calculation overflowed."
        }
    }
}

enum VertexTranslateGeometry {
    static let maximumWorkingBytes = 768 * 1_024 * 1_024

    static func begin(
        mesh: EditableMesh, table: MeshVertexTopologyTable,
        selection: VertexSelection, transform: ObjectTransform,
        transactionID: UUID = UUID(), memoryLimit: Int = maximumWorkingBytes
    ) throws -> VertexTranslateTransaction {
        guard table.matches(mesh), selection.matches(table) else {
            throw VertexTranslateError.staleSource
        }
        let ids = selection.selectedVertexIDs()
        guard !ids.isEmpty else { throw VertexTranslateError.emptySelection }
        let estimate = try estimatedPeakBytes(
            vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
            selectedCount: ids.count)
        guard estimate <= memoryLimit else { throw VertexTranslateError.workingMemoryLimitExceeded }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(ids.count)
        for id in ids {
            guard Int(id) < mesh.vertices.count else { throw VertexTranslateError.staleSource }
            let position = mesh.vertices[Int(id)].position
            guard position.allFinite else { throw VertexTranslateError.staleSource }
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
            positions.append(position)
        }
        let safeTransform = transform.sanitized()
        let pivotLocal = (minimum + maximum) * 0.5
        let pivotWorld = safeTransform.worldPosition(fromLocal: pivotLocal)
        guard safeTransform.isFinite, pivotLocal.allFinite, pivotWorld.allFinite,
              matrixIsFinite(safeTransform.inverseModelMatrix) else {
            throw VertexTranslateError.invalidTransform
        }
        return VertexTranslateTransaction(
            id: transactionID, topologyID: mesh.runtime.topologyID,
            topologyRevision: mesh.runtime.topologyRevision,
            topologyFingerprint: table.fingerprint,
            sourceVertexRevision: mesh.runtime.revision, vertexIDs: ids,
            startPositions: positions, pivotLocal: pivotLocal, pivotWorld: pivotWorld,
            transform: safeTransform)
    }

    static func pivot(
        mesh: EditableMesh, table: MeshVertexTopologyTable,
        selection: VertexSelection, transform: ObjectTransform
    ) throws -> (local: SIMD3<Float>, world: SIMD3<Float>) {
        guard table.matches(mesh), selection.matches(table) else {
            throw VertexTranslateError.staleSource
        }
        let ids = selection.selectedVertexIDs()
        guard !ids.isEmpty else { throw VertexTranslateError.emptySelection }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for id in ids {
            guard Int(id) < mesh.vertices.count else { throw VertexTranslateError.staleSource }
            let position = mesh.vertices[Int(id)].position
            guard position.allFinite else { throw VertexTranslateError.staleSource }
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        let local = (minimum + maximum) * 0.5
        let safeTransform = transform.sanitized()
        let world = safeTransform.worldPosition(fromLocal: local)
        guard local.allFinite, world.allFinite else { throw VertexTranslateError.invalidTransform }
        return (local, world)
    }

    static func candidate(
        sourceMesh: EditableMesh, transaction: inout VertexTranslateTransaction,
        worldDelta: SIMD3<Float>, profiler: PerformanceProfiler? = nil
    ) throws -> EditableMesh? {
        guard worldDelta.allFinite else { throw VertexTranslateError.nonFiniteDelta }
        let transformed = transaction.transform.inverseModelMatrix * SIMD4<Float>(worldDelta, 0)
        let localDelta = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
        guard transformed.w.isFinite, abs(transformed.w) <= 0.000_01,
              localDelta.allFinite else { throw VertexTranslateError.nonFiniteDelta }
        transaction.update(worldDelta: worldDelta, localDelta: localDelta)
        guard localDelta != .zero else { return nil }
        guard transaction.topologyID == sourceMesh.runtime.topologyID,
              transaction.topologyRevision == sourceMesh.runtime.topologyRevision,
              transaction.vertexIDs.count == transaction.startPositions.count else {
            throw VertexTranslateError.staleSource
        }
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(transaction.vertexIDs.count)
        for (offset, id) in transaction.vertexIDs.enumerated() {
            let value = transaction.startPositions[offset] + localDelta
            guard value.allFinite else { throw VertexTranslateError.nonFiniteDelta }
            updates[Int(id)] = value
        }
        var candidate = sourceMesh
        let mutations = candidate.updatePositions(updates, profiler: profiler)
        guard mutations.isEmpty || mutations.count == updates.count else {
            throw VertexTranslateError.staleSource
        }
        return candidate
    }

    static func estimatedPeakBytes(
        vertexCount: Int, indexCount: Int, selectedCount: Int
    ) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0, selectedCount >= 0 else {
            throw VertexTranslateError.allocationOverflow
        }
        var bytes = 0
        func add(_ count: Int, _ stride: Int) throws {
            let (part, firstOverflow) = count.multipliedReportingOverflow(by: stride)
            let (total, secondOverflow) = bytes.addingReportingOverflow(part)
            guard !firstOverflow, !secondOverflow else { throw VertexTranslateError.allocationOverflow }
            bytes = total
        }
        // Source and preview vertex/index storage plus selection snapshots and update staging.
        try add(vertexCount, MemoryLayout<MeshVertex>.stride * 2)
        try add(indexCount, MemoryLayout<UInt32>.stride * 2)
        try add(selectedCount, MemoryLayout<MeshVertexID>.stride)
        try add(selectedCount, MemoryLayout<SIMD3<Float>>.stride * 2)
        try add(selectedCount, 64)
        return bytes
    }

    private static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in
            (0..<4).allSatisfy { matrix[column][$0].isFinite }
        }
    }
}
