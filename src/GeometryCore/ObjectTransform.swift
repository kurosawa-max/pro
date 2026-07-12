import Foundation
import simd

struct ObjectTransform: Codable, Equatable {
    static let identity = ObjectTransform()
    static let minimumScaleMagnitude: Float = 0.001
    static let maximumScaleMagnitude: Float = 1_000

    var translation: SIMD3<Float> = .zero
    /// Quaternion stored as x, y, z, w for stable Codable persistence.
    var rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)

    init(translation: SIMD3<Float> = .zero,
         rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
         scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)) {
        self.translation = translation; self.rotation = rotation; self.scale = scale
        self = sanitized()
    }

    var quaternion: simd_quatf { simd_quatf(vector: rotation) }

    var modelMatrix: simd_float4x4 {
        let value = sanitized()
        var translationMatrix = matrix_identity_float4x4
        translationMatrix.columns.3 = SIMD4<Float>(value.translation, 1)
        var scaleMatrix = matrix_identity_float4x4
        scaleMatrix.columns.0.x = value.scale.x; scaleMatrix.columns.1.y = value.scale.y; scaleMatrix.columns.2.z = value.scale.z
        return translationMatrix * simd_float4x4(value.quaternion) * scaleMatrix
    }

    var inverseModelMatrix: simd_float4x4 { modelMatrix.inverse }

    var normalMatrix: simd_float3x3 {
        let model = modelMatrix
        let linear = simd_float3x3(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
                                   SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
                                   SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z))
        return linear.inverse.transpose
    }

    var isFinite: Bool {
        translation.allFinite && rotation.x.isFinite && rotation.y.isFinite && rotation.z.isFinite && rotation.w.isFinite && scale.allFinite
    }

    var isIdentity: Bool {
        let value = sanitized(), epsilon: Float = 0.000_01
        return simd_length(value.translation) <= epsilon && simd_length(value.scale - SIMD3<Float>(repeating: 1)) <= epsilon &&
            min(simd_length(value.rotation - SIMD4<Float>(0, 0, 0, 1)), simd_length(value.rotation + SIMD4<Float>(0, 0, 0, 1))) <= epsilon
    }

    func sanitized() -> ObjectTransform {
        var value = self
        if !value.translation.allFinite { value.translation = .zero }
        let rotationLength = simd_length(value.rotation)
        value.rotation = rotationLength.isFinite && rotationLength > 0.000_001
            ? value.rotation / rotationLength : SIMD4<Float>(0, 0, 0, 1)
        for axis in 0..<3 {
            let component = value.scale[axis]
            if !component.isFinite { value.scale[axis] = 1; continue }
            let sign: Float = component < 0 ? -1 : 1
            value.scale[axis] = sign * min(max(abs(component), Self.minimumScaleMagnitude), Self.maximumScaleMagnitude)
        }
        return value
    }

    mutating func reset() { self = .identity }

    static func rotation(degrees: SIMD3<Float>) -> SIMD4<Float> {
        guard degrees.allFinite else { return SIMD4<Float>(0, 0, 0, 1) }
        let radians = degrees * (.pi / 180)
        let x = simd_quatf(angle: radians.x, axis: SIMD3<Float>(1, 0, 0))
        let y = simd_quatf(angle: radians.y, axis: SIMD3<Float>(0, 1, 0))
        let z = simd_quatf(angle: radians.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(z * y * x).vector
    }

    var rotationDegrees: SIMD3<Float> {
        let matrix = simd_float3x3(quaternion)
        let sy = min(max(-matrix.columns.0.z, -1), 1)
        let y = asin(sy)
        let x = atan2(matrix.columns.1.z, matrix.columns.2.z)
        let z = atan2(matrix.columns.0.y, matrix.columns.0.x)
        return SIMD3<Float>(x, y, z) * (180 / .pi)
    }

    func localPosition(fromWorld point: SIMD3<Float>) -> SIMD3<Float> { transformPosition(point, matrix: inverseModelMatrix) }
    func worldPosition(fromLocal point: SIMD3<Float>) -> SIMD3<Float> { transformPosition(point, matrix: modelMatrix) }
    func localDirection(fromWorld direction: SIMD3<Float>) -> SIMD3<Float> { normalizedDirection(direction, matrix: inverseModelMatrix) }
    func worldDirection(fromLocal direction: SIMD3<Float>) -> SIMD3<Float> { normalizedDirection(direction, matrix: modelMatrix) }

    func worldNormal(fromLocal normal: SIMD3<Float>) -> SIMD3<Float> {
        normalized(normalMatrix * normal)
    }

    func localNormal(fromWorld normal: SIMD3<Float>) -> SIMD3<Float> {
        normalized(normalMatrix.inverse * normal)
    }

    func localRay(fromWorld ray: Ray) -> Ray? {
        let origin = localPosition(fromWorld: ray.origin), direction = localDirection(fromWorld: ray.direction)
        guard origin.allFinite, direction.allFinite, simd_length_squared(direction) > 0 else { return nil }
        return Ray(origin: origin, direction: direction)
    }

    private func transformPosition(_ point: SIMD3<Float>, matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(point, 1)
        guard transformed.w.isFinite, abs(transformed.w) > 0.000_001 else { return .zero }
        return SIMD3(transformed.x, transformed.y, transformed.z) / transformed.w
    }

    private func normalizedDirection(_ direction: SIMD3<Float>, matrix: simd_float4x4) -> SIMD3<Float> {
        let value = matrix * SIMD4<Float>(direction, 0)
        return normalized(SIMD3(value.x, value.y, value.z))
    }

    private func normalized(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        return length.isFinite && length > 0.000_001 ? value / length : .zero
    }
}
