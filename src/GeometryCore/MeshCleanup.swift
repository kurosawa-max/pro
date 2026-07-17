import Foundation
import simd

struct MeshCleanupOptions: Equatable {
    var removeDegenerateTriangles = false
    var removeDuplicateTriangles = false
    var removeIsolatedVertices = false

    static let none = MeshCleanupOptions()

    var hasSelection: Bool {
        removeDegenerateTriangles || removeDuplicateTriangles || removeIsolatedVertices
    }
}

struct MeshCleanupEstimate: Equatable {
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let removableDegenerateTriangleCount: Int
    let removableDuplicateTriangleCount: Int
    let removableIsolatedVertexCount: Int
    let newlyUnreferencedVertexCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let estimatedWorkingByteCount: Int

    var removedTriangleCount: Int {
        removableDegenerateTriangleCount + removableDuplicateTriangleCount
    }

    var removedVertexCount: Int {
        removableIsolatedVertexCount + newlyUnreferencedVertexCount
    }
}

struct MeshCleanupResult: Equatable {
    let mesh: EditableMesh
    let removedDegenerateTriangleCount: Int
    let removedDuplicateTriangleCount: Int
    let removedIsolatedVertexCount: Int
    let removedUnreferencedVertexCount: Int
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int

    var summary: MeshCleanupSummary {
        MeshCleanupSummary(
            removedDegenerateTriangleCount: removedDegenerateTriangleCount,
            removedDuplicateTriangleCount: removedDuplicateTriangleCount,
            removedIsolatedVertexCount: removedIsolatedVertexCount,
            removedUnreferencedVertexCount: removedUnreferencedVertexCount,
            originalVertexCount: originalVertexCount,
            originalTriangleCount: originalTriangleCount,
            resultingVertexCount: resultingVertexCount,
            resultingTriangleCount: resultingTriangleCount
        )
    }
}

struct MeshCleanupSummary: Equatable {
    let removedDegenerateTriangleCount: Int
    let removedDuplicateTriangleCount: Int
    let removedIsolatedVertexCount: Int
    let removedUnreferencedVertexCount: Int
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
}

struct MeshCleanupSourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let revision: UInt64
    let workspaceMutationGeneration: UInt64

    init(mesh: EditableMesh, workspaceMutationGeneration: UInt64) {
        topologyID = mesh.runtime.topologyID
        topologyRevision = mesh.runtime.topologyRevision
        revision = mesh.runtime.revision
        self.workspaceMutationGeneration = workspaceMutationGeneration
    }
}

struct MeshCleanupPreview: Equatable {
    let options: MeshCleanupOptions
    let estimate: MeshCleanupEstimate
    let source: MeshCleanupSourceKey
}

enum MeshCleanupError: Error, Equatable, LocalizedError {
    case noOptionsSelected
    case noApplicableCleanup
    case invalidMesh
    case nonFiniteValue
    case emptyResult
    case vertexLimitExceeded
    case triangleLimitExceeded
    case indexOverflow
    case arithmeticOverflow
    case workingMemoryLimitExceeded
    case validationFailed
    case stalePreview
    case cleanupInProgress
    case activeEdit

    var errorDescription: String? {
        switch self {
        case .noOptionsSelected: "Select at least one cleanup item."
        case .noApplicableCleanup: "The selected cleanup items have nothing to remove."
        case .invalidMesh: "The mesh structure or an index is invalid. Cleanup cannot repair invalid indices."
        case .nonFiniteValue: "The mesh contains NaN or Infinity. Cleanup cannot safely continue."
        case .emptyResult: "Cleanup would remove every triangle or leave fewer than three vertices."
        case .vertexLimitExceeded: "The mesh exceeds the 2,000,000 vertex cleanup limit."
        case .triangleLimitExceeded: "The mesh exceeds the 4,000,000 triangle cleanup limit."
        case .indexOverflow: "Cleanup would exceed the supported UInt32 index range."
        case .arithmeticOverflow: "Cleanup size calculation overflowed."
        case .workingMemoryLimitExceeded: "Cleanup would exceed the 768 MiB working-memory limit."
        case .validationFailed: "The cleaned mesh failed post-cleanup validation."
        case .stalePreview: "The mesh changed after this preview. Create a new cleanup preview."
        case .cleanupInProgress: "Mesh Cleanup is already running."
        case .activeEdit: "Finish or prepare the active Sculpt, Gizmo, or Transform edit before cleanup."
        }
    }
}

enum MeshCleanup {
    static let maximumVertices = 2_000_000
    static let maximumTriangles = 4_000_000
    static let maximumWorkingBytes = 768 * 1_024 * 1_024

    static func estimate(mesh: EditableMesh, options: MeshCleanupOptions) throws -> MeshCleanupEstimate {
        try makePlan(mesh: mesh, options: options).estimate
    }

    static func clean(mesh: EditableMesh, options: MeshCleanupOptions) throws -> MeshCleanupResult {
        let plan = try makePlan(mesh: mesh, options: options)
        var remap = Array<UInt32?>(repeating: nil, count: mesh.vertices.count)
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(plan.estimate.resultingVertexCount)

        for oldIndex in mesh.vertices.indices where !plan.removedVertices[oldIndex] {
            guard vertices.count < Int(UInt32.max) else { throw MeshCleanupError.indexOverflow }
            remap[oldIndex] = UInt32(vertices.count)
            vertices.append(mesh.vertices[oldIndex])
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(plan.keptIndices.count)
        for oldIndex in plan.keptIndices {
            guard Int(oldIndex) < remap.count, let newIndex = remap[Int(oldIndex)] else {
                throw MeshCleanupError.validationFailed
            }
            indices.append(newIndex)
        }

        guard vertices.count >= 3, indices.count >= 3 else { throw MeshCleanupError.emptyResult }
        var cleaned = EditableMesh(vertices: vertices, indices: indices)
        cleaned.recalculateNormals(recordChange: false)
        _ = cleaned.adjacency()
        _ = try cleaned.validated(maxVertices: maximumVertices, maxIndices: maximumTriangles * 3)

        let topology = MeshTopologyDiagnostics.analyze(cleaned)
        guard !topology.hasInvalidStructure, topology.invalidIndexTriangleCount == 0,
              topology.nonFiniteVertexCount == 0 else { throw MeshCleanupError.validationFailed }
        if options.removeDegenerateTriangles, topology.degenerateTriangleCount != 0 {
            throw MeshCleanupError.validationFailed
        }
        if options.removeDuplicateTriangles, topology.duplicateTriangleCount != 0 {
            throw MeshCleanupError.validationFailed
        }
        if options.removeIsolatedVertices, topology.isolatedVertexCount != 0 {
            throw MeshCleanupError.validationFailed
        }
        guard cleaned.vertices.allSatisfy({ vertex in
            let length = simd_length(vertex.normal)
            return vertex.position.allFinite && vertex.normal.allFinite && length.isFinite
                && abs(length - 1) <= 0.000_1
        }) else { throw MeshCleanupError.validationFailed }

        return MeshCleanupResult(
            mesh: cleaned,
            removedDegenerateTriangleCount: plan.estimate.removableDegenerateTriangleCount,
            removedDuplicateTriangleCount: plan.estimate.removableDuplicateTriangleCount,
            removedIsolatedVertexCount: plan.estimate.removableIsolatedVertexCount,
            removedUnreferencedVertexCount: plan.estimate.newlyUnreferencedVertexCount,
            originalVertexCount: plan.estimate.originalVertexCount,
            originalTriangleCount: plan.estimate.originalTriangleCount,
            resultingVertexCount: cleaned.vertices.count,
            resultingTriangleCount: cleaned.indices.count / 3
        )
    }

    static func estimatedWorkingBytes(
        originalVertices: Int,
        originalIndices: Int,
        resultingVertices: Int,
        resultingIndices: Int
    ) throws -> Int {
        guard originalVertices >= 0, originalIndices >= 0,
              resultingVertices >= 0, resultingIndices >= 0 else {
            throw MeshCleanupError.arithmeticOverflow
        }
        let sourceVertices = try multiply(originalVertices, MemoryLayout<MeshVertex>.stride * 2)
        let sourceIndices = try multiply(originalIndices, MemoryLayout<UInt32>.stride * 2)
        let outputVertices = try multiply(resultingVertices, MemoryLayout<MeshVertex>.stride * 6)
        let outputIndices = try multiply(resultingIndices, MemoryLayout<UInt32>.stride * 4)
        let remapAndFlags = try multiply(originalVertices, 24)
        let triangleState = try multiply(originalIndices / 3, 32)
        let adjacencyVertices = try multiply(resultingVertices, 24)
        let adjacencyIndices = try multiply(resultingIndices, 8)
        return try add([sourceVertices, sourceIndices, outputVertices, outputIndices,
                        remapAndFlags, triangleState, adjacencyVertices, adjacencyIndices])
    }

    static func validateWorkingByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0 else { throw MeshCleanupError.arithmeticOverflow }
        guard byteCount <= maximumWorkingBytes else { throw MeshCleanupError.workingMemoryLimitExceeded }
    }

    private struct Plan {
        let estimate: MeshCleanupEstimate
        let keptIndices: [UInt32]
        let removedVertices: [Bool]
    }

    private static func makePlan(mesh: EditableMesh, options: MeshCleanupOptions) throws -> Plan {
        guard options.hasSelection else { throw MeshCleanupError.noOptionsSelected }
        guard mesh.vertices.count >= 3, !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3) else { throw MeshCleanupError.invalidMesh }
        let triangleCount = mesh.indices.count / 3
        guard mesh.vertices.count <= maximumVertices else { throw MeshCleanupError.vertexLimitExceeded }
        guard triangleCount <= maximumTriangles else { throw MeshCleanupError.triangleLimitExceeded }
        guard mesh.vertices.count <= Int(UInt32.max) else { throw MeshCleanupError.indexOverflow }
        guard mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw MeshCleanupError.invalidMesh
        }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw MeshCleanupError.nonFiniteValue
        }
        let worstCaseBytes = try estimatedWorkingBytes(
            originalVertices: mesh.vertices.count,
            originalIndices: mesh.indices.count,
            resultingVertices: mesh.vertices.count,
            resultingIndices: mesh.indices.count
        )
        try validateWorkingByteCount(worstCaseBytes)

        var originalReferenced = Array(repeating: false, count: mesh.vertices.count)
        var keptIndices: [UInt32] = []
        keptIndices.reserveCapacity(mesh.indices.count)
        var seenTriangles: Set<MeshDiagnosticTriangleKey> = []
        seenTriangles.reserveCapacity(triangleCount)
        var removedDegenerate = 0
        var removedDuplicate = 0
        let twiceAreaEpsilon = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: mesh)

        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
            originalReferenced[Int(a)] = true
            originalReferenced[Int(b)] = true
            originalReferenced[Int(c)] = true
            let isDegenerate = MeshDiagnosticTriangleRules.isDegenerate(
                a, b, c, vertices: mesh.vertices, twiceAreaEpsilon: twiceAreaEpsilon
            )
            let isDuplicate = !seenTriangles.insert(MeshDiagnosticTriangleKey(a, b, c)).inserted
            if options.removeDegenerateTriangles, isDegenerate {
                removedDegenerate += 1
                continue
            }
            if options.removeDuplicateTriangles, isDuplicate {
                removedDuplicate += 1
                continue
            }
            keptIndices.append(contentsOf: [a, b, c])
        }

        guard keptIndices.count >= 3 else { throw MeshCleanupError.emptyResult }
        var resultingReferenced = Array(repeating: false, count: mesh.vertices.count)
        for index in keptIndices { resultingReferenced[Int(index)] = true }
        var removedVertices = Array(repeating: false, count: mesh.vertices.count)
        var removedIsolated = 0
        var removedNewlyUnreferenced = 0
        for index in mesh.vertices.indices {
            if originalReferenced[index], !resultingReferenced[index] {
                removedVertices[index] = true
                removedNewlyUnreferenced += 1
            } else if !originalReferenced[index], options.removeIsolatedVertices {
                removedVertices[index] = true
                removedIsolated += 1
            }
        }

        let removedVertexCount = try add([removedIsolated, removedNewlyUnreferenced])
        let (resultingVertexCount, vertexUnderflow) = mesh.vertices.count.subtractingReportingOverflow(removedVertexCount)
        let removedTriangleCount = try add([removedDegenerate, removedDuplicate])
        let (resultingTriangleCount, triangleUnderflow) = triangleCount.subtractingReportingOverflow(removedTriangleCount)
        guard !vertexUnderflow, !triangleUnderflow else { throw MeshCleanupError.arithmeticOverflow }
        guard resultingVertexCount >= 3, resultingTriangleCount >= 1 else { throw MeshCleanupError.emptyResult }
        guard removedVertexCount > 0 || removedTriangleCount > 0 else {
            throw MeshCleanupError.noApplicableCleanup
        }

        let workingBytes = try estimatedWorkingBytes(
            originalVertices: mesh.vertices.count,
            originalIndices: mesh.indices.count,
            resultingVertices: resultingVertexCount,
            resultingIndices: keptIndices.count
        )
        try validateWorkingByteCount(workingBytes)
        let estimate = MeshCleanupEstimate(
            originalVertexCount: mesh.vertices.count,
            originalTriangleCount: triangleCount,
            removableDegenerateTriangleCount: removedDegenerate,
            removableDuplicateTriangleCount: removedDuplicate,
            removableIsolatedVertexCount: removedIsolated,
            newlyUnreferencedVertexCount: removedNewlyUnreferenced,
            resultingVertexCount: resultingVertexCount,
            resultingTriangleCount: resultingTriangleCount,
            estimatedWorkingByteCount: workingBytes
        )
        return Plan(estimate: estimate, keptIndices: keptIndices, removedVertices: removedVertices)
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw MeshCleanupError.arithmeticOverflow }
        return result.partialValue
    }

    private static func add(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { throw MeshCleanupError.arithmeticOverflow }
            result = next.partialValue
        }
        return result
    }
}
