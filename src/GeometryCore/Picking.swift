import simd

struct Ray { var origin: SIMD3<Float>; var direction: SIMD3<Float> }
struct MeshHit { var position: SIMD3<Float>; var normal: SIMD3<Float>; var distance: Float; var triangleStart: Int }

enum MeshPicker {
    static func hit(ray: Ray, mesh: EditableMesh) -> MeshHit? {
        var nearest: MeshHit?
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])]
            let b = mesh.vertices[Int(mesh.indices[t + 1])]
            let c = mesh.vertices[Int(mesh.indices[t + 2])]
            guard let distance = triangleDistance(ray: ray, a: a.position, b: b.position, c: c.position), distance > 0,
                  distance < (nearest?.distance ?? .greatestFiniteMagnitude) else { continue }
            let p = ray.origin + ray.direction * distance
            nearest = MeshHit(position: p, normal: simd_normalize(a.normal + b.normal + c.normal), distance: distance, triangleStart: t)
        }
        return nearest
    }

    private static func triangleDistance(ray: Ray, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Float? {
        let epsilon: Float = 0.000_001
        let edge1 = b - a, edge2 = c - a
        let h = simd_cross(ray.direction, edge2)
        let determinant = simd_dot(edge1, h)
        guard abs(determinant) > epsilon else { return nil }
        let inverse = 1 / determinant
        let s = ray.origin - a
        let u = inverse * simd_dot(s, h)
        guard u >= 0 && u <= 1 else { return nil }
        let q = simd_cross(s, edge1)
        let v = inverse * simd_dot(ray.direction, q)
        guard v >= 0 && u + v <= 1 else { return nil }
        let distance = inverse * simd_dot(edge2, q)
        return distance > epsilon ? distance : nil
    }
}

