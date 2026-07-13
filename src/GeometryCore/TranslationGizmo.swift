import Foundation
import simd

enum GizmoMode: Equatable { case translate }

enum TranslationGizmoHandle: Int32, CaseIterable, Equatable {
    case xAxis = 0, yAxis, zAxis, xyPlane, yzPlane, zxPlane

    var axis: SIMD3<Float>? {
        switch self {
        case .xAxis: return SIMD3(1, 0, 0)
        case .yAxis: return SIMD3(0, 1, 0)
        case .zAxis: return SIMD3(0, 0, 1)
        default: return nil
        }
    }

    var planeNormal: SIMD3<Float>? {
        switch self {
        case .xyPlane: return SIMD3(0, 0, 1)
        case .yzPlane: return SIMD3(1, 0, 0)
        case .zxPlane: return SIMD3(0, 1, 0)
        default: return nil
        }
    }
}

struct TranslationGizmoHit: Equatable {
    var handle: TranslationGizmoHandle
    var distance: Float
}

struct TranslationDragSession {
    var handle: TranslationGizmoHandle
    var startTransform: ObjectTransform
    var origin: SIMD3<Float>
    var startRay: Ray
    var startConstraintPoint: SIMD3<Float>
    var axis: SIMD3<Float>?
    var planeNormal: SIMD3<Float>?
}

struct TranslationGizmoState {
    var mode: GizmoMode = .translate
    var hoverHandle: TranslationGizmoHandle?
    var activeHandle: TranslationGizmoHandle?
    var dragSession: TranslationDragSession?
    var isDragging: Bool { dragSession != nil }
}

enum TranslationGizmoGeometry {
    static let axisLength: Float = 1
    static let planeMinimum: Float = 0.18
    static let planeMaximum: Float = 0.42
    static let axisTolerance: Float = 0.09
    static let maximumDragDelta: Float = 10_000
    private static let epsilon: Float = 0.000_01

    static func worldScale(cameraDistance: Float, viewportHeight: Float, fovYRadians: Float,
                           desiredPixels: Float = 112, minimum: Float = 0.05, maximum: Float = 100) -> Float {
        guard cameraDistance.isFinite, viewportHeight.isFinite, fovYRadians.isFinite,
              viewportHeight > 0, fovYRadians > 0, desiredPixels > 0 else { return minimum }
        let visibleHeight = 2 * max(cameraDistance, 0) * tan(fovYRadians * 0.5)
        let scale = visibleHeight * desiredPixels / viewportHeight
        if scale == .infinity { return maximum }
        return min(max(scale.isFinite ? scale : minimum, minimum), maximum)
    }

    static func hit(ray: Ray, origin: SIMD3<Float>, scale: Float) -> TranslationGizmoHit? {
        guard ray.origin.allFinite, ray.direction.allFinite, origin.allFinite, scale.isFinite, scale > 0 else { return nil }
        var candidates: [TranslationGizmoHit] = []
        for handle in [TranslationGizmoHandle.xAxis, .yAxis, .zAxis] {
            guard let axis = handle.axis,
                  let closest = closestRayAndLine(ray: ray, lineOrigin: origin, lineDirection: axis),
                  closest.lineParameter >= 0, closest.lineParameter <= axisLength * scale,
                  closest.distance <= axisTolerance * scale, closest.rayParameter >= 0 else { continue }
            candidates.append(TranslationGizmoHit(handle: handle, distance: closest.rayParameter))
        }
        // Axis handles intentionally win overlaps because they are narrower and otherwise hard to acquire.
        if let axisHit = candidates.min(by: { $0.distance < $1.distance }) { return axisHit }
        for handle in [TranslationGizmoHandle.xyPlane, .yzPlane, .zxPlane] {
            guard let normal = handle.planeNormal,
                  let intersection = intersect(ray: ray, planePoint: origin, planeNormal: normal) else { continue }
            let local = (intersection.point - origin) / scale
            let coordinates: SIMD2<Float>
            switch handle {
            case .xyPlane: coordinates = SIMD2(local.x, local.y)
            case .yzPlane: coordinates = SIMD2(local.y, local.z)
            case .zxPlane: coordinates = SIMD2(local.z, local.x)
            default: continue
            }
            guard coordinates.x >= planeMinimum, coordinates.y >= planeMinimum,
                  coordinates.x <= planeMaximum, coordinates.y <= planeMaximum else { continue }
            candidates.append(TranslationGizmoHit(handle: handle, distance: intersection.distance))
        }
        return candidates.min(by: { $0.distance < $1.distance })
    }

    static func beginSession(handle: TranslationGizmoHandle, ray: Ray, transform: ObjectTransform,
                             cameraDirection: SIMD3<Float>) -> TranslationDragSession? {
        let origin = transform.translation
        if let axis = handle.axis {
            guard let point = axisConstraintPoint(ray: ray, origin: origin, axis: axis,
                                                  cameraDirection: cameraDirection) else { return nil }
            return TranslationDragSession(handle: handle, startTransform: transform, origin: origin, startRay: ray,
                                          startConstraintPoint: point, axis: axis, planeNormal: nil)
        }
        guard let normal = handle.planeNormal,
              let intersection = intersect(ray: ray, planePoint: origin, planeNormal: normal) else { return nil }
        return TranslationDragSession(handle: handle, startTransform: transform, origin: origin, startRay: ray,
                                      startConstraintPoint: intersection.point, axis: nil, planeNormal: normal)
    }

    static func translation(session: TranslationDragSession, ray: Ray, cameraDirection: SIMD3<Float>) -> SIMD3<Float>? {
        let current: SIMD3<Float>
        if let axis = session.axis {
            guard let point = axisConstraintPoint(ray: ray, origin: session.origin, axis: axis,
                                                  cameraDirection: cameraDirection) else { return nil }
            current = point
        } else if let normal = session.planeNormal {
            guard let intersection = intersect(ray: ray, planePoint: session.origin, planeNormal: normal) else { return nil }
            current = intersection.point
        } else { return nil }
        let delta = current - session.startConstraintPoint
        guard delta.allFinite, simd_length(delta) <= maximumDragDelta else { return nil }
        let value = session.startTransform.translation + delta
        return value.allFinite ? value : nil
    }

    static func axisConstraintPoint(ray: Ray, origin: SIMD3<Float>, axis: SIMD3<Float>,
                                    cameraDirection: SIMD3<Float>) -> SIMD3<Float>? {
        if let closest = closestRayAndLine(ray: ray, lineOrigin: origin, lineDirection: axis),
           abs(simd_dot(ray.direction, axis)) < 0.985 {
            let point = origin + axis * closest.lineParameter
            return point.allFinite ? point : nil
        }
        guard let normal = fallbackPlaneNormal(axis: axis, cameraDirection: cameraDirection),
              let intersection = intersect(ray: ray, planePoint: origin, planeNormal: normal) else { return nil }
        let point = origin + axis * simd_dot(intersection.point - origin, axis)
        return point.allFinite ? point : nil
    }

    static func fallbackPlaneNormal(axis: SIMD3<Float>, cameraDirection: SIMD3<Float>) -> SIMD3<Float>? {
        let normalizedAxis = safeNormalize(axis), view = safeNormalize(cameraDirection)
        guard simd_length_squared(normalizedAxis) > 0, simd_length_squared(view) > 0 else { return nil }
        var side = simd_cross(normalizedAxis, view)
        if simd_length_squared(side) < epsilon { side = simd_cross(normalizedAxis, SIMD3(0, 1, 0)) }
        if simd_length_squared(side) < epsilon { side = simd_cross(normalizedAxis, SIMD3(1, 0, 0)) }
        let normal = safeNormalize(simd_cross(side, normalizedAxis))
        return simd_length_squared(normal) > 0 ? normal : nil
    }

    static func closestRayAndLine(ray: Ray, lineOrigin: SIMD3<Float>, lineDirection: SIMD3<Float>)
        -> (rayParameter: Float, lineParameter: Float, distance: Float)? {
        let u = safeNormalize(ray.direction), v = safeNormalize(lineDirection), w = ray.origin - lineOrigin
        let b = simd_dot(u, v), d = simd_dot(u, w), e = simd_dot(v, w)
        let denominator = 1 - b * b
        guard abs(denominator) > epsilon else { return nil }
        let rayParameter = (b * e - d) / denominator
        let lineParameter = (e - b * d) / denominator
        let delta = (ray.origin + u * rayParameter) - (lineOrigin + v * lineParameter)
        let distance = simd_length(delta)
        guard rayParameter.isFinite, lineParameter.isFinite, distance.isFinite else { return nil }
        return (rayParameter, lineParameter, distance)
    }

    private static func intersect(ray: Ray, planePoint: SIMD3<Float>, planeNormal: SIMD3<Float>)
        -> (point: SIMD3<Float>, distance: Float)? {
        let denominator = simd_dot(ray.direction, planeNormal)
        guard denominator.isFinite, abs(denominator) > epsilon else { return nil }
        let distance = simd_dot(planePoint - ray.origin, planeNormal) / denominator
        guard distance.isFinite, distance >= 0 else { return nil }
        let point = ray.origin + ray.direction * distance
        return point.allFinite ? (point, distance) : nil
    }

    private static func safeNormalize(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        return length.isFinite && length > epsilon ? value / length : .zero
    }
}
