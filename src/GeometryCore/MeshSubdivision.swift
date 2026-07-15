import Foundation
import simd

struct SubdivisionEdgeKey: Hashable, Comparable {
    let low: UInt32
    let high: UInt32

    init(_ first: UInt32, _ second: UInt32) {
        low = min(first, second)
        high = max(first, second)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.low == rhs.low ? lhs.high < rhs.high : lhs.low < rhs.low
    }
}

struct SubdivisionEstimate: Equatable {
    let sourceVertices: Int
    let sourceTriangles: Int
    let uniqueEdges: Int
    let resultVertices: Int
    let resultTriangles: Int
    let resultIndices: Int
    let estimatedWorkingBytes: Int
}

enum MeshSubdivisionError: Error, Equatable, LocalizedError {
    case invalidMesh
    case nonFiniteValue
    case degenerateTriangle
    case nonManifoldEdge
    case vertexLimitExceeded
    case triangleLimitExceeded
    case indexOverflow
    case arithmeticOverflow

    var errorDescription: String? {
        switch self {
        case .invalidMesh: "The mesh structure is invalid."
        case .nonFiniteValue: "The mesh contains a non-finite value."
        case .degenerateTriangle: "The mesh contains a degenerate triangle."
        case .nonManifoldEdge: "The mesh contains a non-manifold edge."
        case .vertexLimitExceeded: "Subdivision would exceed the 500,000 vertex limit."
        case .triangleLimitExceeded: "Subdivision would exceed the 1,000,000 triangle limit."
        case .indexOverflow: "Subdivision would exceed the supported index range."
        case .arithmeticOverflow: "Subdivision size calculation overflowed."
        }
    }
}

enum MeshSubdivision {
    static let maximumVertices = 500_000
    static let maximumTriangles = 1_000_000

    static func estimate(_ mesh: EditableMesh) throws -> SubdivisionEstimate {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty, mesh.indices.count.isMultiple(of: 3),
              mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw MeshSubdivisionError.invalidMesh
        }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw MeshSubdivisionError.nonFiniteValue
        }

        var edgeUse: [SubdivisionEdgeKey: UInt8] = [:]
        edgeUse.reserveCapacity(mesh.indices.count)
        let scale = max(simd_length(mesh.bounds.extent), 1.0e-12)
        let areaEpsilon = max(scale * scale * 1.0e-12, Float.leastNonzeroMagnitude)
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
            guard a != b, b != c, c != a else { throw MeshSubdivisionError.degenerateTriangle }
            let pa = mesh.vertices[Int(a)].position, pb = mesh.vertices[Int(b)].position, pc = mesh.vertices[Int(c)].position
            let twiceArea = simd_length(simd_cross(pb - pa, pc - pa))
            guard twiceArea.isFinite, twiceArea > areaEpsilon else { throw MeshSubdivisionError.degenerateTriangle }
            for edge in [SubdivisionEdgeKey(a, b), SubdivisionEdgeKey(b, c), SubdivisionEdgeKey(c, a)] {
                let count = edgeUse[edge, default: 0]
                guard count < 2 else { throw MeshSubdivisionError.nonManifoldEdge }
                edgeUse[edge] = count + 1
            }
        }

        let triangles = mesh.indices.count / 3
        let (resultVertices, vertexOverflow) = mesh.vertices.count.addingReportingOverflow(edgeUse.count)
        let (resultTriangles, triangleOverflow) = triangles.multipliedReportingOverflow(by: 4)
        let (resultIndices, indexOverflow) = triangles.multipliedReportingOverflow(by: 12)
        guard !vertexOverflow, !triangleOverflow, !indexOverflow else { throw MeshSubdivisionError.arithmeticOverflow }
        guard resultVertices <= Int(UInt32.max) else { throw MeshSubdivisionError.indexOverflow }

        // Conservative transient estimate: before/after history snapshots, adjacency,
        // midpoint hash storage, acceleration structures and CPU/GPU render copies.
        let vertexBytes = MemoryLayout<MeshVertex>.stride
        let indexBytes = MemoryLayout<UInt32>.stride
        let base = resultVertices.multipliedReportingOverflow(by: vertexBytes * 8)
        let indices = resultIndices.multipliedReportingOverflow(by: indexBytes * 4)
        let edges = edgeUse.count.multipliedReportingOverflow(by: 48)
        guard !base.overflow, !indices.overflow, !edges.overflow else { throw MeshSubdivisionError.arithmeticOverflow }
        let (partial, overflow1) = base.partialValue.addingReportingOverflow(indices.partialValue)
        let (bytes, overflow2) = partial.addingReportingOverflow(edges.partialValue)
        guard !overflow1, !overflow2 else { throw MeshSubdivisionError.arithmeticOverflow }

        return SubdivisionEstimate(sourceVertices: mesh.vertices.count, sourceTriangles: triangles,
                                   uniqueEdges: edgeUse.count, resultVertices: resultVertices,
                                   resultTriangles: resultTriangles, resultIndices: resultIndices,
                                   estimatedWorkingBytes: bytes)
    }

    static func validateLimits(_ estimate: SubdivisionEstimate) throws {
        guard estimate.resultVertices <= maximumVertices else { throw MeshSubdivisionError.vertexLimitExceeded }
        guard estimate.resultTriangles <= maximumTriangles else { throw MeshSubdivisionError.triangleLimitExceeded }
    }

    static func subdivideOnce(_ mesh: EditableMesh) throws -> EditableMesh {
        let estimate = try estimate(mesh)
        try validateLimits(estimate)
        var vertices = mesh.vertices
        vertices.reserveCapacity(estimate.resultVertices)
        var indices: [UInt32] = []
        indices.reserveCapacity(estimate.resultIndices)
        var midpoints: [SubdivisionEdgeKey: UInt32] = [:]
        midpoints.reserveCapacity(estimate.uniqueEdges)

        func midpoint(_ first: UInt32, _ second: UInt32) throws -> UInt32 {
            let key = SubdivisionEdgeKey(first, second)
            if let existing = midpoints[key] { return existing }
            guard vertices.count < Int(UInt32.max) else { throw MeshSubdivisionError.indexOverflow }
            let position = (vertices[Int(first)].position + vertices[Int(second)].position) * 0.5
            guard position.allFinite else { throw MeshSubdivisionError.nonFiniteValue }
            let index = UInt32(vertices.count)
            vertices.append(MeshVertex(position: position, normal: SIMD3<Float>(0, 1, 0)))
            midpoints[key] = index
            return index
        }

        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
            let ab = try midpoint(a, b), bc = try midpoint(b, c), ca = try midpoint(c, a)
            indices.append(contentsOf: [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
        }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals(recordChange: false)
        _ = result.adjacency()
        return try result.validated(maxVertices: maximumVertices, maxIndices: maximumTriangles * 3)
    }
}
