import Foundation
import simd

struct VertexRotateTransaction: Equatable {
    let id: UUID
    let topologyID: UUID
    let topologyRevision: UInt64
    let topologyFingerprint: UInt64
    let sourceVertexRevision: UInt64
    let sourceVertexCount: Int
    let sourceIndexCount: Int
    let selectionVersion: VertexSelectionVersion
    let selectedCount: Int
    let projectSessionID: UUID
    let projectGeneration: MutationGeneration
    let vertexIDs: [MeshVertexID]
    let startLocalPositions: [SIMD3<Float>]
    let startWorldPositions: [SIMD3<Float>]
    let pivotLocal: SIMD3<Float>
    let pivotWorld: SIMD3<Float>
    let transform: ObjectTransform
    let axis: SIMD3<Float>
    private(set) var accumulatedAngle: Float = 0

    mutating func update(accumulatedAngle: Float) { self.accumulatedAngle = accumulatedAngle }

    func matches(mesh: EditableMesh, table: MeshVertexTopologyTable,
                 selection: VertexSelection, transform: ObjectTransform,
                 projectSessionID: UUID, projectGeneration: MutationGeneration) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && topologyFingerprint == table.fingerprint
            && sourceVertexRevision == mesh.runtime.revision
            && sourceVertexCount == mesh.vertices.count
            && sourceIndexCount == mesh.indices.count
            && table.matches(mesh) && selection.matches(table)
            && selectionVersion == selection.version && selectedCount == selection.selectedCount
            && self.transform == transform.sanitized()
            && self.projectSessionID == projectSessionID
            && self.projectGeneration == projectGeneration
    }
}

enum VertexRotateError: Error, Equatable, LocalizedError {
    case emptySelection, staleSource, invalidTransform, nonFiniteAngle
    case precisionLoss, workingMemoryLimitExceeded, allocationOverflow, preparationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one vertex before rotating."
        case .staleSource: "The selected vertices changed before the rotation completed."
        case .invalidTransform: "The object transform cannot be inverted safely."
        case .nonFiniteAngle: "The requested rotation is outside the supported numeric range."
        case .precisionLoss: "The rotation cannot be represented safely at the current scale and position."
        case .workingMemoryLimitExceeded: "The rotation would exceed the working-memory limit."
        case .allocationOverflow: "The rotation size calculation overflowed."
        case .preparationFailed: "The selected vertex rotation could not be prepared safely."
        }
    }
}

enum VertexRotateFailurePoint: Hashable {
    case sourceSnapshot, selectedPositionCopy, candidateAllocation
    case candidateValidation, normalRebuild, rendererPreparation, commitBoundary
}

struct VertexRotateFailureInjector {
    let shouldFail: (VertexRotateFailurePoint) -> Bool
    init(shouldFail: @escaping (VertexRotateFailurePoint) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }
}

enum VertexRotateGeometry {
    static let maximumWorkingBytes = 768 * 1_024 * 1_024

    static func begin(mesh: EditableMesh, table: MeshVertexTopologyTable,
                      selection: VertexSelection, transform: ObjectTransform,
                      axis: SIMD3<Float>, projectSessionID: UUID,
                      projectGeneration: MutationGeneration, transactionID: UUID = UUID(),
                      memoryLimit: Int = maximumWorkingBytes,
                      failureInjector: VertexRotateFailureInjector = .init()) throws -> VertexRotateTransaction {
        guard table.matches(mesh), selection.matches(table) else { throw VertexRotateError.staleSource }
        let ids = selection.selectedVertexIDs()
        guard !ids.isEmpty else { throw VertexRotateError.emptySelection }
        guard !failureInjector.shouldFail(.selectedPositionCopy) else { throw VertexRotateError.preparationFailed }
        guard try estimatedPeakBytes(vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
                                     selectedCount: ids.count) <= memoryLimit else {
            throw VertexRotateError.workingMemoryLimitExceeded
        }
        let safeTransform = transform.sanitized()
        guard safeTransform.isFinite, matrixIsFinite(safeTransform.inverseModelMatrix),
              axis.allFinite, simd_length_squared(axis) > 0 else { throw VertexRotateError.invalidTransform }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var local: [SIMD3<Float>] = [], world: [SIMD3<Float>] = []
        local.reserveCapacity(ids.count); world.reserveCapacity(ids.count)
        for id in ids {
            guard Int(id) < mesh.vertices.count else { throw VertexRotateError.staleSource }
            let p = mesh.vertices[Int(id)].position
            let w = safeTransform.worldPosition(fromLocal: p)
            guard p.allFinite, w.allFinite else { throw VertexRotateError.staleSource }
            minimum = simd_min(minimum, p); maximum = simd_max(maximum, p)
            local.append(p); world.append(w)
        }
        let pivotLocal = (minimum + maximum) * 0.5
        let pivotWorld = safeTransform.worldPosition(fromLocal: pivotLocal)
        guard pivotLocal.allFinite, pivotWorld.allFinite else { throw VertexRotateError.invalidTransform }
        return VertexRotateTransaction(
            id: transactionID, topologyID: mesh.runtime.topologyID,
            topologyRevision: mesh.runtime.topologyRevision, topologyFingerprint: table.fingerprint,
            sourceVertexRevision: mesh.runtime.revision, sourceVertexCount: mesh.vertices.count,
            sourceIndexCount: mesh.indices.count, selectionVersion: selection.version,
            selectedCount: selection.selectedCount, projectSessionID: projectSessionID,
            projectGeneration: projectGeneration, vertexIDs: ids,
            startLocalPositions: local, startWorldPositions: world,
            pivotLocal: pivotLocal, pivotWorld: pivotWorld,
            transform: safeTransform, axis: simd_normalize(axis))
    }

    static func candidate(sourceMesh: EditableMesh, transaction: inout VertexRotateTransaction,
                          accumulatedAngle: Float, profiler: PerformanceProfiler? = nil,
                          failureInjector: VertexRotateFailureInjector = .init()) throws -> EditableMesh? {
        guard accumulatedAngle.isFinite else { throw VertexRotateError.nonFiniteAngle }
        transaction.update(accumulatedAngle: accumulatedAngle)
        guard abs(accumulatedAngle) > 1e-7 else { return nil }
        guard transaction.vertexIDs.count == transaction.startLocalPositions.count,
              transaction.vertexIDs.count == transaction.startWorldPositions.count,
              transaction.topologyID == sourceMesh.runtime.topologyID,
              transaction.topologyRevision == sourceMesh.runtime.topologyRevision else {
            throw VertexRotateError.staleSource
        }
        guard !failureInjector.shouldFail(.candidateAllocation) else { throw VertexRotateError.preparationFailed }
        let rotation = simd_quatf(angle: accumulatedAngle, axis: transaction.axis)
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(transaction.selectedCount)
        for offset in transaction.vertexIDs.indices {
            let ideal = transaction.pivotWorld
                + rotation.act(transaction.startWorldPositions[offset] - transaction.pivotWorld)
            let h = transaction.transform.inverseModelMatrix * SIMD4<Float>(ideal, 1)
            guard h.x.isFinite, h.y.isFinite, h.z.isFinite, h.w.isFinite, abs(h.w) > 1e-8 else {
                throw VertexRotateError.precisionLoss
            }
            let local = SIMD3<Float>(h.x, h.y, h.z) / h.w
            let actual = transaction.transform.worldPosition(fromLocal: local)
            let magnitude = max(
                max(1, simd_length(ideal)),
                max(simd_length(transaction.pivotWorld),
                    simd_length(transaction.startWorldPositions[offset] - transaction.pivotWorld)))
            let tolerance = max(0.000_01, magnitude * Float.ulpOfOne * 48)
            guard local.allFinite, actual.allFinite,
                  simd_distance(actual, ideal) <= tolerance else { throw VertexRotateError.precisionLoss }
            updates[Int(transaction.vertexIDs[offset])] = local
        }
        var candidate = sourceMesh
        let mutations = candidate.updatePositions(updates, profiler: profiler)
        guard !failureInjector.shouldFail(.normalRebuild), mutations.count <= updates.count,
              !failureInjector.shouldFail(.candidateValidation),
              !failureInjector.shouldFail(.rendererPreparation) else {
            throw VertexRotateError.preparationFailed
        }
        return candidate
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int,
                                   selectedCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0, selectedCount >= 0 else {
            throw VertexRotateError.allocationOverflow
        }
        var bytes = 0
        func add(_ count: Int, _ stride: Int) throws {
            let (part, o1) = count.multipliedReportingOverflow(by: stride)
            let (sum, o2) = bytes.addingReportingOverflow(part)
            guard !o1, !o2 else { throw VertexRotateError.allocationOverflow }
            bytes = sum
        }
        try add(vertexCount, MemoryLayout<MeshVertex>.stride * 4)
        try add(indexCount, MemoryLayout<UInt32>.stride * 2)
        let triangles = indexCount / 3
        try add(triangles, MemoryLayout<TriangleReference>.stride * 2)
        try add(triangles, MemoryLayout<BVHNode>.stride * 4)
        try add(selectedCount, MemoryLayout<MeshVertexID>.stride)
        try add(selectedCount, MemoryLayout<SIMD3<Float>>.stride * 3)
        try add(selectedCount, 64)
        return bytes
    }

    private static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }
    }
}
