import Foundation
import simd

struct EdgeScaleTransaction: Equatable {
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
    let startLocalPositions: [SIMD3<Float>]
    let pivotLocal: SIMD3<Float>
    let pivotWorld: SIMD3<Float>
    let transform: ObjectTransform
    let handle: ScaleGizmoHandle
    let projectSessionID: UUID
    let projectGeneration: MutationGeneration
    private(set) var factor: Float = 1

    mutating func update(factor: Float) { self.factor = factor }

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

enum EdgeScaleError: Error, Equatable, LocalizedError {
    case emptySelection, staleSource, invalidTransform, invalidFactor
    case precisionLoss, workingMemoryLimitExceeded, allocationOverflow, preparationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one edge before scaling."
        case .staleSource: "The selected edges changed before the scale completed."
        case .invalidTransform: "The object transform cannot be inverted safely."
        case .invalidFactor: "The requested scale factor is outside the supported range."
        case .precisionLoss: "The scale cannot be represented safely at the current size."
        case .workingMemoryLimitExceeded: "The scale would exceed the working-memory limit."
        case .allocationOverflow: "The scale size calculation overflowed."
        case .preparationFailed: "The selected edge scale could not be prepared safely."
        }
    }
}

enum EdgeScaleFailurePoint: Hashable {
    case sourceSnapshot, selectedPositionCopy, candidateAllocation
    case candidateValidation, normalRebuild, rendererPreparation
    case roundTripValidation, candidatePostUpdate
    case previewBVHPreparation, beginCommitBoundary
    case commitBVHPreparation, commitBoundary
}

struct EdgeScaleFailureInjector {
    let shouldFail: (EdgeScaleFailurePoint) -> Bool
    init(shouldFail: @escaping (EdgeScaleFailurePoint) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }
}

enum EdgeScaleGeometry {
    static let maximumWorkingBytes = 768 * 1_024 * 1_024
    static let minimumFactor: Float = 0.001
    static let maximumFactor: Float = 1_000

    static func begin(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                      transform: ObjectTransform, handle: ScaleGizmoHandle,
                      projectSessionID: UUID, projectGeneration: MutationGeneration,
                      transactionID: UUID = UUID(), memoryLimit: Int = maximumWorkingBytes,
                      failureInjector: EdgeScaleFailureInjector = .init()) throws -> EdgeScaleTransaction {
        guard table.matches(mesh), selection.matches(table) else { throw EdgeScaleError.staleSource }
        guard !failureInjector.shouldFail(.sourceSnapshot) else { throw EdgeScaleError.preparationFailed }
        let selectedEdgeCount = selection.selectedCount
        guard selectedEdgeCount > 0 else { throw EdgeScaleError.emptySelection }
        let (twiceEdges, overflow) = selectedEdgeCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw EdgeScaleError.allocationOverflow }
        let maximumAffected = min(mesh.vertices.count, twiceEdges)
        guard try estimatedPeakBytes(vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
                                     selectedEdgeCount: selectedEdgeCount,
                                     affectedVertexCount: maximumAffected) <= memoryLimit else {
            throw EdgeScaleError.workingMemoryLimitExceeded
        }
        let edgeIDs = selection.selectedEdgeIDs()
        guard edgeIDs.count == selectedEdgeCount else { throw EdgeScaleError.staleSource }
        var endpoints = Set<UInt32>()
        endpoints.reserveCapacity(maximumAffected)
        for edgeID in edgeIDs {
            guard table.edges.indices.contains(edgeID) else { throw EdgeScaleError.staleSource }
            endpoints.insert(table.edges[edgeID].key.low)
            endpoints.insert(table.edges[edgeID].key.high)
        }
        let vertexIDs = endpoints.sorted()
        guard try estimatedPeakBytes(vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
                                     selectedEdgeCount: selectedEdgeCount,
                                     affectedVertexCount: vertexIDs.count) <= memoryLimit else {
            throw EdgeScaleError.workingMemoryLimitExceeded
        }
        guard !failureInjector.shouldFail(.selectedPositionCopy) else {
            throw EdgeScaleError.preparationFailed
        }
        let safeTransform = transform.sanitized()
        guard safeTransform.isFinite, matrixIsFinite(safeTransform.modelMatrix),
              matrixIsFinite(safeTransform.inverseModelMatrix) else { throw EdgeScaleError.invalidTransform }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var starts: [SIMD3<Float>] = []
        starts.reserveCapacity(vertexIDs.count)
        for id in vertexIDs {
            guard Int(id) < mesh.vertices.count else { throw EdgeScaleError.staleSource }
            let position = mesh.vertices[Int(id)].position
            guard position.allFinite else { throw EdgeScaleError.staleSource }
            starts.append(position)
            minimum = simd_min(minimum, position); maximum = simd_max(maximum, position)
        }
        let pivotLocal = minimum * 0.5 + maximum * 0.5
        let pivotWorld = safeTransform.worldPosition(fromLocal: pivotLocal)
        guard pivotLocal.allFinite, pivotWorld.allFinite else { throw EdgeScaleError.invalidTransform }
        return EdgeScaleTransaction(
            id: transactionID, topologyID: mesh.runtime.topologyID,
            topologyRevision: mesh.runtime.topologyRevision, edgeTableFingerprint: table.fingerprint,
            sourceVertexRevision: mesh.runtime.revision, sourceVertexCount: mesh.vertices.count,
            sourceIndexCount: mesh.indices.count, selectionVersion: selection.version,
            selectedEdgeCount: selectedEdgeCount, affectedVertexCount: vertexIDs.count,
            selectedEdgeIDs: edgeIDs, vertexIDs: vertexIDs, startLocalPositions: starts,
            pivotLocal: pivotLocal, pivotWorld: pivotWorld, transform: safeTransform, handle: handle,
            projectSessionID: projectSessionID, projectGeneration: projectGeneration)
    }

    static func candidate(sourceMesh: EditableMesh, transaction: inout EdgeScaleTransaction,
                          factor: Float, profiler: PerformanceProfiler? = nil,
                          failureInjector: EdgeScaleFailureInjector = .init()) throws -> EditableMesh? {
        guard factor.isFinite, factor >= minimumFactor, factor <= maximumFactor else {
            throw EdgeScaleError.invalidFactor
        }
        transaction.update(factor: factor)
        guard factor != 1 else { return nil }
        guard transaction.topologyID == sourceMesh.runtime.topologyID,
              transaction.topologyRevision == sourceMesh.runtime.topologyRevision,
              transaction.vertexIDs.count == transaction.startLocalPositions.count else {
            throw EdgeScaleError.staleSource
        }
        guard !failureInjector.shouldFail(.candidateAllocation) else {
            throw EdgeScaleError.preparationFailed
        }
        let worldScale: SIMD3<Float>
        switch transaction.handle {
        case .xAxis: worldScale = SIMD3(factor, 1, 1)
        case .yAxis: worldScale = SIMD3(1, factor, 1)
        case .zAxis: worldScale = SIMD3(1, 1, factor)
        case .uniform: worldScale = SIMD3(repeating: factor)
        }
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(transaction.affectedVertexCount)
        for offset in transaction.vertexIDs.indices {
            let localOffset = transaction.startLocalPositions[offset] - transaction.pivotLocal
            let world4 = transaction.transform.modelMatrix * SIMD4<Float>(localOffset, 0)
            let worldOffset = SIMD3<Float>(world4.x, world4.y, world4.z)
            let scaledWorldOffset = worldOffset * worldScale
            let local4 = transaction.transform.inverseModelMatrix * SIMD4<Float>(scaledWorldOffset, 0)
            guard localOffset.allFinite, worldOffset.allFinite, scaledWorldOffset.allFinite,
                  local4.x.isFinite, local4.y.isFinite, local4.z.isFinite else {
                throw EdgeScaleError.precisionLoss
            }
            let scaledLocalOffset = SIMD3<Float>(local4.x, local4.y, local4.z)
            let local = transaction.pivotLocal + scaledLocalOffset
            let actual4 = transaction.transform.modelMatrix * SIMD4<Float>(local - transaction.pivotLocal, 0)
            let actualWorldOffset = SIMD3<Float>(actual4.x, actual4.y, actual4.z)
            let magnitude = max(1, max(max(maxAbs(worldOffset), maxAbs(scaledWorldOffset)),
                                       max(maxAbs(localOffset), maxAbs(scaledLocalOffset))))
            let tolerance = max(0.000_01, magnitude * Float.ulpOfOne * 48)
            let errorVector = actualWorldOffset - scaledWorldOffset
            guard local.allFinite, actualWorldOffset.allFinite, errorVector.allFinite,
                  maxAbs(errorVector).isFinite, maxAbs(errorVector) <= tolerance,
                  !failureInjector.shouldFail(.roundTripValidation) else {
                throw EdgeScaleError.precisionLoss
            }
            updates[Int(transaction.vertexIDs[offset])] = local
        }
        var candidate = sourceMesh
        let mutations = candidate.updatePositions(updates, profiler: profiler)
        guard !failureInjector.shouldFail(.normalRebuild), mutations.count <= updates.count,
              !failureInjector.shouldFail(.candidateValidation),
              !failureInjector.shouldFail(.candidatePostUpdate),
              !failureInjector.shouldFail(.rendererPreparation) else {
            throw EdgeScaleError.preparationFailed
        }
        return candidate
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int,
                                   selectedEdgeCount: Int, affectedVertexCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0, selectedEdgeCount >= 0,
              affectedVertexCount >= 0 else { throw EdgeScaleError.allocationOverflow }
        var bytes = 0
        func add(_ count: Int, _ stride: Int) throws {
            let (part, a) = count.multipliedReportingOverflow(by: stride)
            let (sum, b) = bytes.addingReportingOverflow(part)
            guard !a, !b else { throw EdgeScaleError.allocationOverflow }
            bytes = sum
        }
        try add(vertexCount, MemoryLayout<MeshVertex>.stride * 4)
        try add(indexCount, MemoryLayout<UInt32>.stride * 2)
        let triangles = indexCount / 3
        try add(triangles, MemoryLayout<TriangleReference>.stride * 2)
        try add(triangles, MemoryLayout<BVHNode>.stride * 4)
        try add(selectedEdgeCount, MemoryLayout<Int>.stride)
        try add(affectedVertexCount,
                MemoryLayout<UInt32>.stride + MemoryLayout<SIMD3<Float>>.stride * 2 + 96)
        return bytes
    }

    private static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }
    }

    private static func maxAbs(_ value: SIMD3<Float>) -> Float {
        max(abs(value.x), max(abs(value.y), abs(value.z)))
    }
}
