import Foundation
import simd

enum LengthUnit: String, Codable, Equatable {
    case millimeter

    var symbol: String { "mm" }
}

enum LengthFormatter {
    static func string(_ millimeters: Float, fractionDigits: Int = 2) -> String {
        guard millimeters.isFinite else { return "—" }
        return String(format: "%.*f mm", max(fractionDigits, 0), millimeters)
    }
}

struct ObjectDimensions: Equatable {
    let localBounds: AxisAlignedBoundingBox
    let worldBounds: AxisAlignedBoundingBox

    var localSize: SIMD3<Float> { localBounds.extent }
    var worldSize: SIMD3<Float> { worldBounds.extent }

    static func make(mesh: EditableMesh, transform: ObjectTransform) -> ObjectDimensions? {
        let local = mesh.bounds
        guard local.isFinite, transform.isFinite else { return nil }
        var world = AxisAlignedBoundingBox()
        for x in [local.minimum.x, local.maximum.x] {
            for y in [local.minimum.y, local.maximum.y] {
                for z in [local.minimum.z, local.maximum.z] {
                    let point = transform.worldPosition(fromLocal: SIMD3<Float>(x, y, z))
                    guard point.allFinite else { return nil }
                    world.include(point)
                }
            }
        }
        guard world.isFinite else { return nil }
        return ObjectDimensions(localBounds: local, worldBounds: world)
    }
}
