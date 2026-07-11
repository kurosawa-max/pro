import Foundation
import simd

enum BinarySTLExporter {
    static func data(for mesh: EditableMesh) throws -> Data {
        _ = try mesh.validated()
        var data = Data(count: 80)
        append(UInt32(mesh.indices.count / 3), to: &data)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])].position
            let b = mesh.vertices[Int(mesh.indices[t + 1])].position
            let c = mesh.vertices[Int(mesh.indices[t + 2])].position
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length(cross) > 0 ? simd_normalize(cross) : .zero
            for value in [normal.x, normal.y, normal.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] {
                append(value.bitPattern, to: &data)
            }
            append(UInt16(0), to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
