import Foundation
import simd

struct VertexScaleTransaction: Equatable {
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
    let pivotLocal: SIMD3<Float>
    let pivotWorld: SIMD3<Float>
    let transform: ObjectTransform
    let handle: ScaleGizmoHandle
    private(set) var factor: Float = 1

    mutating func update(factor: Float) { self.factor = factor }

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

enum VertexScaleError: Error, Equatable, LocalizedError {
    case emptySelection, staleSource, invalidTransform, invalidFactor
    case precisionLoss, workingMemoryLimitExceeded, allocationOverflow, preparationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one vertex before scaling."
        case .staleSource: "The selected vertices changed before the scale completed."
        case .invalidTransform: "The object transform cannot be inverted safely."
        case .invalidFactor: "The requested scale factor is outside the supported range."
        case .precisionLoss: "The scale cannot be represented safely at the current size."
        case .workingMemoryLimitExceeded: "The scale would exceed the working-memory limit."
        case .allocationOverflow: "The scale size calculation overflowed."
        case .preparationFailed: "The selected vertex scale could not be prepared safely."
        }
    }
}

enum VertexScaleFailurePoint: Hashable {
    case sourceSnapshot, selectedPositionCopy, candidateAllocation
    case roundTripValidation, candidatePostUpdate
    case previewBVHPreparation, beginCommitBoundary, commitBVHPreparation, commitBoundary
}

struct VertexScaleFailureInjector {
    let shouldFail: (VertexScaleFailurePoint) -> Bool
    init(shouldFail: @escaping (VertexScaleFailurePoint) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }
}

enum VertexScaleGeometry {
    static let maximumWorkingBytes = 768 * 1_024 * 1_024
    static let minimumFactor: Float = 0.001
    static let maximumFactor: Float = 1_000

    static func begin(mesh: EditableMesh, table: MeshVertexTopologyTable,
                      selection: VertexSelection, transform: ObjectTransform,
                      handle: ScaleGizmoHandle, projectSessionID: UUID,
                      projectGeneration: MutationGeneration, transactionID: UUID = UUID(),
                      memoryLimit: Int = maximumWorkingBytes,
                      failureInjector: VertexScaleFailureInjector = .init()) throws -> VertexScaleTransaction {
        guard table.matches(mesh), selection.matches(table) else { throw VertexScaleError.staleSource }
        let ids = selection.selectedVertexIDs()
        guard !ids.isEmpty else { throw VertexScaleError.emptySelection }
        guard !failureInjector.shouldFail(.selectedPositionCopy) else { throw VertexScaleError.preparationFailed }
        guard try estimatedPeakBytes(vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
                                     selectedCount: ids.count) <= memoryLimit else {
            throw VertexScaleError.workingMemoryLimitExceeded
        }
        let safeTransform = transform.sanitized()
        guard safeTransform.isFinite, matrixIsFinite(safeTransform.inverseModelMatrix),
              matrixIsFinite(safeTransform.modelMatrix) else { throw VertexScaleError.invalidTransform }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var local: [SIMD3<Float>] = []
        local.reserveCapacity(ids.count)
        for id in ids {
            guard Int(id) < mesh.vertices.count else { throw VertexScaleError.staleSource }
            let position = mesh.vertices[Int(id)].position
            guard position.allFinite else { throw VertexScaleError.staleSource }
            minimum = simd_min(minimum, position); maximum = simd_max(maximum, position)
            local.append(position)
        }
        let pivotLocal = minimum * 0.5 + maximum * 0.5
        let pivotWorld = safeTransform.worldPosition(fromLocal: pivotLocal)
        guard pivotLocal.allFinite, pivotWorld.allFinite else { throw VertexScaleError.invalidTransform }
        return VertexScaleTransaction(
            id: transactionID, topologyID: mesh.runtime.topologyID,
            topologyRevision: mesh.runtime.topologyRevision, topologyFingerprint: table.fingerprint,
            sourceVertexRevision: mesh.runtime.revision, sourceVertexCount: mesh.vertices.count,
            sourceIndexCount: mesh.indices.count, selectionVersion: selection.version,
            selectedCount: selection.selectedCount, projectSessionID: projectSessionID,
            projectGeneration: projectGeneration, vertexIDs: ids, startLocalPositions: local,
            pivotLocal: pivotLocal, pivotWorld: pivotWorld, transform: safeTransform, handle: handle)
    }

    static func candidate(sourceMesh: EditableMesh, transaction: inout VertexScaleTransaction,
                          factor: Float, profiler: PerformanceProfiler? = nil,
                          failureInjector: VertexScaleFailureInjector = .init()) throws -> EditableMesh? {
        guard factor.isFinite, factor >= minimumFactor, factor <= maximumFactor else {
            throw VertexScaleError.invalidFactor
        }
        transaction.update(factor: factor)
        guard factor != 1 else { return nil }
        guard transaction.vertexIDs.count == transaction.startLocalPositions.count,
              transaction.topologyID == sourceMesh.runtime.topologyID,
              transaction.topologyRevision == sourceMesh.runtime.topologyRevision else {
            throw VertexScaleError.staleSource
        }
        guard !failureInjector.shouldFail(.candidateAllocation) else { throw VertexScaleError.preparationFailed }
        let worldScale: SIMD3<Float>
        switch transaction.handle {
        case .xAxis: worldScale = SIMD3<Float>(factor, 1, 1)
        case .yAxis: worldScale = SIMD3<Float>(1, factor, 1)
        case .zAxis: worldScale = SIMD3<Float>(1, 1, factor)
        case .uniform: worldScale = SIMD3<Float>(repeating: factor)
        }
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(transaction.selectedCount)
        for offset in transaction.vertexIDs.indices {
            let localOffset = transaction.startLocalPositions[offset] - transaction.pivotLocal
            let world4 = transaction.transform.modelMatrix * SIMD4<Float>(localOffset, 0)
            let worldOffset = SIMD3<Float>(world4.x, world4.y, world4.z)
            let scaledWorldOffset = worldOffset * worldScale
            let local4 = transaction.transform.inverseModelMatrix * SIMD4<Float>(scaledWorldOffset, 0)
            guard localOffset.allFinite, worldOffset.allFinite, scaledWorldOffset.allFinite,
                  local4.x.isFinite, local4.y.isFinite, local4.z.isFinite else {
                throw VertexScaleError.precisionLoss
            }
            let scaledLocalOffset = SIMD3<Float>(local4.x, local4.y, local4.z)
            let local = transaction.pivotLocal + scaledLocalOffset
            let actual4 = transaction.transform.modelMatrix * SIMD4<Float>(local - transaction.pivotLocal, 0)
            let actualWorldOffset = SIMD3<Float>(actual4.x, actual4.y, actual4.z)
            let magnitude = max(
                1, max(
                    max(maxAbsComponent(worldOffset), maxAbsComponent(scaledWorldOffset)),
                    max(maxAbsComponent(localOffset), maxAbsComponent(scaledLocalOffset))))
            let tolerance = max(0.000_01, magnitude * Float.ulpOfOne * 48)
            let errorVector = actualWorldOffset - scaledWorldOffset
            let error = maxAbsComponent(errorVector)
            guard local.allFinite, actualWorldOffset.allFinite,
                  errorVector.allFinite, magnitude.isFinite, tolerance.isFinite,
                  error.isFinite, error <= tolerance,
                  !failureInjector.shouldFail(.roundTripValidation) else {
                throw VertexScaleError.precisionLoss
            }
            updates[Int(transaction.vertexIDs[offset])] = local
        }
        var candidate = sourceMesh
        let mutations = candidate.updatePositions(updates, profiler: profiler)
        guard mutations.count <= updates.count,
              !failureInjector.shouldFail(.candidatePostUpdate) else {
            throw VertexScaleError.preparationFailed
        }
        return candidate
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int,
                                   selectedCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0, selectedCount >= 0 else {
            throw VertexScaleError.allocationOverflow
        }
        var bytes = 0
        func add(_ count: Int, _ stride: Int) throws {
            let (part, firstOverflow) = count.multipliedReportingOverflow(by: stride)
            let (sum, secondOverflow) = bytes.addingReportingOverflow(part)
            guard !firstOverflow, !secondOverflow else { throw VertexScaleError.allocationOverflow }
            bytes = sum
        }
        try add(vertexCount, MemoryLayout<MeshVertex>.stride * 4)
        try add(indexCount, MemoryLayout<UInt32>.stride * 2)
        let triangles = indexCount / 3
        try add(triangles, MemoryLayout<TriangleReference>.stride * 2)
        try add(triangles, MemoryLayout<BVHNode>.stride * 4)
        try add(selectedCount, MemoryLayout<MeshVertexID>.stride)
        try add(selectedCount, MemoryLayout<SIMD3<Float>>.stride * 2)
        try add(selectedCount, 64)
        return bytes
    }

    private static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }
    }

    private static func maxAbsComponent(_ value: SIMD3<Float>) -> Float {
        max(abs(value.x), max(abs(value.y), abs(value.z)))
    }
}
