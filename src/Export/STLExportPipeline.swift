import Foundation
import simd

enum STLExportOrigin: String, CaseIterable, Identifiable {
    case asDisplayed = "As Displayed"
    case centerAtOrigin = "Center at Origin"
    var id: Self { self }
}

struct STLExportOptions: Equatable {
    var unit: LengthUnit = .millimeter
    var origin: STLExportOrigin = .asDisplayed
    var includeHeaderUnitHint = true
}

struct STLExportEstimate: Equatable {
    let triangleCount: Int
    let byteCount: Int
    let dimensionsMM: SIMD3<Float>
}

struct TriangleMeshExportData {
    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    let estimate: STLExportEstimate
    let header: String
}

enum STLExportError: Error, Equatable, LocalizedError {
    case invalidMesh
    case nonFiniteTransform
    case nonFiniteGeometry
    case degenerateTriangle
    case sizeOverflow
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidMesh: "The mesh is not valid for STL export."
        case .nonFiniteTransform: "The object Transform is not finite."
        case .nonFiniteGeometry: "The transformed geometry is not finite."
        case .degenerateTriangle: "The transformed mesh contains a degenerate triangle."
        case .sizeOverflow: "The STL size calculation overflowed."
        case .fileTooLarge: "The STL would exceed the 512 MiB export limit."
        }
    }
}

enum STLExportPipeline {
    static let maximumByteCount = 512 * 1_024 * 1_024

    static func estimate(mesh: EditableMesh, transform: ObjectTransform,
                         options: STLExportOptions = STLExportOptions()) throws -> STLExportEstimate {
        try prepare(mesh: mesh, transform: transform, options: options).estimate
    }

    static func prepare(mesh: EditableMesh, transform: ObjectTransform,
                        options: STLExportOptions = STLExportOptions()) throws -> TriangleMeshExportData {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty, mesh.indices.count.isMultiple(of: 3),
              mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count }),
              mesh.vertices.allSatisfy({ $0.position.allFinite }) else { throw STLExportError.invalidMesh }
        guard transform.isFinite else { throw STLExportError.nonFiniteTransform }
        let safeTransform = transform.sanitized()
        var positions = mesh.vertices.map { safeTransform.worldPosition(fromLocal: $0.position) }
        guard positions.allSatisfy(\.allFinite) else { throw STLExportError.nonFiniteGeometry }

        var bounds = Self.bounds(for: positions)
        guard bounds.isFinite else { throw STLExportError.nonFiniteGeometry }
        if options.origin == .centerAtOrigin {
            let center = bounds.center
            for index in positions.indices { positions[index] -= center }
            bounds = Self.bounds(for: positions)
        }
        let triangles = mesh.indices.count / 3
        let byteCount = try byteCount(triangleCount: triangles)

        let scale = max(simd_length(bounds.extent), 1.0e-12)
        // Scale-aware but deliberately far below a valid triangle made from two
        // minimum-scale axes; extreme non-uniform scale must remain exportable.
        let areaEpsilon = max(scale * scale * 1.0e-15, Float.leastNonzeroMagnitude)
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = positions[Int(mesh.indices[offset])]
            let b = positions[Int(mesh.indices[offset + 1])]
            let c = positions[Int(mesh.indices[offset + 2])]
            let cross = simd_cross(b - a, c - a)
            let twiceArea = simd_length(cross)
            guard twiceArea.isFinite, twiceArea > areaEpsilon else { throw STLExportError.degenerateTriangle }
        }
        let header = options.includeHeaderUnitHint ? "Forge3D Binary STL | unit=mm" : "Forge3D Binary STL"
        return TriangleMeshExportData(positions: positions, indices: mesh.indices,
                                      estimate: STLExportEstimate(triangleCount: triangles,
                                                                  byteCount: byteCount,
                                                                  dimensionsMM: bounds.extent),
                                      header: header)
    }

    private static func bounds(for positions: [SIMD3<Float>]) -> AxisAlignedBoundingBox {
        var value = AxisAlignedBoundingBox()
        positions.forEach { value.include($0) }
        return value
    }

    static func byteCount(triangleCount: Int) throws -> Int {
        guard triangleCount >= 0, triangleCount <= Int(UInt32.max) else { throw STLExportError.sizeOverflow }
        let (records, multiplyOverflow) = triangleCount.multipliedReportingOverflow(by: 50)
        let (byteCount, addOverflow) = records.addingReportingOverflow(84)
        guard !multiplyOverflow, !addOverflow else { throw STLExportError.sizeOverflow }
        guard byteCount <= maximumByteCount else { throw STLExportError.fileTooLarge }
        return byteCount
    }
}
