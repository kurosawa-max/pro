import Foundation
import simd

struct MeshVertex: Codable, Equatable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct MeshRuntimeState: Equatable {
    var topologyID = UUID()
    var revision: UInt64 = 1
    var topologyRevision: UInt64 = 1
    var changedVertexRange: Range<Int>?
}

struct EditableMesh: Codable, Equatable {
    private(set) var vertices: [MeshVertex]
    private(set) var indices: [UInt32]

    private var adjacencyCache: [[Int]]?
    private(set) var runtime = MeshRuntimeState()

    private enum CodingKeys: String, CodingKey { case vertices, indices }

    init(vertices: [MeshVertex], indices: [UInt32]) {
        self.vertices = vertices
        self.indices = indices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vertices = try container.decode([MeshVertex].self, forKey: .vertices)
        indices = try container.decode([UInt32].self, forKey: .indices)
        adjacencyCache = nil
        runtime = MeshRuntimeState()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vertices, forKey: .vertices)
        try container.encode(indices, forKey: .indices)
    }

    static func == (lhs: EditableMesh, rhs: EditableMesh) -> Bool {
        lhs.vertices == rhs.vertices && lhs.indices == rhs.indices
    }

    static func icosphere(subdivisions: Int = 3) -> EditableMesh {
        precondition((0...6).contains(subdivisions))
        let goldenRatio = (1 + sqrt(Float(5))) / 2
        var positions = [
            SIMD3<Float>(-1, goldenRatio, 0), SIMD3<Float>(1, goldenRatio, 0),
            SIMD3<Float>(-1, -goldenRatio, 0), SIMD3<Float>(1, -goldenRatio, 0),
            SIMD3<Float>(0, -1, goldenRatio), SIMD3<Float>(0, 1, goldenRatio),
            SIMD3<Float>(0, -1, -goldenRatio), SIMD3<Float>(0, 1, -goldenRatio),
            SIMD3<Float>(goldenRatio, 0, -1), SIMD3<Float>(goldenRatio, 0, 1),
            SIMD3<Float>(-goldenRatio, 0, -1), SIMD3<Float>(-goldenRatio, 0, 1),
        ].map { simd_normalize($0) }
        var triangles: [[UInt32]] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
        ]

        for _ in 0..<subdivisions {
            var midpointCache: [UInt64: UInt32] = [:]
            func midpoint(_ first: UInt32, _ second: UInt32) -> UInt32 {
                let low = min(first, second), high = max(first, second)
                let key = (UInt64(low) << 32) | UInt64(high)
                if let cached = midpointCache[key] { return cached }
                let index = UInt32(positions.count)
                positions.append(simd_normalize((positions[Int(first)] + positions[Int(second)]) * 0.5))
                midpointCache[key] = index
                return index
            }
            var refined: [[UInt32]] = []
            refined.reserveCapacity(triangles.count * 4)
            for triangle in triangles {
                let a = midpoint(triangle[0], triangle[1])
                let b = midpoint(triangle[1], triangle[2])
                let c = midpoint(triangle[2], triangle[0])
                refined.append(contentsOf: [
                    [triangle[0], a, c], [triangle[1], b, a],
                    [triangle[2], c, b], [a, b, c],
                ])
            }
            triangles = refined
        }

        var mesh = EditableMesh(
            vertices: positions.map { MeshVertex(position: $0, normal: $0) },
            indices: triangles.flatMap { $0 }
        )
        mesh.recalculateNormals(recordChange: false)
        _ = mesh.adjacency()
        return mesh
    }

    mutating func adjacency() -> [[Int]] {
        if let adjacencyCache { return adjacencyCache }
        var sets = Array(repeating: Set<Int>(), count: vertices.count)
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[triangle]), b = Int(indices[triangle + 1]), c = Int(indices[triangle + 2])
            guard sets.indices.contains(a), sets.indices.contains(b), sets.indices.contains(c) else { continue }
            sets[a].formUnion([b, c]); sets[b].formUnion([a, c]); sets[c].formUnion([a, b])
        }
        let built = sets.map { $0.sorted() }
        adjacencyCache = built
        return built
    }

    var hasCachedAdjacency: Bool { adjacencyCache != nil }

    var bounds: AxisAlignedBoundingBox {
        var value = AxisAlignedBoundingBox()
        vertices.forEach { value.include($0.position) }
        return value
    }

    mutating func updatePositions(
        _ updates: [Int: SIMD3<Float>],
        profiler: PerformanceProfiler? = nil
    ) -> [VertexMutation] {
        var mutations: [VertexMutation] = []
        mutations.reserveCapacity(updates.count)
        for (index, position) in updates.sorted(by: { $0.key < $1.key })
            where vertices.indices.contains(index) && position.allFinite && position != vertices[index].position {
            let before = vertices[index].position
            vertices[index].position = position
            mutations.append(VertexMutation(index: index, before: before, after: position))
        }
        guard !mutations.isEmpty else { return [] }
        let affected = recalculateNormals(around: mutations.map(\.index), profiler: profiler)
        recordVertexChange(indices: affected)
        return mutations
    }

    @discardableResult
    mutating func recalculateNormals(around changed: [Int], profiler: PerformanceProfiler? = nil) -> [Int] {
        var affected = Set(changed.filter(vertices.indices.contains))
        let neighbors = adjacency()
        for index in Array(affected) { affected.formUnion(neighbors[index]) }
        let ordered = affected.sorted()
        guard !ordered.isEmpty else { return [] }
        PerformanceProfiler.measure(profiler, metric: .normalRebuild) {
            for index in ordered { vertices[index].normal = .zero }
            for triangle in stride(from: 0, to: indices.count, by: 3) {
                let ids = [Int(indices[triangle]), Int(indices[triangle + 1]), Int(indices[triangle + 2])]
                guard ids.allSatisfy(vertices.indices.contains), ids.contains(where: affected.contains) else { continue }
                let normal = simd_cross(vertices[ids[1]].position - vertices[ids[0]].position,
                                        vertices[ids[2]].position - vertices[ids[0]].position)
                guard normal.allFinite else { continue }
                for index in ids where affected.contains(index) { vertices[index].normal += normal }
            }
            for index in ordered {
                let length = simd_length(vertices[index].normal)
                vertices[index].normal = length.isFinite && length > 0.000_001
                    ? vertices[index].normal / length : SIMD3<Float>(0, 1, 0)
            }
        }
        return ordered
    }

    mutating func recalculateNormals(
        recordChange: Bool = true,
        profiler: PerformanceProfiler? = nil
    ) {
        PerformanceProfiler.measure(profiler, metric: .normalRebuild) {
            recalculateNormalsUnmeasured(recordChange: recordChange)
        }
    }

    private mutating func recalculateNormalsUnmeasured(recordChange: Bool) {
        guard indices.count.isMultiple(of: 3) else { return }
        for i in vertices.indices { vertices[i].normal = .zero }
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[triangle]), ib = Int(indices[triangle + 1]), ic = Int(indices[triangle + 2])
            guard vertices.indices.contains(ia), vertices.indices.contains(ib), vertices.indices.contains(ic) else { continue }
            let normal = simd_cross(vertices[ib].position - vertices[ia].position,
                                    vertices[ic].position - vertices[ia].position)
            guard normal.allFinite else { continue }
            vertices[ia].normal += normal; vertices[ib].normal += normal; vertices[ic].normal += normal
        }
        for index in vertices.indices {
            let length = simd_length(vertices[index].normal)
            vertices[index].normal = length.isFinite && length > 0.000_001
                ? vertices[index].normal / length : SIMD3<Float>(0, 1, 0)
        }
        if recordChange { recordVertexChange(indices: Array(vertices.indices)) }
    }

    func validated(maxVertices: Int = 2_000_000, maxIndices: Int = 12_000_000) throws -> EditableMesh {
        guard !vertices.isEmpty, !indices.isEmpty, vertices.count <= maxVertices, indices.count <= maxIndices,
              indices.count.isMultiple(of: 3) else { throw MeshError.invalidStructure }
        guard indices.allSatisfy({ Int($0) < vertices.count }) else { throw MeshError.indexOutOfRange }
        guard vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else { throw MeshError.nonFiniteValue }
        return self
    }

    private mutating func recordVertexChange(indices changedIndices: [Int]) {
        guard let first = changedIndices.min(), let last = changedIndices.max() else { return }
        runtime.revision &+= 1
        runtime.changedVertexRange = first..<(last + 1)
    }
}

struct VertexMutation: Equatable {
    let index: Int
    let before: SIMD3<Float>
    let after: SIMD3<Float>
}

extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

enum MeshError: Error { case invalidStructure, indexOutOfRange, nonFiniteValue }
