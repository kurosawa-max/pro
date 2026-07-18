import simd

struct Ray { var origin: SIMD3<Float>; var direction: SIMD3<Float> }

enum FaceCulling { case none, back }

struct MeshHit {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var barycentric: SIMD3<Float>
    var distance: Float
    var triangleStart: Int

    var triangleIndex: Int { triangleStart / 3 }
}

enum IndexedMeshPickResult {
    case hit(MeshHit)
    case miss
    case unavailable
}

private struct TriangleIntersection {
    var distance: Float
    var u: Float
    var v: Float
}

enum MeshPicker {
    static func hit(
        ray: Ray,
        mesh: EditableMesh,
        culling: FaceCulling = .none,
        profiler: PerformanceProfiler? = nil,
        cache: MeshBVHCache? = nil
    ) -> MeshHit? {
        PerformanceProfiler.measure(profiler, metric: .picking) {
            let activeCache = cache ?? MeshBVHCache()
            guard let bvh = activeCache.index(for: mesh) else { return hitLinearUnmeasured(ray: ray, mesh: mesh, culling: culling) }
            return hitBVHUnmeasured(ray: ray, mesh: mesh, culling: culling, bvh: bvh)
        }
    }

    static func hitLinear(ray: Ray, mesh: EditableMesh, culling: FaceCulling = .none) -> MeshHit? {
        hitLinearUnmeasured(ray: ray, mesh: mesh, culling: culling)
    }

    static func indexedHit(
        ray: Ray,
        mesh: EditableMesh,
        culling: FaceCulling = .none,
        profiler: PerformanceProfiler? = nil,
        cache: MeshBVHCache
    ) -> IndexedMeshPickResult {
        PerformanceProfiler.measure(profiler, metric: .picking) {
            guard isValid(ray) else { return .unavailable }
            guard let bvh = cache.index(for: mesh),
                  cache.topologyID == mesh.runtime.topologyID,
                  cache.topologyRevision == mesh.runtime.topologyRevision,
                  cache.revision == mesh.runtime.revision else { return .unavailable }
            guard let hit = hitBVHUnmeasured(ray: ray, mesh: mesh, culling: culling, bvh: bvh) else {
                return .miss
            }
            guard hit.triangleStart.isMultiple(of: 3),
                  hit.triangleIndex >= 0,
                  hit.triangleIndex < mesh.indices.count / 3 else { return .unavailable }
            return .hit(hit)
        }
    }

    private static func hitLinearUnmeasured(ray: Ray, mesh: EditableMesh, culling: FaceCulling) -> MeshHit? {
        guard isValid(ray) else { return nil }
        var nearest: MeshHit?
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            if let hit = triangleHit(ray: ray, mesh: mesh, triangleStart: triangle, culling: culling), isPreferred(hit, over: nearest) { nearest = hit }
        }
        return nearest
    }

    private static func hitBVHUnmeasured(ray: Ray, mesh: EditableMesh, culling: FaceCulling, bvh: MeshBVH) -> MeshHit? {
        guard isValid(ray), !bvh.nodes.isEmpty,
              let rootNear = bvh.nodes[0].bounds.rayNearDistance(ray) else { return nil }
        var nearest: MeshHit?
        var stack: [(index: Int, near: Float)] = [(0, rootNear)]
        while let item = stack.popLast() {
            if item.near > (nearest?.distance ?? .greatestFiniteMagnitude) { continue }
            let node = bvh.nodes[item.index]
            if node.isLeaf {
                for referenceIndex in node.start..<(node.start + node.count) {
                    let triangle = bvh.triangles[referenceIndex].triangleStart
                    if let hit = triangleHit(ray: ray, mesh: mesh, triangleStart: triangle, culling: culling), isPreferred(hit, over: nearest) { nearest = hit }
                }
            } else {
                let maximum = nearest?.distance ?? .greatestFiniteMagnitude
                let leftNear = bvh.nodes[node.left].bounds.rayNearDistance(ray, maximumDistance: maximum)
                let rightNear = bvh.nodes[node.right].bounds.rayNearDistance(ray, maximumDistance: maximum)
                if let leftNear, let rightNear {
                    if leftNear <= rightNear { stack.append((node.right, rightNear)); stack.append((node.left, leftNear)) }
                    else { stack.append((node.left, leftNear)); stack.append((node.right, rightNear)) }
                } else if let leftNear { stack.append((node.left, leftNear)) }
                else if let rightNear { stack.append((node.right, rightNear)) }
            }
        }
        return nearest
    }

    private static func isPreferred(_ candidate: MeshHit, over current: MeshHit?) -> Bool {
        guard let current else { return true }
        let epsilon: Float = 0.000_001
        return candidate.distance < current.distance - epsilon ||
            (abs(candidate.distance - current.distance) <= epsilon && candidate.triangleStart < current.triangleStart)
    }

    private static func triangleHit(ray: Ray, mesh: EditableMesh, triangleStart: Int, culling: FaceCulling) -> MeshHit? {
        guard triangleStart + 2 < mesh.indices.count else { return nil }
        let ids = (0..<3).map { Int(mesh.indices[triangleStart + $0]) }
        guard ids.allSatisfy({ mesh.vertices.indices.contains($0) }) else { return nil }
        let a = mesh.vertices[ids[0]], b = mesh.vertices[ids[1]], c = mesh.vertices[ids[2]]
        guard let intersection = triangleIntersection(ray: ray, a: a.position, b: b.position, c: c.position, culling: culling) else { return nil }
        let barycentric = SIMD3<Float>(1 - intersection.u - intersection.v, intersection.u, intersection.v)
        let interpolatedNormal = a.normal * barycentric.x + b.normal * barycentric.y + c.normal * barycentric.z
        let normalLength = simd_length(interpolatedNormal)
        let faceNormal = simd_cross(b.position - a.position, c.position - a.position)
        let faceLength = simd_length(faceNormal)
        let normal = normalLength.isFinite && normalLength > 0.000_001 ? interpolatedNormal / normalLength :
            (faceLength.isFinite && faceLength > 0.000_001 ? faceNormal / faceLength : SIMD3<Float>(0, 1, 0))
        return MeshHit(position: ray.origin + ray.direction * intersection.distance, normal: normal,
                       barycentric: barycentric, distance: intersection.distance, triangleStart: triangleStart)
    }

    private static func triangleIntersection(
        ray: Ray,
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>,
        culling: FaceCulling
    ) -> TriangleIntersection? {
        let epsilon: Float = 0.000_001
        let edge1 = b - a, edge2 = c - a
        let h = simd_cross(ray.direction, edge2)
        let determinant = simd_dot(edge1, h)
        switch culling {
        case .none: guard abs(determinant) > epsilon else { return nil }
        case .back: guard determinant > epsilon else { return nil }
        }
        let inverse = 1 / determinant
        let s = ray.origin - a
        let u = inverse * simd_dot(s, h)
        guard u >= -epsilon, u <= 1 + epsilon else { return nil }
        let q = simd_cross(s, edge1)
        let v = inverse * simd_dot(ray.direction, q)
        guard v >= -epsilon, u + v <= 1 + epsilon else { return nil }
        let distance = inverse * simd_dot(edge2, q)
        guard distance > epsilon, distance.isFinite else { return nil }
        return TriangleIntersection(distance: distance, u: u, v: v)
    }


    private static func isValid(_ ray: Ray) -> Bool {
        guard ray.origin.allFinite, ray.direction.allFinite else { return false }
        let lengthSquared = simd_length_squared(ray.direction)
        return lengthSquared.isFinite && lengthSquared > 0.000_000_000_001
    }
}
