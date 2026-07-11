import simd

struct Ray { var origin: SIMD3<Float>; var direction: SIMD3<Float> }

enum FaceCulling { case none, back }

struct MeshHit {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var barycentric: SIMD3<Float>
    var distance: Float
    var triangleStart: Int
}

private struct TriangleIntersection {
    var distance: Float
    var u: Float
    var v: Float
}

enum MeshPicker {
    static func hit(ray: Ray, mesh: EditableMesh, culling: FaceCulling = .none) -> MeshHit? {
        guard ray.origin.allFinite, ray.direction.allFinite else { return nil }
        var nearest: MeshHit?
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[triangle])]
            let b = mesh.vertices[Int(mesh.indices[triangle + 1])]
            let c = mesh.vertices[Int(mesh.indices[triangle + 2])]
            guard let intersection = triangleIntersection(
                ray: ray, a: a.position, b: b.position, c: c.position, culling: culling
            ), intersection.distance < (nearest?.distance ?? .greatestFiniteMagnitude) else { continue }

            let barycentric = SIMD3<Float>(1 - intersection.u - intersection.v, intersection.u, intersection.v)
            let interpolatedNormal = a.normal * barycentric.x + b.normal * barycentric.y + c.normal * barycentric.z
            let normalLength = simd_length(interpolatedNormal)
            let faceNormal = simd_cross(b.position - a.position, c.position - a.position)
            let normal = normalLength.isFinite && normalLength > 0.000_001
                ? interpolatedNormal / normalLength : simd_normalize(faceNormal)
            nearest = MeshHit(
                position: ray.origin + ray.direction * intersection.distance,
                normal: normal,
                barycentric: barycentric,
                distance: intersection.distance,
                triangleStart: triangle
            )
        }
        return nearest
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
}
