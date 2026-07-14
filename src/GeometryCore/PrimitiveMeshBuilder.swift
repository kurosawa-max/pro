import Foundation
import simd

enum PrimitiveKind: String, Codable, CaseIterable, Identifiable {
    case sphere
    case cube
    case cylinder

    var id: Self { self }
    var displayName: String {
        switch self {
        case .sphere: return "UV Sphere"
        case .cube: return "Cube"
        case .cylinder: return "Cylinder"
        }
    }
}

struct PrimitiveParameters: Equatable {
    var kind: PrimitiveKind = .sphere
    var size: Float = 1
    var sphereRadius: Float = 0.5
    var sphereSegments = 32
    var sphereRings = 16
    var cylinderRadialSegments = 32
    var cylinderHeightSegments = 1
    var cylinderRadius: Float = 0.5
    var cylinderHeight: Float = 1

    var isValid: Bool { (try? PrimitiveMeshBuilder.validate(self)) != nil }
}

enum PrimitiveMeshError: Error, Equatable {
    case nonFiniteValue
    case dimensionOutOfRange
    case segmentCountOutOfRange
    case invalidMesh
}

enum PrimitiveMeshBuilder {
    static let dimensionRange: ClosedRange<Float> = 0.001...1_000
    static let sphereSegmentRange = 3...256
    static let sphereRingRange = 2...256
    static let cylinderRadialSegmentRange = 3...256
    static let cylinderHeightSegmentRange = 1...256

    static func build(_ parameters: PrimitiveParameters) throws -> EditableMesh {
        try validate(parameters)
        switch parameters.kind {
        case .sphere:
            return try sphere(radius: parameters.sphereRadius,
                              longitudeSegments: parameters.sphereSegments,
                              latitudeRings: parameters.sphereRings)
        case .cube:
            return try cube(size: parameters.size)
        case .cylinder:
            return try cylinder(radius: parameters.cylinderRadius,
                                height: parameters.cylinderHeight,
                                radialSegments: parameters.cylinderRadialSegments,
                                heightSegments: parameters.cylinderHeightSegments)
        }
    }

    static func validate(_ parameters: PrimitiveParameters) throws {
        switch parameters.kind {
        case .sphere:
            try validateDimension(parameters.sphereRadius)
            guard sphereSegmentRange.contains(parameters.sphereSegments),
                  sphereRingRange.contains(parameters.sphereRings) else { throw PrimitiveMeshError.segmentCountOutOfRange }
        case .cube:
            try validateDimension(parameters.size)
        case .cylinder:
            try validateDimension(parameters.cylinderRadius); try validateDimension(parameters.cylinderHeight)
            guard cylinderRadialSegmentRange.contains(parameters.cylinderRadialSegments),
                  cylinderHeightSegmentRange.contains(parameters.cylinderHeightSegments) else {
                throw PrimitiveMeshError.segmentCountOutOfRange
            }
        }
    }

    static func sphere(radius: Float, longitudeSegments: Int, latitudeRings: Int) throws -> EditableMesh {
        var parameters = PrimitiveParameters(kind: .sphere)
        parameters.sphereRadius = radius; parameters.sphereSegments = longitudeSegments; parameters.sphereRings = latitudeRings
        try validate(parameters)
        var positions: [SIMD3<Float>] = [SIMD3<Float>(0, radius, 0)]
        positions.reserveCapacity(2 + longitudeSegments * (latitudeRings - 1))
        for ring in 1..<latitudeRings {
            let theta = Float(ring) * .pi / Float(latitudeRings)
            let y = cos(theta) * radius, ringRadius = sin(theta) * radius
            for segment in 0..<longitudeSegments {
                let phi = Float(segment) * 2 * .pi / Float(longitudeSegments)
                positions.append(SIMD3<Float>(cos(phi) * ringRadius, y, sin(phi) * ringRadius))
            }
        }
        let south = UInt32(positions.count); positions.append(SIMD3<Float>(0, -radius, 0))
        var indices: [UInt32] = []
        indices.reserveCapacity(6 * longitudeSegments * (latitudeRings - 1))
        for segment in 0..<longitudeSegments {
            let current = UInt32(1 + segment), next = UInt32(1 + (segment + 1) % longitudeSegments)
            indices.append(contentsOf: [0, next, current])
        }
        if latitudeRings > 2 {
            for ring in 0..<(latitudeRings - 2) {
                let upper = 1 + ring * longitudeSegments, lower = upper + longitudeSegments
                for segment in 0..<longitudeSegments {
                    let next = (segment + 1) % longitudeSegments
                    let a = UInt32(upper + segment), b = UInt32(upper + next)
                    let c = UInt32(lower + segment), d = UInt32(lower + next)
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        let lastRing = 1 + (latitudeRings - 2) * longitudeSegments
        for segment in 0..<longitudeSegments {
            let current = UInt32(lastRing + segment), next = UInt32(lastRing + (segment + 1) % longitudeSegments)
            indices.append(contentsOf: [current, next, south])
        }
        return try finish(positions: positions, indices: indices, sphereNormals: true)
    }

    static func cube(size: Float) throws -> EditableMesh {
        try validateDimension(size)
        let h = size * 0.5
        let positions = [
            SIMD3<Float>(-h, -h, -h), SIMD3<Float>(h, -h, -h), SIMD3<Float>(h, h, -h), SIMD3<Float>(-h, h, -h),
            SIMD3<Float>(-h, -h, h), SIMD3<Float>(h, -h, h), SIMD3<Float>(h, h, h), SIMD3<Float>(-h, h, h),
        ]
        let indices: [UInt32] = [
            0, 3, 2, 0, 2, 1, 4, 5, 6, 4, 6, 7,
            0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
            0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2,
        ]
        return try finish(positions: positions, indices: indices)
    }

    static func cylinder(radius: Float, height: Float, radialSegments: Int,
                         heightSegments: Int) throws -> EditableMesh {
        var parameters = PrimitiveParameters(kind: .cylinder)
        parameters.cylinderRadius = radius; parameters.cylinderHeight = height
        parameters.cylinderRadialSegments = radialSegments; parameters.cylinderHeightSegments = heightSegments
        try validate(parameters)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((heightSegments + 1) * radialSegments + 2)
        for level in 0...heightSegments {
            let y = -height * 0.5 + height * Float(level) / Float(heightSegments)
            for segment in 0..<radialSegments {
                let phi = Float(segment) * 2 * .pi / Float(radialSegments)
                positions.append(SIMD3<Float>(cos(phi) * radius, y, sin(phi) * radius))
            }
        }
        let bottomCenter = UInt32(positions.count); positions.append(SIMD3<Float>(0, -height * 0.5, 0))
        let topCenter = UInt32(positions.count); positions.append(SIMD3<Float>(0, height * 0.5, 0))
        var indices: [UInt32] = []
        indices.reserveCapacity(radialSegments * heightSegments * 6 + radialSegments * 6)
        for level in 0..<heightSegments {
            let lower = level * radialSegments, upper = (level + 1) * radialSegments
            for segment in 0..<radialSegments {
                let next = (segment + 1) % radialSegments
                let a = UInt32(lower + segment), b = UInt32(upper + segment)
                let c = UInt32(lower + next), d = UInt32(upper + next)
                indices.append(contentsOf: [a, b, c, c, b, d])
            }
        }
        let topRing = heightSegments * radialSegments
        for segment in 0..<radialSegments {
            let next = (segment + 1) % radialSegments
            indices.append(contentsOf: [bottomCenter, UInt32(segment), UInt32(next)])
            indices.append(contentsOf: [topCenter, UInt32(topRing + next), UInt32(topRing + segment)])
        }
        return try finish(positions: positions, indices: indices)
    }

    private static func validateDimension(_ value: Float) throws {
        guard value.isFinite else { throw PrimitiveMeshError.nonFiniteValue }
        guard dimensionRange.contains(value) else { throw PrimitiveMeshError.dimensionOutOfRange }
    }

    private static func finish(positions: [SIMD3<Float>], indices: [UInt32],
                               sphereNormals: Bool = false) throws -> EditableMesh {
        var mesh = EditableMesh(vertices: positions.map {
            let normal = sphereNormals ? $0 / simd_length($0) : SIMD3<Float>(0, 1, 0)
            return MeshVertex(position: $0, normal: normal)
        }, indices: indices)
        if !sphereNormals { mesh.recalculateNormals(recordChange: false) }
        _ = mesh.adjacency()
        do { return try mesh.validated() } catch { throw PrimitiveMeshError.invalidMesh }
    }
}
