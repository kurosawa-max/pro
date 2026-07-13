import Foundation
import simd

enum RotationGizmoHandle: Int32, CaseIterable, Equatable {
    case xAxis = 0, yAxis, zAxis

    var axis: SIMD3<Float> {
        switch self {
        case .xAxis: return SIMD3(1, 0, 0)
        case .yAxis: return SIMD3(0, 1, 0)
        case .zAxis: return SIMD3(0, 0, 1)
        }
    }
}

struct RotationGizmoHit: Equatable {
    var handle: RotationGizmoHandle
    var distance: Float
    var radialError: Float
}

struct RotationDragSession {
    var handle: RotationGizmoHandle
    var startTransform: ObjectTransform
    var origin: SIMD3<Float>
    var axis: SIMD3<Float>
    var startIntersection: SIMD3<Float>
    var startVector: SIMD3<Float>
    var lastRawAngle: Float
    var accumulatedAngle: Float
}

struct RotationGizmoState {
    var hoverHandle: RotationGizmoHandle?
    var activeHandle: RotationGizmoHandle?
    var dragSession: RotationDragSession?
    var isDragging: Bool { dragSession != nil }
}

enum RotationGizmoGeometry {
    static let ringRadius: Float = 0.82
    static let ringTolerance: Float = 0.10
    private static let epsilon: Float = 0.000_01

    static func hit(ray: Ray, origin: SIMD3<Float>, scale: Float) -> RotationGizmoHit? {
        guard ray.origin.allFinite, ray.direction.allFinite, origin.allFinite,
              scale.isFinite, scale > 0 else { return nil }
        let radius = ringRadius * scale, tolerance = ringTolerance * scale
        var hits: [RotationGizmoHit] = []
        for handle in RotationGizmoHandle.allCases {
            guard let intersection = intersect(ray: ray, planePoint: origin, planeNormal: handle.axis) else { continue }
            let radialDistance = simd_length(intersection.point - origin)
            let error = abs(radialDistance - radius)
            guard radialDistance.isFinite, error <= tolerance else { continue }
            hits.append(RotationGizmoHit(handle: handle, distance: intersection.distance, radialError: error))
        }
        return hits.min {
            if abs($0.radialError - $1.radialError) > epsilon { return $0.radialError < $1.radialError }
            if abs($0.distance - $1.distance) > epsilon { return $0.distance < $1.distance }
            return $0.handle.rawValue < $1.handle.rawValue
        }
    }

    static func beginSession(handle: RotationGizmoHandle, ray: Ray,
                             transform: ObjectTransform) -> RotationDragSession? {
        let origin = transform.translation, axis = handle.axis
        guard let intersection = intersect(ray: ray, planePoint: origin, planeNormal: axis),
              let vector = normalized(intersection.point - origin) else { return nil }
        return RotationDragSession(handle: handle, startTransform: transform, origin: origin, axis: axis,
                                   startIntersection: intersection.point, startVector: vector,
                                   lastRawAngle: 0, accumulatedAngle: 0)
    }

    static func rotation(session: RotationDragSession, ray: Ray)
        -> (rotation: SIMD4<Float>, rawAngle: Float, accumulatedAngle: Float)? {
        guard let intersection = intersect(ray: ray, planePoint: session.origin, planeNormal: session.axis),
              let current = normalized(intersection.point - session.origin),
              let rawAngle = signedAngle(from: session.startVector, to: current, axis: session.axis),
              let unwrapped = unwrap(rawAngle: rawAngle, lastRawAngle: session.lastRawAngle,
                                     accumulatedAngle: session.accumulatedAngle),
              let composed = worldRotation(startTransform: session.startTransform, axis: session.axis,
                                           accumulatedAngle: unwrapped.accumulatedAngle) else { return nil }
        return (composed, unwrapped.rawAngle, unwrapped.accumulatedAngle)
    }

    static func unwrap(rawAngle: Float, lastRawAngle: Float, accumulatedAngle: Float)
        -> (rawAngle: Float, accumulatedAngle: Float)? {
        guard rawAngle.isFinite, lastRawAngle.isFinite, accumulatedAngle.isFinite else { return nil }
        var delta = rawAngle - lastRawAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let accumulated = accumulatedAngle + delta
        guard delta.isFinite, accumulated.isFinite else { return nil }
        return (rawAngle, accumulated)
    }

    static func worldRotation(startTransform: ObjectTransform, axis: SIMD3<Float>,
                              accumulatedAngle: Float) -> SIMD4<Float>? {
        guard accumulatedAngle.isFinite, let normalizedAxis = normalized(axis) else { return nil }
        let delta = simd_quatf(angle: accumulatedAngle, axis: normalizedAxis)
        let composed = simd_normalize(delta * startTransform.quaternion).vector
        guard composed.x.isFinite, composed.y.isFinite, composed.z.isFinite, composed.w.isFinite else { return nil }
        return composed
    }

    static func signedAngle(from start: SIMD3<Float>, to end: SIMD3<Float>,
                            axis: SIMD3<Float>) -> Float? {
        guard let a = normalized(start), let b = normalized(end), let n = normalized(axis) else { return nil }
        let cosine = min(max(simd_dot(a, b), -1), 1)
        let sine = simd_dot(n, simd_cross(a, b))
        let angle = atan2(sine, cosine)
        return angle.isFinite ? angle : nil
    }

    private static func intersect(ray: Ray, planePoint: SIMD3<Float>, planeNormal: SIMD3<Float>)
        -> (point: SIMD3<Float>, distance: Float)? {
        guard ray.origin.allFinite, ray.direction.allFinite, planePoint.allFinite, planeNormal.allFinite else { return nil }
        let denominator = simd_dot(ray.direction, planeNormal)
        guard denominator.isFinite, abs(denominator) > epsilon else { return nil }
        let distance = simd_dot(planePoint - ray.origin, planeNormal) / denominator
        guard distance.isFinite, distance >= 0 else { return nil }
        let point = ray.origin + ray.direction * distance
        return point.allFinite ? (point, distance) : nil
    }

    private static func normalized(_ value: SIMD3<Float>) -> SIMD3<Float>? {
        let length = simd_length(value)
        guard length.isFinite, length > epsilon else { return nil }
        let result = value / length
        return result.allFinite ? result : nil
    }
}
