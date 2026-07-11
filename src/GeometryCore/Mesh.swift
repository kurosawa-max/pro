import Foundation
import simd

struct MeshVertex: Codable, Equatable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct EditableMesh: Codable, Equatable {
    var vertices: [MeshVertex]
    var indices: [UInt32]

    static func uvSphere(latitudeSegments: Int = 32, longitudeSegments: Int = 48) -> EditableMesh {
        precondition(latitudeSegments >= 2 && longitudeSegments >= 3)
        var vertices: [MeshVertex] = []
        for latitude in 0...latitudeSegments {
            let v = Float(latitude) / Float(latitudeSegments)
            let phi = Float.pi * v
            for longitude in 0...longitudeSegments {
                let u = Float(longitude) / Float(longitudeSegments)
                let theta = 2 * Float.pi * u
                let p = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                vertices.append(MeshVertex(position: p, normal: p))
            }
        }

        var indices: [UInt32] = []
        let stride = longitudeSegments + 1
        for latitude in 0..<latitudeSegments {
            for longitude in 0..<longitudeSegments {
                let a = UInt32(latitude * stride + longitude)
                let b = a + UInt32(stride)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        var mesh = EditableMesh(vertices: vertices, indices: indices)
        mesh.recalculateNormals()
        return mesh
    }

    mutating func recalculateNormals() {
        guard indices.count.isMultiple(of: 3) else { return }
        for i in vertices.indices { vertices[i].normal = .zero }
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[triangle]), ib = Int(indices[triangle + 1]), ic = Int(indices[triangle + 2])
            guard vertices.indices.contains(ia), vertices.indices.contains(ib), vertices.indices.contains(ic) else { continue }
            let n = simd_cross(vertices[ib].position - vertices[ia].position,
                               vertices[ic].position - vertices[ia].position)
            vertices[ia].normal += n; vertices[ib].normal += n; vertices[ic].normal += n
        }
        for i in vertices.indices {
            let length = simd_length(vertices[i].normal)
            vertices[i].normal = length > 0.000_001 ? vertices[i].normal / length : SIMD3<Float>(0, 1, 0)
        }
    }

    func validated(maxVertices: Int = 2_000_000, maxIndices: Int = 12_000_000) throws -> EditableMesh {
        guard !vertices.isEmpty, vertices.count <= maxVertices, indices.count <= maxIndices,
              indices.count.isMultiple(of: 3) else { throw MeshError.invalidStructure }
        guard indices.allSatisfy({ Int($0) < vertices.count }) else { throw MeshError.indexOutOfRange }
        guard vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else { throw MeshError.nonFiniteValue }
        return self
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

enum MeshError: Error { case invalidStructure, indexOutOfRange, nonFiniteValue }

