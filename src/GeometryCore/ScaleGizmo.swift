import Foundation
import simd

enum ScaleGizmoHandle: Int32, CaseIterable, Equatable {
    case xAxis = 0, yAxis, zAxis, uniform

    var axis: SIMD3<Float>? {
        switch self {
        case .xAxis: return SIMD3<Float>(1, 0, 0)
        case .yAxis: return SIMD3<Float>(0, 1, 0)
        case .zAxis: return SIMD3<Float>(0, 0, 1)
        case .uniform: return nil
        }
    }
}

struct ScaleGizmoHit: Equatable {
    var handle: ScaleGizmoHandle
    var distance: Float
}

struct ScaleDragSession {
    var handle: ScaleGizmoHandle
    var startTransform: ObjectTransform
    var startRay: Ray
    var startScale: SIMD3<Float>
    var origin: SIMD3<Float>
    var axis: SIMD3<Float>?
    var startCameraDirection: SIMD3<Float>
    var cameraPlaneNormal: SIMD3<Float>?
    var uniformDirection: SIMD3<Float>?
    var startConstraintPoint: SIMD3<Float>
    var referenceLength: Float
    var lastValidScale: SIMD3<Float>
}

struct ScaleGizmoState {
    var hoverHandle: ScaleGizmoHandle?
    var activeHandle: ScaleGizmoHandle?
    var dragSession: ScaleDragSession?
    var isDragging: Bool { dragSession != nil }
}

enum ScaleGizmoGeometry {
    static let axisLength: Float = 1
    static let axisHitMaximum: Float = 1.08
    static let axisMinimum: Float = 0.18
    static let axisTolerance: Float = 0.10
    static let uniformHandleRadius: Float = 0.14
    private static let epsilon: Float = 0.000_01

    static func hit(ray: Ray, origin: SIMD3<Float>, scale: Float) -> ScaleGizmoHit? {
        guard ray.origin.allFinite, ray.direction.allFinite, origin.allFinite,
              simd_length_squared(ray.direction) > epsilon,
              scale.isFinite, scale > 0 else { return nil }

        // The center handle wins intentional overlaps so uniform scaling remains easy to acquire.
        if let distance = raySphereDistance(ray: ray, center: origin,
                                            radius: uniformHandleRadius * scale) {
            return ScaleGizmoHit(handle: .uniform, distance: distance)
        }

        var hits: [ScaleGizmoHit] = []
        for handle in [ScaleGizmoHandle.xAxis, .yAxis, .zAxis] {
            guard let axis = handle.axis,
                  let closest = TranslationGizmoGeometry.closestRayAndLine(
                    ray: ray, lineOrigin: origin, lineDirection: axis),
                  closest.rayParameter >= 0,
                  closest.lineParameter >= axisMinimum * scale,
                  closest.lineParameter <= axisHitMaximum * scale,
                  closest.distance <= axisTolerance * scale else { continue }
            hits.append(ScaleGizmoHit(handle: handle, distance: closest.rayParameter))
        }
        return hits.min {
            if abs($0.distance - $1.distance) > epsilon { return $0.distance < $1.distance }
            return $0.handle.rawValue < $1.handle.rawValue
        }
    }

    static func beginSession(handle: ScaleGizmoHandle, ray: Ray,
                             transform: ObjectTransform, cameraDirection: SIMD3<Float>,
                             referenceLength: Float) -> ScaleDragSession? {
        guard ray.origin.allFinite, ray.direction.allFinite,
              simd_length_squared(ray.direction) > epsilon,
              referenceLength.isFinite, referenceLength > epsilon else { return nil }
        let origin = transform.translation
        if let axis = handle.axis {
            guard let point = TranslationGizmoGeometry.axisConstraintPoint(
                ray: ray, origin: origin, axis: axis, cameraDirection: cameraDirection) else { return nil }
            return ScaleDragSession(handle: handle, startTransform: transform,
                                    startRay: ray, startScale: transform.scale, origin: origin,
                                    axis: axis, startCameraDirection: cameraDirection,
                                    cameraPlaneNormal: nil, uniformDirection: nil,
                                    startConstraintPoint: point, referenceLength: referenceLength,
                                    lastValidScale: transform.scale)
        }

        guard let normal = normalized(cameraDirection),
              let direction = uniformDragDirection(cameraDirection: normal),
              let intersection = intersect(ray: ray, planePoint: origin, planeNormal: normal) else { return nil }
        return ScaleDragSession(handle: handle, startTransform: transform,
                                startRay: ray, startScale: transform.scale, origin: origin,
                                axis: nil, startCameraDirection: normal,
                                cameraPlaneNormal: normal, uniformDirection: direction,
                                startConstraintPoint: intersection.point, referenceLength: referenceLength,
                                lastValidScale: transform.scale)
    }

    static func scale(session: ScaleDragSession, ray: Ray,
                      cameraDirection: SIMD3<Float>) -> SIMD3<Float>? {
        guard ray.origin.allFinite, ray.direction.allFinite,
              simd_length_squared(ray.direction) > epsilon else { return nil }
        let signedDistance: Float
        if let axis = session.axis {
            let constraintCameraDirection = simd_length_squared(session.startCameraDirection) > epsilon
                ? session.startCameraDirection : cameraDirection
            guard let point = TranslationGizmoGeometry.axisConstraintPoint(
                ray: ray, origin: session.origin, axis: axis,
                cameraDirection: constraintCameraDirection) else { return nil }
            signedDistance = simd_dot(point - session.startConstraintPoint, axis)
        } else {
            guard let normal = session.cameraPlaneNormal,
                  let direction = session.uniformDirection,
                  let intersection = intersect(ray: ray, planePoint: session.origin,
                                               planeNormal: normal) else { return nil }
            signedDistance = simd_dot(intersection.point - session.startConstraintPoint, direction)
        }
        guard signedDistance.isFinite else { return nil }
        let normalizedDistance = signedDistance / session.referenceLength
        let factor = normalizedDistance.isFinite
            ? 1 + normalizedDistance
            : (signedDistance >= 0 ? Float.greatestFiniteMagnitude : -Float.greatestFiniteMagnitude)
        return applyFactor(startScale: session.startScale,
                           handle: session.handle, factor: factor)
    }

    static func applyFactor(startScale: SIMD3<Float>, handle: ScaleGizmoHandle,
                            factor: Float) -> SIMD3<Float>? {
        guard startScale.allFinite, factor.isFinite else { return nil }
        let safeStart = ObjectTransform.sanitizedScale(startScale)
        var result = safeStart
        if let axis = handle.axis {
            let component = axis.x != 0 ? 0 : (axis.y != 0 ? 1 : 2)
            let minimumFactor = ObjectTransform.minimumScaleMagnitude / safeStart[component]
            let maximumFactor = ObjectTransform.maximumScaleMagnitude / safeStart[component]
            result[component] = safeStart[component] * min(max(factor, minimumFactor), maximumFactor)
        } else {
            let minimumFactor = max(ObjectTransform.minimumScaleMagnitude / safeStart.x,
                                    ObjectTransform.minimumScaleMagnitude / safeStart.y,
                                    ObjectTransform.minimumScaleMagnitude / safeStart.z)
            let maximumFactor = min(ObjectTransform.maximumScaleMagnitude / safeStart.x,
                                    ObjectTransform.maximumScaleMagnitude / safeStart.y,
                                    ObjectTransform.maximumScaleMagnitude / safeStart.z)
            result = safeStart * min(max(factor, minimumFactor), maximumFactor)
        }
        return result.allFinite ? result : nil
    }

    static func uniformDragDirection(cameraDirection: SIMD3<Float>) -> SIMD3<Float>? {
        guard let view = normalized(cameraDirection) else { return nil }
        var right = simd_cross(SIMD3<Float>(0, 1, 0), view)
        if simd_length_squared(right) < epsilon {
            right = simd_cross(SIMD3<Float>(1, 0, 0), view)
        }
        guard let normalizedRight = normalized(right),
              let up = normalized(simd_cross(view, normalizedRight)) else { return nil }
        return normalized(normalizedRight + up)
    }

    private static func raySphereDistance(ray: Ray, center: SIMD3<Float>,
                                          radius: Float) -> Float? {
        guard let direction = normalized(ray.direction), radius.isFinite, radius > 0 else { return nil }
        let offset = ray.origin - center
        let b = simd_dot(offset, direction)
        let c = simd_dot(offset, offset) - radius * radius
        let discriminant = b * b - c
        guard discriminant.isFinite, discriminant >= 0 else { return nil }
        let root = sqrt(discriminant)
        let near = -b - root
        let far = -b + root
        if near >= 0 { return near }
        return far >= 0 ? far : nil
    }

    private static func intersect(ray: Ray, planePoint: SIMD3<Float>,
                                  planeNormal: SIMD3<Float>)
        -> (point: SIMD3<Float>, distance: Float)? {
        guard ray.origin.allFinite, ray.direction.allFinite,
              planePoint.allFinite, planeNormal.allFinite else { return nil }
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
