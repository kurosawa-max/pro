import Foundation
import simd

struct SpatialCellCoordinate: Hashable, Comparable {
    let x: Int
    let y: Int
    let z: Int

    init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }

    init?(position: SIMD3<Float>, cellSize: Float) {
        guard position.allFinite, cellSize.isFinite, cellSize > 0 else { return nil }
        let values = [position.x, position.y, position.z].map { floor(Double($0) / Double(cellSize)) }
        guard values.allSatisfy({ $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) }) else { return nil }
        x = Int(values[0]); y = Int(values[1]); z = Int(values[2])
    }

    static func < (lhs: SpatialCellCoordinate, rhs: SpatialCellCoordinate) -> Bool {
        lhs.x != rhs.x ? lhs.x < rhs.x : (lhs.y != rhs.y ? lhs.y < rhs.y : lhs.z < rhs.z)
    }
}

struct VertexSpatialHash {
    static let fallbackCellSize: Float = 0.1
    static let minimumCellSize: Float = 0.001
    static let maximumCellSize: Float = 1
    static let maximumEnumeratedCells = 32_768

    let cellSize: Float
    private(set) var buckets: [SpatialCellCoordinate: [Int]] = [:]
    private(set) var vertexCells: [SpatialCellCoordinate?]
    private(set) var registeredVertexCount = 0
    private(set) var topologyID: UUID
    private(set) var revision: UInt64

    init(mesh: EditableMesh) throws {
        cellSize = Self.representativeCellSize(mesh: mesh)
        topologyID = mesh.runtime.topologyID
        revision = mesh.runtime.revision
        vertexCells = Array(repeating: nil, count: mesh.vertices.count)
        for index in mesh.vertices.indices {
            guard let cell = SpatialCellCoordinate(position: mesh.vertices[index].position, cellSize: cellSize) else {
                throw VertexSpatialHashError.invalidVertex
            }
            buckets[cell, default: []].append(index)
            vertexCells[index] = cell
            registeredVertexCount += 1
        }
    }

    func vertices(near center: SIMD3<Float>, radius: Float, mesh: EditableMesh) -> [Int]? {
        guard center.allFinite, radius.isFinite, radius > 0, topologyID == mesh.runtime.topologyID,
              mesh.vertices.count == vertexCells.count else { return nil }
        let offset = SIMD3<Float>(repeating: radius)
        guard let minimum = SpatialCellCoordinate(position: center - offset, cellSize: cellSize),
              let maximum = SpatialCellCoordinate(position: center + offset, cellSize: cellSize) else { return nil }
        let xCount = maximum.x.subtractingReportingOverflow(minimum.x).partialValue.addingReportingOverflow(1)
        let yCount = maximum.y.subtractingReportingOverflow(minimum.y).partialValue.addingReportingOverflow(1)
        let zCount = maximum.z.subtractingReportingOverflow(minimum.z).partialValue.addingReportingOverflow(1)
        guard !xCount.overflow, !yCount.overflow, !zCount.overflow, xCount.partialValue > 0,
              yCount.partialValue > 0, zCount.partialValue > 0 else { return nil }
        let xy = xCount.partialValue.multipliedReportingOverflow(by: yCount.partialValue)
        let xyz = xy.partialValue.multipliedReportingOverflow(by: zCount.partialValue)
        guard !xy.overflow, !xyz.overflow, xyz.partialValue <= Self.maximumEnumeratedCells else { return nil }
        let radiusSquared = radius * radius
        var result: [Int] = []
        for x in minimum.x...maximum.x {
            for y in minimum.y...maximum.y {
                for z in minimum.z...maximum.z {
                    for index in buckets[SpatialCellCoordinate(x: x, y: y, z: z)] ?? [] where mesh.vertices.indices.contains(index) {
                        let delta = mesh.vertices[index].position - center
                        let distanceSquared = simd_length_squared(delta)
                        if distanceSquared.isFinite && distanceSquared <= radiusSquared { result.append(index) }
                    }
                }
            }
        }
        return result.sorted()
    }

    mutating func update(mutations: [VertexMutation], mesh: EditableMesh) throws {
        guard topologyID == mesh.runtime.topologyID, vertexCells.count == mesh.vertices.count else { throw VertexSpatialHashError.staleCache }
        for mutation in mutations.sorted(by: { $0.index < $1.index }) {
            guard mesh.vertices.indices.contains(mutation.index), let oldCell = vertexCells[mutation.index],
                  oldCell == SpatialCellCoordinate(position: mutation.before, cellSize: cellSize),
                  let newCell = SpatialCellCoordinate(position: mesh.vertices[mutation.index].position, cellSize: cellSize) else {
                throw VertexSpatialHashError.invalidVertex
            }
            guard oldCell != newCell else { continue }
            guard var oldBucket = buckets[oldCell], let offset = oldBucket.firstIndex(of: mutation.index) else {
                throw VertexSpatialHashError.bucketMismatch
            }
            oldBucket.remove(at: offset)
            if oldBucket.isEmpty { buckets.removeValue(forKey: oldCell) } else { buckets[oldCell] = oldBucket }
            var newBucket = buckets[newCell] ?? []
            guard !newBucket.contains(mutation.index) else { throw VertexSpatialHashError.bucketMismatch }
            newBucket.append(mutation.index); newBucket.sort(); buckets[newCell] = newBucket
            vertexCells[mutation.index] = newCell
        }
        revision = mesh.runtime.revision
    }

    private static func representativeCellSize(mesh: EditableMesh) -> Float {
        var edges = Set<UInt64>(), total: Double = 0, count = 0
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) where triangle + 2 < mesh.indices.count {
            let ids = [mesh.indices[triangle], mesh.indices[triangle + 1], mesh.indices[triangle + 2]]
            for pair in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
                let low = min(pair.0, pair.1), high = max(pair.0, pair.1)
                let key = (UInt64(low) << 32) | UInt64(high)
                guard edges.insert(key).inserted, Int(high) < mesh.vertices.count else { continue }
                let length = simd_distance(mesh.vertices[Int(low)].position, mesh.vertices[Int(high)].position)
                if length.isFinite && length > 0 { total += Double(length); count += 1 }
            }
        }
        guard count > 0 else { return fallbackCellSize }
        let average = Float(total / Double(count))
        return average.isFinite ? min(max(average, minimumCellSize), maximumCellSize) : fallbackCellSize
    }
}

enum VertexSpatialHashError: Error { case invalidVertex, staleCache, bucketMismatch }

final class VertexSpatialHashCache {
    private(set) var index: VertexSpatialHash?
    private(set) var buildCount = 0
    private(set) var incrementalUpdateCount = 0
    private(set) var reuseCount = 0
    private(set) var fallbackCount = 0

    func vertices(near center: SIMD3<Float>, radius: Float, mesh: EditableMesh) -> [Int]? {
        do {
            if index == nil || index?.topologyID != mesh.runtime.topologyID || index?.revision != mesh.runtime.revision {
                index = try VertexSpatialHash(mesh: mesh); buildCount += 1
            } else { reuseCount += 1 }
            guard let result = index?.vertices(near: center, radius: radius, mesh: mesh) else {
                fallbackCount += 1; return nil
            }
            return result
        } catch {
            index = nil; fallbackCount += 1; return nil
        }
    }

    func update(mutations: [VertexMutation], mesh: EditableMesh) {
        guard !mutations.isEmpty else { return }
        do {
            try index?.update(mutations: mutations, mesh: mesh)
            if index != nil { incrementalUpdateCount += 1 }
        } catch {
            index = nil; fallbackCount += 1
        }
    }
}
