import Foundation
import simd

struct EdgeRotateTransaction: Equatable {
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
    let axis: SIMD3<Float>
    let projectSessionID: UUID
    let projectGeneration: MutationGeneration
    private(set) var accumulatedAngle: Float = 0

    mutating func update(accumulatedAngle: Float) { self.accumulatedAngle = accumulatedAngle }

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

enum EdgeRotateError: Error, Equatable, LocalizedError {
    case emptySelection, staleSource, invalidTransform, invalidAxis, nonFiniteAngle
    case precisionLoss, workingMemoryLimitExceeded, allocationOverflow, preparationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one edge before rotating."
        case .staleSource: "The selected edges changed before the rotation completed."
        case .invalidTransform: "The object transform cannot be inverted safely."
        case .invalidAxis: "The rotation axis is invalid."
        case .nonFiniteAngle: "The requested rotation is outside the supported numeric range."
        case .precisionLoss: "The rotation cannot be represented safely at the current scale and position."
        case .workingMemoryLimitExceeded: "The rotation would exceed the working-memory limit."
        case .allocationOverflow: "The rotation size calculation overflowed."
        case .preparationFailed: "The selected edge rotation could not be prepared safely."
        }
    }
}

enum EdgeRotateFailurePoint: Hashable {
    case sourceSnapshot, selectedPositionCopy, candidateAllocation
    case roundTripValidation, candidatePostUpdate
    case previewBVHPreparation, commitBVHPreparation, commitBoundary
}

struct EdgeRotateFailureInjector {
    let shouldFail: (EdgeRotateFailurePoint) -> Bool
    init(shouldFail: @escaping (EdgeRotateFailurePoint) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }
}

enum EdgeRotateGeometry {
    static let maximumWorkingBytes = 768 * 1_024 * 1_024
    static let minimumAxisLength: Float = 0.000_01

    static func begin(mesh: EditableMesh, table: MeshEdgeTable, selection: EdgeSelection,
                      transform: ObjectTransform, axis: SIMD3<Float>,
                      projectSessionID: UUID, projectGeneration: MutationGeneration,
                      transactionID: UUID = UUID(), memoryLimit: Int = maximumWorkingBytes,
                      failureInjector: EdgeRotateFailureInjector = .init()) throws -> EdgeRotateTransaction {
        guard table.matches(mesh), selection.matches(table) else { throw EdgeRotateError.staleSource }
        guard !failureInjector.shouldFail(.sourceSnapshot) else { throw EdgeRotateError.preparationFailed }
        let selectedEdgeCount = selection.selectedCount
        guard selectedEdgeCount > 0 else { throw EdgeRotateError.emptySelection }
        let (twiceEdges, overflow) = selectedEdgeCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw EdgeRotateError.allocationOverflow }
        let maximumAffected = min(mesh.vertices.count, twiceEdges)
        guard try estimatedPeakBytes(vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
                                     selectedEdgeCount: selectedEdgeCount,
                                     affectedVertexCount: maximumAffected) <= memoryLimit else {
            throw EdgeRotateError.workingMemoryLimitExceeded
        }

        let edgeIDs = selection.selectedEdgeIDs()
        guard edgeIDs.count == selectedEdgeCount else { throw EdgeRotateError.staleSource }
        var endpoints = Set<UInt32>()
        endpoints.reserveCapacity(maximumAffected)
        for edgeID in edgeIDs {
            guard table.edges.indices.contains(edgeID) else { throw EdgeRotateError.staleSource }
            endpoints.insert(table.edges[edgeID].key.low)
            endpoints.insert(table.edges[edgeID].key.high)
        }
        let vertexIDs = endpoints.sorted()
        guard try estimatedPeakBytes(vertexCount: mesh.vertices.count, indexCount: mesh.indices.count,
                                     selectedEdgeCount: selectedEdgeCount,
                                     affectedVertexCount: vertexIDs.count) <= memoryLimit else {
            throw EdgeRotateError.workingMemoryLimitExceeded
        }
        guard !failureInjector.shouldFail(.selectedPositionCopy) else {
            throw EdgeRotateError.preparationFailed
        }
        let safeTransform = transform.sanitized()
        guard safeTransform.isFinite, matrixIsFinite(safeTransform.modelMatrix),
              matrixIsFinite(safeTransform.inverseModelMatrix) else { throw EdgeRotateError.invalidTransform }
        let axisLengthSquared = simd_length_squared(axis)
        guard axis.allFinite, axisLengthSquared.isFinite,
              axisLengthSquared > minimumAxisLength * minimumAxisLength else {
            throw EdgeRotateError.invalidAxis
        }
        let normalizedAxis = axis / sqrt(axisLengthSquared)
        guard normalizedAxis.allFinite else { throw EdgeRotateError.invalidAxis }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var starts: [SIMD3<Float>] = []
        starts.reserveCapacity(vertexIDs.count)
        for id in vertexIDs {
            guard Int(id) < mesh.vertices.count else { throw EdgeRotateError.staleSource }
            let position = mesh.vertices[Int(id)].position
            guard position.allFinite else { throw EdgeRotateError.staleSource }
            starts.append(position)
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        let pivotLocal = minimum * 0.5 + maximum * 0.5
        let pivotWorld = safeTransform.worldPosition(fromLocal: pivotLocal)
        guard pivotLocal.allFinite, pivotWorld.allFinite else { throw EdgeRotateError.invalidTransform }
        return EdgeRotateTransaction(
            id: transactionID, topologyID: mesh.runtime.topologyID,
            topologyRevision: mesh.runtime.topologyRevision, edgeTableFingerprint: table.fingerprint,
            sourceVertexRevision: mesh.runtime.revision, sourceVertexCount: mesh.vertices.count,
            sourceIndexCount: mesh.indices.count, selectionVersion: selection.version,
            selectedEdgeCount: selectedEdgeCount, affectedVertexCount: vertexIDs.count,
            selectedEdgeIDs: edgeIDs, vertexIDs: vertexIDs, startLocalPositions: starts,
            pivotLocal: pivotLocal, pivotWorld: pivotWorld, transform: safeTransform,
            axis: normalizedAxis, projectSessionID: projectSessionID,
            projectGeneration: projectGeneration)
    }

    static func candidate(sourceMesh: EditableMesh, transaction: inout EdgeRotateTransaction,
                          accumulatedAngle: Float, profiler: PerformanceProfiler? = nil,
                          failureInjector: EdgeRotateFailureInjector = .init()) throws -> EditableMesh? {
        guard accumulatedAngle.isFinite else { throw EdgeRotateError.nonFiniteAngle }
        transaction.update(accumulatedAngle: accumulatedAngle)
        let canonicalAngle = accumulatedAngle.truncatingRemainder(dividingBy: Float.pi * 2)
        guard abs(canonicalAngle) > 1e-6 else { return nil }
        guard transaction.topologyID == sourceMesh.runtime.topologyID,
              transaction.topologyRevision == sourceMesh.runtime.topologyRevision,
              transaction.vertexIDs.count == transaction.startLocalPositions.count else {
            throw EdgeRotateError.staleSource
        }
        guard !failureInjector.shouldFail(.candidateAllocation) else {
            throw EdgeRotateError.preparationFailed
        }
        let rotation = simd_quatf(angle: canonicalAngle, axis: transaction.axis)
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(transaction.affectedVertexCount)
        for offset in transaction.vertexIDs.indices {
            let localOffset = transaction.startLocalPositions[offset] - transaction.pivotLocal
            let world4 = transaction.transform.modelMatrix * SIMD4<Float>(localOffset, 0)
            let worldOffset = SIMD3<Float>(world4.x, world4.y, world4.z)
            let rotatedWorldOffset = rotation.act(worldOffset)
            let local4 = transaction.transform.inverseModelMatrix * SIMD4<Float>(rotatedWorldOffset, 0)
            guard localOffset.allFinite, worldOffset.allFinite, rotatedWorldOffset.allFinite,
                  local4.x.isFinite, local4.y.isFinite, local4.z.isFinite else {
                throw EdgeRotateError.precisionLoss
            }
            let rotatedLocalOffset = SIMD3<Float>(local4.x, local4.y, local4.z)
            let local = transaction.pivotLocal + rotatedLocalOffset
            let actual4 = transaction.transform.modelMatrix * SIMD4<Float>(local - transaction.pivotLocal, 0)
            let actualWorldOffset = SIMD3<Float>(actual4.x, actual4.y, actual4.z)
            let magnitude = max(max(1, simd_length(worldOffset)),
                                max(simd_length(rotatedWorldOffset),
                                    max(simd_length(localOffset), simd_length(rotatedLocalOffset))))
            let tolerance = max(0.000_01, magnitude * Float.ulpOfOne * 48)
            guard local.allFinite, actualWorldOffset.allFinite,
                  simd_distance(actualWorldOffset, rotatedWorldOffset) <= tolerance,
                  !failureInjector.shouldFail(.roundTripValidation) else {
                throw EdgeRotateError.precisionLoss
            }
            updates[Int(transaction.vertexIDs[offset])] = local
        }
        var candidate = sourceMesh
        let mutations = candidate.updatePositions(updates, profiler: profiler)
        guard mutations.count <= updates.count,
              !failureInjector.shouldFail(.candidatePostUpdate) else {
            throw EdgeRotateError.preparationFailed
        }
        return candidate
    }

    static func estimatedPeakBytes(vertexCount: Int, indexCount: Int,
                                   selectedEdgeCount: Int, affectedVertexCount: Int) throws -> Int {
        guard vertexCount >= 0, indexCount >= 0, selectedEdgeCount >= 0,
              affectedVertexCount >= 0 else { throw EdgeRotateError.allocationOverflow }
        var bytes = 0
        func add(_ count: Int, _ stride: Int) throws {
            let (part, a) = count.multipliedReportingOverflow(by: stride)
            let (sum, b) = bytes.addingReportingOverflow(part)
            guard !a, !b else { throw EdgeRotateError.allocationOverflow }
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
}
