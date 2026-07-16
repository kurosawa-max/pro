import Foundation
import simd

enum STLImportFormat: String, Equatable {
    case binary = "Binary STL"
    case ascii = "ASCII STL"
}

struct STLImportEstimate: Equatable {
    let sourceByteCount: Int
    let sourceTriangleCount: Int
    let maximumPossibleVertexCount: Int
    let estimatedWorkingByteCount: Int
}

struct STLImportResult: Equatable {
    let mesh: EditableMesh
    let format: STLImportFormat
    let sourceByteCount: Int
    let sourceTriangleCount: Int
    let weldedVertexCount: Int
    let bounds: AxisAlignedBoundingBox
    let estimate: STLImportEstimate
}

enum STLImportError: Error, Equatable, LocalizedError {
    case emptyFile
    case sourceTooLarge
    case unsupportedOrMalformedFormat
    case malformedBinary
    case malformedASCII
    case triangleLimitExceeded
    case vertexLimitExceeded
    case nonFiniteValue
    case degenerateTriangle
    case duplicateTriangle
    case nonManifoldEdge
    case sizeOverflow
    case estimatedWorkingSetTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyFile: "The STL file is empty."
        case .sourceTooLarge: "The STL file exceeds the 256 MiB import limit."
        case .unsupportedOrMalformedFormat: "The file is not a supported Binary or ASCII STL."
        case .malformedBinary: "The Binary STL record layout is malformed or truncated."
        case .malformedASCII: "The ASCII STL grammar is malformed."
        case .triangleLimitExceeded: "The STL exceeds the 1,000,000 triangle import limit."
        case .vertexLimitExceeded: "The STL exceeds the 500,000 welded-vertex import limit."
        case .nonFiniteValue: "The STL contains NaN or Infinity coordinates."
        case .degenerateTriangle: "The STL contains a degenerate triangle."
        case .duplicateTriangle: "The STL contains a duplicate triangle."
        case .nonManifoldEdge: "The STL contains an edge shared by more than two triangles."
        case .sizeOverflow: "The STL size calculation overflowed."
        case .estimatedWorkingSetTooLarge: "The STL would require too much temporary memory to import safely."
        }
    }
}

enum STLImporter {
    static let maximumSourceByteCount = 256 * 1_024 * 1_024
    static let maximumTriangleCount = 1_000_000
    static let maximumWeldedVertexCount = 500_000
    static let maximumASCIILineLength = 4_096
    static let maximumEstimatedWorkingByteCount = 768 * 1_024 * 1_024

    static func importMesh(from data: Data) throws -> STLImportResult {
        try validateSourceByteCount(data.count)
        guard !data.isEmpty else { throw STLImportError.emptyFile }

        if let binaryTriangleCount = binaryTriangleCountWhenLayoutMatches(data) {
            _ = try estimate(sourceByteCount: data.count, triangleCount: binaryTriangleCount)
            let positions = try parseBinary(data, triangleCount: binaryTriangleCount)
            return try buildResult(positions: positions, format: .binary, sourceByteCount: data.count)
        }

        do {
            let conservativeASCIITriangles = min(maximumTriangleCount, max(1, data.count / 64 + 1))
            _ = try estimate(sourceByteCount: data.count, triangleCount: conservativeASCIITriangles)
            let positions = try parseASCII(data)
            return try buildResult(positions: positions, format: .ascii, sourceByteCount: data.count)
        } catch let error as STLImportError {
            if error == .malformedASCII, !looksLikeASCIISTL(data) {
                throw STLImportError.unsupportedOrMalformedFormat
            }
            throw error
        }
    }

    static func validateSourceByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0 else { throw STLImportError.sizeOverflow }
        guard byteCount <= maximumSourceByteCount else { throw STLImportError.sourceTooLarge }
    }

    static func validateWeldedVertexCount(_ vertexCount: Int) throws {
        guard vertexCount >= 0 else { throw STLImportError.sizeOverflow }
        guard vertexCount <= maximumWeldedVertexCount else { throw STLImportError.vertexLimitExceeded }
    }

    static func estimate(sourceByteCount: Int, triangleCount: Int) throws -> STLImportEstimate {
        try validateSourceByteCount(sourceByteCount)
        guard triangleCount >= 0 else { throw STLImportError.sizeOverflow }
        guard triangleCount <= maximumTriangleCount else { throw STLImportError.triangleLimitExceeded }
        let (maximumVertices, vertexOverflow) = triangleCount.multipliedReportingOverflow(by: 3)
        guard !vertexOverflow else { throw STLImportError.sizeOverflow }
        let cappedVertices = min(maximumVertices, maximumWeldedVertexCount)
        let temporaryPoints = try multiplied(maximumVertices,
            MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<UInt32>.stride)
        let parseBuffer = sourceByteCount
        let weldDictionary = try multiplied(cappedVertices, 56)
        let meshStorage = try added(
            multiplied(cappedVertices, MemoryLayout<MeshVertex>.stride),
            multiplied(maximumVertices, MemoryLayout<UInt32>.stride))
        let adjacency = try added(multiplied(cappedVertices, 24), multiplied(triangleCount, 48))
        let bvh = try multiplied(triangleCount,
            MemoryLayout<TriangleReference>.stride + 2 * MemoryLayout<BVHNode>.stride)
        let spatialIndex = try multiplied(cappedVertices, 64)
        let metalBuffers = meshStorage
        let undoSnapshot = meshStorage
        var workingBytes = sourceByteCount
        for component in [parseBuffer, temporaryPoints, weldDictionary, meshStorage, adjacency,
                          bvh, spatialIndex, metalBuffers, undoSnapshot] {
            workingBytes = try added(workingBytes, component)
        }
        guard workingBytes <= maximumEstimatedWorkingByteCount else {
            throw STLImportError.estimatedWorkingSetTooLarge
        }
        return STLImportEstimate(sourceByteCount: sourceByteCount,
                                 sourceTriangleCount: triangleCount,
                                 maximumPossibleVertexCount: maximumVertices,
                                 estimatedWorkingByteCount: workingBytes)
    }

    private static func binaryTriangleCountWhenLayoutMatches(_ data: Data) -> Int? {
        guard data.count >= 84 else { return nil }
        let count = Int(uint32(in: data, at: 80))
        guard let expected = try? binaryByteCount(triangleCount: count),
              expected == data.count else { return nil }
        return count
    }

    private static func binaryByteCount(triangleCount: Int) throws -> Int {
        guard triangleCount >= 0 else { throw STLImportError.sizeOverflow }
        let (records, multiplyOverflow) = triangleCount.multipliedReportingOverflow(by: 50)
        let (total, addOverflow) = records.addingReportingOverflow(84)
        guard !multiplyOverflow, !addOverflow else { throw STLImportError.sizeOverflow }
        return total
    }

    private static func parseBinary(_ data: Data, triangleCount: Int) throws -> [SIMD3<Float>] {
        guard triangleCount > 0 else { throw STLImportError.malformedBinary }
        guard triangleCount <= maximumTriangleCount else { throw STLImportError.triangleLimitExceeded }
        guard try binaryByteCount(triangleCount: triangleCount) == data.count else {
            throw STLImportError.malformedBinary
        }
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(triangleCount * 3)
        for triangle in 0..<triangleCount {
            let record = 84 + triangle * 50
            for vertex in 0..<3 {
                let offset = record + 12 + vertex * 12
                let point = SIMD3<Float>(float(in: data, at: offset),
                                         float(in: data, at: offset + 4),
                                         float(in: data, at: offset + 8))
                guard point.allFinite else { throw STLImportError.nonFiniteValue }
                positions.append(point)
            }
        }
        return positions
    }

    private static func parseASCII(_ data: Data) throws -> [SIMD3<Float>] {
        guard let source = String(data: data, encoding: .utf8) else { throw STLImportError.malformedASCII }
        let rawLines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard rawLines.allSatisfy({ $0.utf8.count <= maximumASCIILineLength }) else {
            throw STLImportError.malformedASCII
        }
        let lines = rawLines.map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, keyword(first) == "solid" else { throw STLImportError.malformedASCII }
        var cursor = 1
        var positions: [SIMD3<Float>] = []

        while cursor < lines.count {
            if keyword(lines[cursor]) == "endsolid" {
                cursor += 1
                guard cursor == lines.count, !positions.isEmpty else { throw STLImportError.malformedASCII }
                return positions
            }
            let facet = tokens(lines[cursor])
            guard facet.count == 5, facet[0].lowercased() == "facet", facet[1].lowercased() == "normal" else {
                throw STLImportError.malformedASCII
            }
            guard positions.count / 3 < maximumTriangleCount else { throw STLImportError.triangleLimitExceeded }
            _ = try vector(tokens: Array(facet[2...4]))
            cursor += 1
            guard cursor < lines.count, tokens(lines[cursor]).map({ $0.lowercased() }) == ["outer", "loop"] else {
                throw STLImportError.malformedASCII
            }
            cursor += 1
            for _ in 0..<3 {
                guard cursor < lines.count else { throw STLImportError.malformedASCII }
                let vertex = tokens(lines[cursor])
                guard vertex.count == 4, vertex[0].lowercased() == "vertex" else {
                    throw STLImportError.malformedASCII
                }
                positions.append(try vector(tokens: Array(vertex[1...3])))
                cursor += 1
            }
            guard cursor < lines.count, tokens(lines[cursor]).map({ $0.lowercased() }) == ["endloop"] else {
                throw STLImportError.malformedASCII
            }
            cursor += 1
            guard cursor < lines.count, tokens(lines[cursor]).map({ $0.lowercased() }) == ["endfacet"] else {
                throw STLImportError.malformedASCII
            }
            cursor += 1
        }
        throw STLImportError.malformedASCII
    }

    private static func keyword(_ line: String) -> String? { tokens(line).first?.lowercased() }

    private static func looksLikeASCIISTL(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(1_024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix == "solid" || prefix.hasPrefix("solid ") || prefix.hasPrefix("solid\t")
    }

    private static func tokens(_ line: String) -> [Substring] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    }

    private static func vector(tokens: [Substring]) throws -> SIMD3<Float> {
        guard tokens.count == 3,
              let x = Float(tokens[0]), let y = Float(tokens[1]), let z = Float(tokens[2]) else {
            throw STLImportError.malformedASCII
        }
        let value = SIMD3<Float>(x, y, z)
        guard value.allFinite else { throw STLImportError.nonFiniteValue }
        return value
    }

    private static func buildResult(positions: [SIMD3<Float>], format: STLImportFormat,
                                    sourceByteCount: Int) throws -> STLImportResult {
        guard !positions.isEmpty, positions.count.isMultiple(of: 3) else {
            throw format == .binary ? STLImportError.malformedBinary : STLImportError.malformedASCII
        }
        let triangleCount = positions.count / 3
        guard triangleCount <= maximumTriangleCount else { throw STLImportError.triangleLimitExceeded }
        let estimate = try estimate(sourceByteCount: sourceByteCount, triangleCount: triangleCount)
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(min(positions.count, maximumWeldedVertexCount))
        var indices: [UInt32] = []
        indices.reserveCapacity(positions.count)
        var positionIndices: [STLPositionKey: UInt32] = [:]
        positionIndices.reserveCapacity(min(positions.count, maximumWeldedVertexCount))

        for rawPosition in positions {
            let position = canonicalPosition(rawPosition)
            let key = STLPositionKey(position)
            if let existing = positionIndices[key] {
                indices.append(existing)
            } else {
                try validateWeldedVertexCount(vertices.count + 1)
                let index = UInt32(vertices.count)
                positionIndices[key] = index
                vertices.append(MeshVertex(position: position, normal: .zero))
                indices.append(index)
            }
        }

        var bounds = AxisAlignedBoundingBox()
        vertices.forEach { bounds.include($0.position) }
        guard bounds.isFinite else { throw STLImportError.nonFiniteValue }
        let scale = max(simd_length(bounds.extent), 1.0e-12)
        let areaEpsilon = max(scale * scale * 1.0e-12, Float.leastNonzeroMagnitude)
        var triangles = Set<STLTriangleKey>()
        triangles.reserveCapacity(triangleCount)
        var edgeUse: [STLEdgeKey: UInt8] = [:]
        edgeUse.reserveCapacity(triangleCount * 3 / 2)

        for start in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[start], b = indices[start + 1], c = indices[start + 2]
            guard a != b, b != c, c != a else { throw STLImportError.degenerateTriangle }
            let pa = vertices[Int(a)].position, pb = vertices[Int(b)].position, pc = vertices[Int(c)].position
            let twiceArea = simd_length(simd_cross(pb - pa, pc - pa))
            guard twiceArea.isFinite, twiceArea > areaEpsilon else { throw STLImportError.degenerateTriangle }
            guard triangles.insert(STLTriangleKey(a, b, c)).inserted else { throw STLImportError.duplicateTriangle }
            for edge in [STLEdgeKey(a, b), STLEdgeKey(b, c), STLEdgeKey(c, a)] {
                let count = (edgeUse[edge] ?? 0) + 1
                guard count <= 2 else { throw STLImportError.nonManifoldEdge }
                edgeUse[edge] = count
            }
        }

        var mesh = EditableMesh(vertices: vertices, indices: indices)
        mesh.recalculateNormals(recordChange: false)
        _ = try mesh.validated(maxVertices: maximumWeldedVertexCount,
                               maxIndices: maximumTriangleCount * 3)
        guard mesh.vertices.allSatisfy({ vertex in
            vertex.normal.allFinite && abs(simd_length(vertex.normal) - 1) < 0.001
        }) else { throw STLImportError.nonFiniteValue }
        _ = mesh.adjacency()
        return STLImportResult(mesh: mesh, format: format, sourceByteCount: sourceByteCount,
                               sourceTriangleCount: triangleCount, weldedVertexCount: mesh.vertices.count,
                               bounds: bounds, estimate: estimate)
    }

    private static func canonicalPosition(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(value.x == 0 ? 0 : value.x,
                     value.y == 0 ? 0 : value.y,
                     value.z == 0 ? 0 : value.z)
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func float(in data: Data, at offset: Int) -> Float {
        Float(bitPattern: uint32(in: data, at: offset))
    }

    private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw STLImportError.sizeOverflow }
        return value
    }

    private static func added(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw STLImportError.sizeOverflow }
        return value
    }
}

private struct STLPositionKey: Hashable {
    let x: UInt32
    let y: UInt32
    let z: UInt32

    init(_ value: SIMD3<Float>) {
        x = value.x.bitPattern
        y = value.y.bitPattern
        z = value.z.bitPattern
    }
}

private struct STLTriangleKey: Hashable {
    let first: UInt32
    let second: UInt32
    let third: UInt32

    init(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let ordered = [a, b, c].sorted()
        first = ordered[0]
        second = ordered[1]
        third = ordered[2]
    }
}

private struct STLEdgeKey: Hashable {
    let first: UInt32
    let second: UInt32

    init(_ a: UInt32, _ b: UInt32) {
        first = min(a, b)
        second = max(a, b)
    }
}
