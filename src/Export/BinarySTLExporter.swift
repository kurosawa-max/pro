import Foundation
import simd

enum BinarySTLExporter {
    static func data(for mesh: EditableMesh) throws -> Data {
        try data(for: mesh, transform: .identity)
    }

    static func data(for mesh: EditableMesh, transform: ObjectTransform,
                     options: STLExportOptions = STLExportOptions()) throws -> Data {
        try data(for: STLExportPipeline.prepare(mesh: mesh, transform: transform, options: options))
    }

    static func data(for exportMesh: TriangleMeshExportData) throws -> Data {
        var data = Data(capacity: exportMesh.estimate.byteCount)
        var header = Data(exportMesh.header.utf8.prefix(80))
        if header.count < 80 { header.append(Data(count: 80 - header.count)) }
        data.append(header)
        append(UInt32(exportMesh.estimate.triangleCount), to: &data)
        for t in stride(from: 0, to: exportMesh.indices.count, by: 3) {
            let a = exportMesh.positions[Int(exportMesh.indices[t])]
            let b = exportMesh.positions[Int(exportMesh.indices[t + 1])]
            let c = exportMesh.positions[Int(exportMesh.indices[t + 2])]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length.isFinite, length > 0 else { throw STLExportError.degenerateTriangle }
            let normal = cross / length
            for value in [normal.x, normal.y, normal.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] {
                append(value.bitPattern, to: &data)
            }
            append(UInt16(0), to: &data)
        }
        guard data.count == exportMesh.estimate.byteCount else { throw STLExportError.sizeOverflow }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
