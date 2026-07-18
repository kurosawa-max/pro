import Foundation
import simd

struct AxisAlignedBoundingBox: Equatable {
    private(set) var minimum = SIMD3<Float>(repeating: .infinity)
    private(set) var maximum = SIMD3<Float>(repeating: -.infinity)

    var isFinite: Bool {
        minimum.allFinite && maximum.allFinite &&
            minimum.x <= maximum.x && minimum.y <= maximum.y && minimum.z <= maximum.z
    }
    var center: SIMD3<Float> { isFinite ? (minimum + maximum) * 0.5 : .zero }
    var extent: SIMD3<Float> { isFinite ? maximum - minimum : .zero }
    var surfaceArea: Float {
        let e = extent
        let value = 2 * (e.x * e.y + e.y * e.z + e.z * e.x)
        return value.isFinite ? value : 0
    }

    mutating func include(_ point: SIMD3<Float>) {
        guard point.allFinite else { return }
        minimum = simd_min(minimum, point); maximum = simd_max(maximum, point)
    }

    mutating func include(_ other: AxisAlignedBoundingBox) {
        guard other.isFinite else { return }
        include(other.minimum); include(other.maximum)
    }

    func contains(_ point: SIMD3<Float>, epsilon: Float = 0.000_001) -> Bool {
        isFinite && point.allFinite &&
            point.x >= minimum.x - epsilon && point.y >= minimum.y - epsilon && point.z >= minimum.z - epsilon &&
            point.x <= maximum.x + epsilon && point.y <= maximum.y + epsilon && point.z <= maximum.z + epsilon
    }

    func contains(_ other: AxisAlignedBoundingBox, epsilon: Float = 0.000_001) -> Bool {
        other.isFinite && contains(other.minimum, epsilon: epsilon) && contains(other.maximum, epsilon: epsilon)
    }

    func rayNearDistance(_ ray: Ray, maximumDistance: Float = .greatestFiniteMagnitude) -> Float? {
        guard isFinite, ray.origin.allFinite, ray.direction.allFinite, maximumDistance.isFinite || maximumDistance == .greatestFiniteMagnitude else { return nil }
        var near: Float = 0, far = maximumDistance
        for axis in 0..<3 {
            let origin = ray.origin[axis], direction = ray.direction[axis]
            if abs(direction) < 0.000_000_1 {
                guard origin >= minimum[axis], origin <= maximum[axis] else { return nil }
                continue
            }
            let inverse = 1 / direction
            var first = (minimum[axis] - origin) * inverse
            var second = (maximum[axis] - origin) * inverse
            if first > second { swap(&first, &second) }
            near = max(near, first); far = min(far, second)
            if near > far { return nil }
        }
        return far >= 0 && near <= maximumDistance ? max(near, 0) : nil
    }
}

struct TriangleReference: Equatable {
    let triangleStart: Int
    var bounds: AxisAlignedBoundingBox
    var centroid: SIMD3<Float>
}

struct BVHNode: Equatable {
    var bounds = AxisAlignedBoundingBox()
    var left = -1
    var right = -1
    var start = 0
    var count = 0
    var isLeaf: Bool { count > 0 }
}

struct MeshBVH {
    static let leafThreshold = 8
    static let maximumDepth = 64
    private(set) var nodes: [BVHNode] = []
    private(set) var triangles: [TriangleReference] = []
    var isEmpty: Bool { nodes.isEmpty }

    init(mesh: EditableMesh) throws {
        guard mesh.indices.count.isMultiple(of: 3) else { throw MeshBVHError.invalidMesh }
        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            triangles.append(try Self.reference(mesh: mesh, triangleStart: start))
        }
        if !triangles.isEmpty { _ = build(start: 0, end: triangles.count, depth: 0) }
    }

    mutating func refit(mesh: EditableMesh) throws {
        for index in triangles.indices {
            triangles[index] = try Self.reference(mesh: mesh, triangleStart: triangles[index].triangleStart)
        }
        for index in nodes.indices.reversed() {
            if nodes[index].isLeaf {
                var bounds = AxisAlignedBoundingBox()
                for item in nodes[index].start..<(nodes[index].start + nodes[index].count) { bounds.include(triangles[item].bounds) }
                nodes[index].bounds = bounds
            } else {
                var bounds = AxisAlignedBoundingBox(); bounds.include(nodes[nodes[index].left].bounds); bounds.include(nodes[nodes[index].right].bounds)
                nodes[index].bounds = bounds
            }
            guard nodes[index].bounds.isFinite else { throw MeshBVHError.nonFiniteBounds }
        }
    }

    private mutating func build(start: Int, end: Int, depth: Int) -> Int {
        let nodeIndex = nodes.count; nodes.append(BVHNode())
        var bounds = AxisAlignedBoundingBox(), centroidBounds = AxisAlignedBoundingBox()
        for index in start..<end { bounds.include(triangles[index].bounds); centroidBounds.include(triangles[index].centroid) }
        let count = end - start
        if count <= Self.leafThreshold || depth >= Self.maximumDepth || !centroidBounds.isFinite {
            nodes[nodeIndex] = BVHNode(bounds: bounds, start: start, count: count); return nodeIndex
        }
        let extent = centroidBounds.extent
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        if extent[axis] <= 0 { nodes[nodeIndex] = BVHNode(bounds: bounds, start: start, count: count); return nodeIndex }
        triangles[start..<end].sort { lhs, rhs in
            lhs.centroid[axis] == rhs.centroid[axis] ? lhs.triangleStart < rhs.triangleStart : lhs.centroid[axis] < rhs.centroid[axis]
        }
        let middle = start + count / 2
        let left = build(start: start, end: middle, depth: depth + 1)
        let right = build(start: middle, end: end, depth: depth + 1)
        nodes[nodeIndex] = BVHNode(bounds: bounds, left: left, right: right)
        return nodeIndex
    }

    private static func reference(mesh: EditableMesh, triangleStart: Int) throws -> TriangleReference {
        guard triangleStart + 2 < mesh.indices.count else { throw MeshBVHError.invalidMesh }
        let ids = (0..<3).map { Int(mesh.indices[triangleStart + $0]) }
        guard ids.allSatisfy({ mesh.vertices.indices.contains($0) }) else { throw MeshBVHError.invalidMesh }
        let points = ids.map { mesh.vertices[$0].position }
        guard points.allSatisfy(\.allFinite) else { throw MeshBVHError.nonFiniteBounds }
        var bounds = AxisAlignedBoundingBox(); points.forEach { bounds.include($0) }
        return TriangleReference(triangleStart: triangleStart, bounds: bounds, centroid: (points[0] + points[1] + points[2]) / 3)
    }
}

enum MeshBVHError: Error { case invalidMesh, nonFiniteBounds }

final class MeshBVHCache {
    typealias Builder = (EditableMesh) throws -> MeshBVH

    private(set) var bvh: MeshBVH?
    private(set) var topologyID: UUID?
    private(set) var topologyRevision: UInt64?
    private(set) var revision: UInt64?
    private(set) var buildCount = 0
    private(set) var refitCount = 0
    private(set) var reuseCount = 0
    private let builder: Builder

    init(builder: @escaping Builder = { try MeshBVH(mesh: $0) }) {
        self.builder = builder
    }

    func makeIndex(for mesh: EditableMesh) throws -> MeshBVH {
        try builder(mesh)
    }

    func index(for mesh: EditableMesh) -> MeshBVH? {
        do {
            if bvh == nil || topologyID != mesh.runtime.topologyID
                || topologyRevision != mesh.runtime.topologyRevision {
                bvh = try makeIndex(for: mesh)
                topologyID = mesh.runtime.topologyID
                topologyRevision = mesh.runtime.topologyRevision
                revision = mesh.runtime.revision
                buildCount += 1
            } else if revision != mesh.runtime.revision {
                try bvh?.refit(mesh: mesh); revision = mesh.runtime.revision; refitCount += 1
            } else { reuseCount += 1 }
            return bvh
        } catch {
            invalidate()
            return nil
        }
    }

    @discardableResult
    func rebuild(for mesh: EditableMesh) -> Bool {
        invalidate()
        do {
            install(try makeIndex(for: mesh), for: mesh)
            return true
        } catch {
            invalidate()
            return false
        }
    }

    func install(_ rebuilt: MeshBVH, for mesh: EditableMesh) {
        bvh = rebuilt
        topologyID = mesh.runtime.topologyID
        topologyRevision = mesh.runtime.topologyRevision
        revision = mesh.runtime.revision
        buildCount += 1
    }

    func invalidate() {
        bvh = nil
        topologyID = nil
        topologyRevision = nil
        revision = nil
    }
}

private struct SpatialCell: Hashable {
    let x: Int, y: Int, z: Int
}

final class VertexSpatialIndex {
    private let cellSize: Float
    private var cells: [SpatialCell: Set<Int>] = [:]
    private var vertexCells: [SpatialCell] = []
    private(set) var topologyID: UUID?
    private(set) var revision: UInt64?
    private(set) var buildCount = 0
    private(set) var updateCount = 0

    init(cellSize: Float = 0.25) { self.cellSize = max(cellSize, 0.001) }

    func candidates(center: SIMD3<Float>, radius: Float, mesh: EditableMesh) -> [Int] {
        guard center.allFinite, radius.isFinite, radius > 0 else { return [] }
        prepare(for: mesh)
        let minimum = cell(for: center - SIMD3<Float>(repeating: radius))
        let maximum = cell(for: center + SIMD3<Float>(repeating: radius))
        var result = Set<Int>()
        for x in minimum.x...maximum.x { for y in minimum.y...maximum.y { for z in minimum.z...maximum.z {
            if let values = cells[SpatialCell(x: x, y: y, z: z)] { result.formUnion(values) }
        } } }
        return result.sorted()
    }

    func didUpdate(_ mutations: [VertexMutation], mesh: EditableMesh) {
        guard topologyID == mesh.runtime.topologyID, vertexCells.count == mesh.vertices.count else {
            rebuild(mesh); return
        }
        for mutation in mutations {
            guard vertexCells.indices.contains(mutation.index) else { continue }
            let oldCell = vertexCells[mutation.index], newCell = cell(for: mutation.after)
            if oldCell != newCell {
                cells[oldCell]?.remove(mutation.index)
                if cells[oldCell]?.isEmpty == true { cells.removeValue(forKey: oldCell) }
                cells[newCell, default: []].insert(mutation.index)
                vertexCells[mutation.index] = newCell
            }
        }
        revision = mesh.runtime.revision
        if !mutations.isEmpty { updateCount += 1 }
    }

    func prepare(for mesh: EditableMesh) {
        if topologyID != mesh.runtime.topologyID || vertexCells.count != mesh.vertices.count { rebuild(mesh) }
        else if revision != mesh.runtime.revision { rebuild(mesh) }
    }

    private func rebuild(_ mesh: EditableMesh) {
        cells.removeAll(keepingCapacity: true)
        vertexCells = mesh.vertices.map { cell(for: $0.position) }
        for index in vertexCells.indices { cells[vertexCells[index], default: []].insert(index) }
        topologyID = mesh.runtime.topologyID; revision = mesh.runtime.revision; buildCount += 1
    }

    private func cell(for point: SIMD3<Float>) -> SpatialCell {
        SpatialCell(x: Int(floor(point.x / cellSize)), y: Int(floor(point.y / cellSize)), z: Int(floor(point.z / cellSize)))
    }
}
