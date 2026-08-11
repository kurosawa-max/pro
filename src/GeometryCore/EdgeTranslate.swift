import Foundation
import simd

struct EdgeTranslateTransaction: Equatable {
    let id: UUID
    let topologyID: UUID
    let topologyRevision: UInt64
    let edgeTableFingerprint: UInt64
    let sourceVertexRevision: UInt64
    let sourceVertexCount: Int
    let sourceIndexCount: Int
    let selectionVersion: EdgeSelectionVersion
    let selectedEdgeCount: Int
    let affectedVertexCount: Int
    let selectedEdgeIDs: [Int]
    let vertexIDs: [UInt32]
    let startPositions: [SIMD3<Float>]
    let pivotLocal: SIMD3<Float>
    let pivotWorld: SIMD3<Float>
    let transform: ObjectTransform
    let projectSessionID: UUID
    let projectGeneration: MutationGeneration
    private(set) var worldDelta: SIMD3<Float> = .zero
    private(set) var localDelta: SIMD3<Float> = .zero

    mutating func update(worldDelta: SIMD3<Float>, localDelta: SIMD3<Float>) {
        self.worldDelta = worldDelta
        self.localDelta = localDelta
    }

    func matches(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                 transform: ObjectTransform, projectSessionID: UUID,
                 projectGeneration: MutationGeneration) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && edgeTableFingerprint == table.fingerprint
            && sourceVertexRevision == mesh.runtime.revision
            && sourceVertexCount == mesh.vertices.count
            && sourceIndexCount == mesh.indices.count
            && table.matches(mesh) && selection.matches(table)
            && selectionVersion == selection.version
            && selectedEdgeCount == selection.selectedCount
            && self.transform == transform.sanitized()
            && self.projectSessionID == projectSessionID
            && self.projectGeneration == projectGeneration
    }
}

enum EdgeTranslateError: Error, Equatable, LocalizedError {
    case emptySelection, staleSource, invalidTransform, nonFiniteDelta
    case workingMemoryLimitExceeded, allocationOverflow, preparationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one edge before moving."
        case .staleSource: "The selected edges changed before the move completed."
        case .invalidTransform: "The object transform cannot be inverted safely."
        case .nonFiniteDelta: "The requested move is outside the supported numeric range."
        case .workingMemoryLimitExceeded: "The move would exceed the working-memory limit."
        case .allocationOverflow: "The move size calculation overflowed."
        case .preparationFailed: "The selected edge move could not be prepared safely."
        }
    }
}

enum EdgeTranslateFailurePoint: Hashable {
    case sourceSnapshot, candidateAllocation, candidateValidation, normalRebuild
    case rendererPreparation, previewBVHPreparation, beginCommitBoundary
    case commitBVHPreparation, commitBoundary
}

struct EdgeTranslateFailureInjector {
    let shouldFail: (EdgeTranslateFailurePoint) -> Bool
    init(shouldFail: @escaping (EdgeTranslateFailurePoint) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }
}

enum EdgeTranslateGeometry {
    static let maximumWorkingBytes = 768 * 1_024 * 1_024

    static func affectedVertexIDs(table: MeshEdgeTable, selection: EdgeSelection) throws -> [UInt32] {
        guard selection.matches(table) else { throw EdgeTranslateError.staleSource }
        let edgeIDs = selection.selectedEdgeIDs()
        guard !edgeIDs.isEmpty else { throw EdgeTranslateError.emptySelection }
        var ids: Set<UInt32> = []
        ids.reserveCapacity(edgeIDs.count * 2)
        for edgeID in edgeIDs {
            guard table.edges.indices.contains(edgeID) else { throw EdgeTranslateError.staleSource }
            let key = table.edges[edgeID].key
            ids.insert(key.low); ids.insert(key.high)
        }
        return ids.sorted()
    }

    static func pivot(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                      transform: ObjectTransform) throws -> (local: SIMD3<Float>, world: SIMD3<Float>) {
        guard table.matches(mesh) else { throw EdgeTranslateError.staleSource }
        let ids = try affectedVertexIDs(table: table, selection: selection)
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for id in ids {
            guard Int(id) < mesh.vertices.count else { throw EdgeTranslateError.staleSource }
            let p = mesh.vertices[Int(id)].position
            guard p.allFinite else { throw EdgeTranslateError.staleSource }
            minimum = simd_min(minimum, p); maximum = simd_max(maximum, p)
        }
        let local = minimum * 0.5 + maximum * 0.5
        let safe = transform.sanitized()
        let world = safe.worldPosition(fromLocal: local)
        guard safe.isFinite, local.allFinite, world.allFinite else { throw EdgeTranslateError.invalidTransform }
        return (local, world)
    }

    static func begin(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                      transform: ObjectTransform, projectSessionID: UUID,
                      projectGeneration: MutationGeneration, transactionID: UUID = UUID(),
                      memoryLimit: Int = maximumWorkingBytes,
                      failureInjector: EdgeTranslateFailureInjector = .init()) throws -> EdgeTranslateTransaction {
        guard table.matches(mesh), selection.matches(table) else { throw EdgeTranslateError.staleSource }
        guard !failureInjector.shouldFail(.sourceSnapshot) else { throw EdgeTranslateError.preparationFailed }
        let selectedEdgeCount = selection.selectedCount
        guard selectedEdgeCount > 0 else { throw EdgeTranslateError.emptySelection }
        let (twiceEdges, overflow) = selectedEdgeCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw EdgeTranslateError.allocationOverflow }
        let maximumAffectedVertexCount = min(mesh.vertices.count, twiceEdges)
        let upperEstimate = try estimatedPeakBytes(
            vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
            selectedEdgeCount: selectedEdgeCount, affectedVertexCount: maximumAffectedVertexCount)
        guard upperEstimate <= memoryLimit else { throw EdgeTranslateError.workingMemoryLimitExceeded }

        let edgeIDs = selection.selectedEdgeIDs()
        guard edgeIDs.count == selectedEdgeCount else { throw EdgeTranslateError.staleSource }
        var endpoints = Set<UInt32>()
        endpoints.reserveCapacity(maximumAffectedVertexCount)
        for edgeID in edgeIDs {
            guard table.edges.indices.contains(edgeID) else { throw EdgeTranslateError.staleSource }
            endpoints.insert(table.edges[edgeID].key.low)
            endpoints.insert(table.edges[edgeID].key.high)
        }
        let vertexIDs = endpoints.sorted()
        let actualEstimate = try estimatedPeakBytes(
            vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
            selectedEdgeCount: selectedEdgeCount, affectedVertexCount: vertexIDs.count)
        guard actualEstimate <= memoryLimit else { throw EdgeTranslateError.workingMemoryLimitExceeded }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var starts: [SIMD3<Float>] = []
        starts.reserveCapacity(vertexIDs.count)
        for id in vertexIDs {
            guard Int(id) < mesh.vertices.count else { throw EdgeTranslateError.staleSource }
            let position = mesh.vertices[Int(id)].position
            guard position.allFinite else { throw EdgeTranslateError.staleSource }
            starts.append(position)
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        let safeTransform = transform.sanitized()
        let pivotLocal = minimum * 0.5 + maximum * 0.5
        let pivotWorld = safeTransform.worldPosition(fromLocal: pivotLocal)
        guard safeTransform.isFinite, pivotLocal.allFinite, pivotWorld.allFinite else {
            throw EdgeTranslateError.invalidTransform
        }
        return EdgeTranslateTransaction(
            id: transactionID, topologyID: mesh.runtime.topologyID,
            topologyRevision: mesh.runtime.topologyRevision, edgeTableFingerprint: table.fingerprint,
            sourceVertexRevision: mesh.runtime.revision, sourceVertexCount: mesh.vertices.count,
            sourceIndexCount: mesh.indices.count, selectionVersion: selection.version,
            selectedEdgeCount: selectedEdgeCount, affectedVertexCount: vertexIDs.count,
            selectedEdgeIDs: edgeIDs, vertexIDs: vertexIDs, startPositions: starts,
            pivotLocal: pivotLocal, pivotWorld: pivotWorld, transform: safeTransform,
            projectSessionID: projectSessionID, projectGeneration: projectGeneration)
    }

    static func candidate(sourceMesh: EditableMesh, transaction: inout EdgeTranslateTransaction,
                          worldDelta: SIMD3<Float>, profiler: PerformanceProfiler? = nil,
                          failureInjector: EdgeTranslateFailureInjector = .init()) throws -> EditableMesh? {
        guard worldDelta.allFinite else { throw EdgeTranslateError.nonFiniteDelta }
        let transformed = transaction.transform.inverseModelMatrix * SIMD4<Float>(worldDelta, 0)
        let localDelta = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
        guard transformed.w.isFinite, abs(transformed.w) <= 0.000_01, localDelta.allFinite else {
            throw EdgeTranslateError.nonFiniteDelta
        }
        transaction.update(worldDelta: worldDelta, localDelta: localDelta)
        guard localDelta != .zero else { return nil }
        guard transaction.topologyID == sourceMesh.runtime.topologyID,
              transaction.topologyRevision == sourceMesh.runtime.topologyRevision,
              transaction.vertexIDs.count == transaction.startPositions.count else {
            throw EdgeTranslateError.staleSource
        }
        guard !failureInjector.shouldFail(.candidateAllocation) else {
            throw EdgeTranslateError.preparationFailed
        }
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(transaction.vertexIDs.count)
        for (offset, id) in transaction.vertexIDs.enumerated() {
            let value = transaction.startPositions[offset] + localDelta
            guard value.allFinite else { throw EdgeTranslateError.nonFiniteDelta }
            updates[Int(id)] = value
        }
        var candidate = sourceMesh
        let mutations = candidate.updatePositions(updates, profiler: profiler)
        guard !failureInjector.shouldFail(.normalRebuild), mutations.count == updates.count,
              !failureInjector.shouldFail(.candidateValidation),
              !failureInjector.shouldFail(.rendererPreparation) else {
            throw EdgeTranslateError.preparationFailed
        }
        return candidate
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int,
                                   selectedEdgeCount: Int, affectedVertexCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0, selectedEdgeCount >= 0, affectedVertexCount >= 0 else {
            throw EdgeTranslateError.allocationOverflow
        }
        var bytes = 0
        func add(_ count: Int, _ stride: Int) throws {
            let (part, a) = count.multipliedReportingOverflow(by: stride)
            let (sum, b) = bytes.addingReportingOverflow(part)
            guard !a, !b else { throw EdgeTranslateError.allocationOverflow }; bytes = sum
        }
        try add(vertexCount, MemoryLayout<MeshVertex>.stride * 4)
        try add(indexCount, MemoryLayout<UInt32>.stride * 2)
        let triangles = indexCount / 3
        try add(triangles, MemoryLayout<TriangleReference>.stride + MemoryLayout<BVHNode>.stride * 2)
        try add(selectedEdgeCount, MemoryLayout<Int>.stride)
        // Endpoint Set storage is conservatively included in addition to the sorted ID array.
        try add(affectedVertexCount, MemoryLayout<UInt32>.stride + MemoryLayout<SIMD3<Float>>.stride * 2 + 96)
        return bytes
    }
}
