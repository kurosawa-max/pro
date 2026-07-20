import Foundation
import simd

enum LinearArrayAxis: String, CaseIterable, Identifiable {
    case x = "X"
    case y = "Y"
    case z = "Z"

    var id: Self { self }

    var componentIndex: Int {
        switch self {
        case .x: 0
        case .y: 1
        case .z: 2
        }
    }

    var localUnitVector: SIMD3<Double> {
        var value = SIMD3<Double>.zero
        value[componentIndex] = 1
        return value
    }
}

struct MeshLinearArrayOptions: Equatable {
    var axis: LinearArrayAxis = .x
    var count = 2
    var spacingMillimeters = 10.0
}

struct MeshLinearArrayEstimate: Equatable {
    let axis: LinearArrayAxis
    let count: Int
    let spacingMillimeters: Double
    let totalSpanMillimeters: Double
    let originalVertexCount: Int
    let resultingVertexCount: Int
    let originalTriangleCount: Int
    let resultingTriangleCount: Int
    let sourceComponentCount: Int
    let resultingComponentCount: Int
    let sourceBoundaryEdgeCount: Int
    let resultingBoundaryEdgeCount: Int
    let sourceLocalBounds: AxisAlignedBoundingBox
    let resultLocalBounds: AxisAlignedBoundingBox
    let sourceWorldBounds: AxisAlignedBoundingBox
    let resultWorldBounds: AxisAlignedBoundingBox
    let actualSpacingToleranceMillimeters: Double
    let estimatedWorkingByteCount: Int
}

struct MeshLinearArraySourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: TopologyEditChangeVersion
    let transformChangeVersion: TopologyEditChangeVersion
    let transform: ObjectTransform
    let options: MeshLinearArrayOptions
    let sourceVertexCount: Int
    let sourceTriangleCount: Int
    let sourceComponentCount: Int
    let sourceBoundaryEdgeCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let totalSpanMillimeters: Double
    let analysisFingerprint: UInt64

    func matchesRuntimeIdentity(
        mesh: EditableMesh,
        transform: ObjectTransform,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion,
        options: MeshLinearArrayOptions
    ) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && vertexRevision == mesh.runtime.revision
            && self.meshChangeVersion == meshChangeVersion
            && self.transformChangeVersion == transformChangeVersion
            && self.transform == transform.sanitized()
            && self.options == options
            && sourceVertexCount == mesh.vertices.count
            && sourceTriangleCount == mesh.indices.count / 3
    }
}

struct MeshLinearArrayPreview: Equatable {
    let options: MeshLinearArrayOptions
    let estimate: MeshLinearArrayEstimate
    let source: MeshLinearArraySourceKey
}

struct MeshLinearArrayResult: Equatable {
    let mesh: EditableMesh
    let estimate: MeshLinearArrayEstimate
    let analysisFingerprint: UInt64
}

enum MeshLinearArrayError: Error, Equatable, LocalizedError {
    case invalidMesh
    case nonFiniteValue
    case degenerateTriangle
    case duplicateTriangle
    case nonManifoldEdge
    case windingConflict
    case isolatedVertex
    case invalidCount
    case invalidSpacing
    case totalSpanOverflow
    case vertexLimitExceeded
    case triangleLimitExceeded
    case indexOverflow
    case arithmeticOverflow
    case workingMemoryLimitExceeded
    case worldDirectionFailure
    case inverseTransformFailure
    case spacingRoundTripFailure
    case copyWouldCollapseTriangle
    case copyWouldCreateDuplicateGeometry
    case componentCountFailure
    case boundaryCountFailure
    case boundsFailure
    case validationFailed
    case stalePreview
    case operationInProgress
    case activeEdit
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidMesh: "Linear Array requires a nonempty, valid triangle mesh."
        case .nonFiniteValue: "Linear Array requires finite vertex positions, normals, and Transform values."
        case .degenerateTriangle: "The source contains degenerate triangles. Review Mesh Diagnostics or run Mesh Cleanup first."
        case .duplicateTriangle: "The source contains duplicate triangles. Review Mesh Diagnostics or run Mesh Cleanup first."
        case .nonManifoldEdge: "Linear Array requires manifold source edges. Open boundary edges are supported."
        case .windingConflict: "Linear Array requires consistent triangle winding."
        case .isolatedVertex: "Linear Array requires every vertex to be referenced by a triangle."
        case .invalidCount: "Count must include the source and be between 2 and 256."
        case .invalidSpacing: "Spacing must be finite and between 0.001 and 1000 millimeters in either direction."
        case .totalSpanOverflow: "The requested Array span is not finite."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Linear Array size calculation overflowed."
        case .workingMemoryLimitExceeded: "Linear Array would exceed the 768 MiB working-memory limit."
        case .worldDirectionFailure: "The selected local axis cannot be converted to a finite world direction."
        case .inverseTransformFailure: "The current Object Transform cannot be inverted safely."
        case .spacingRoundTripFailure: "The requested spacing cannot be represented accurately with the current Transform and coordinate magnitude."
        case .copyWouldCollapseTriangle: "Float conversion would collapse a copied triangle. Increase spacing or reduce coordinate magnitude."
        case .copyWouldCreateDuplicateGeometry: "The requested Array would create exactly duplicate triangle geometry."
        case .componentCountFailure: "The result did not preserve the expected detached component count."
        case .boundaryCountFailure: "The result did not preserve the expected boundary topology."
        case .boundsFailure: "Linear Array could not produce finite, consistent bounds."
        case .validationFailed: "The Linear Array result failed geometry validation."
        case .stalePreview: "The mesh, Transform, axis, Count, or Spacing changed. Recalculate the preview."
        case .operationInProgress: "Another topology operation is already running."
        case .activeEdit: "Finish or prepare the active edit before applying Linear Array."
        case .unavailable: "Linear Array is unavailable during the current operation."
        }
    }
}

enum MeshLinearArray {
    static let minimumCount = 2
    static let maximumCount = 256
    static let minimumSpacingMillimeters = 0.001
    static let maximumSpacingMillimeters = 1_000.0
    static let maximumVertices = MeshCleanup.maximumVertices
    static let maximumTriangles = MeshCleanup.maximumTriangles
    static let maximumWorkingBytes = MeshCleanup.maximumWorkingBytes

    private struct PositionKey: Hashable, Comparable {
        let x: UInt32
        let y: UInt32
        let z: UInt32

        init(_ position: SIMD3<Float>) {
            x = position.x == 0 ? 0 : position.x.bitPattern
            y = position.y == 0 ? 0 : position.y.bitPattern
            z = position.z == 0 ? 0 : position.z.bitPattern
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    private struct PositionTriangleKey: Hashable {
        let first: PositionKey
        let second: PositionKey
        let third: PositionKey

        init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let ordered = [PositionKey(a), PositionKey(b), PositionKey(c)].sorted()
            first = ordered[0]
            second = ordered[1]
            third = ordered[2]
        }
    }

    static func makePreview(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshLinearArrayOptions,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion
    ) throws -> MeshLinearArrayPreview {
        let plan = try makePlan(mesh: mesh, transform: transform, options: options)
        let estimate = plan.estimate
        return MeshLinearArrayPreview(
            options: options,
            estimate: estimate,
            source: MeshLinearArraySourceKey(
                topologyID: mesh.runtime.topologyID,
                topologyRevision: mesh.runtime.topologyRevision,
                vertexRevision: mesh.runtime.revision,
                meshChangeVersion: meshChangeVersion,
                transformChangeVersion: transformChangeVersion,
                transform: transform.sanitized(),
                options: options,
                sourceVertexCount: estimate.originalVertexCount,
                sourceTriangleCount: estimate.originalTriangleCount,
                sourceComponentCount: estimate.sourceComponentCount,
                sourceBoundaryEdgeCount: estimate.sourceBoundaryEdgeCount,
                resultingVertexCount: estimate.resultingVertexCount,
                resultingTriangleCount: estimate.resultingTriangleCount,
                totalSpanMillimeters: estimate.totalSpanMillimeters,
                analysisFingerprint: plan.fingerprint))
    }

    static func estimate(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshLinearArrayOptions
    ) throws -> MeshLinearArrayEstimate {
        try makePlan(mesh: mesh, transform: transform, options: options).estimate
    }

    static func array(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshLinearArrayOptions
    ) throws -> MeshLinearArrayResult {
        let plan = try makePlan(mesh: mesh, transform: transform, options: options)
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(plan.estimate.resultingVertexCount)
        for copyIndex in 0..<options.count {
            let base = copyIndex * mesh.vertices.count
            for sourceVertexID in mesh.vertices.indices {
                let position = plan.positions[base + sourceVertexID]
                vertices.append(MeshVertex(position: position, normal: mesh.vertices[sourceVertexID].normal))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(plan.estimate.resultingTriangleCount * 3)
        for copyIndex in 0..<options.count {
            let vertexOffset = try multiply(copyIndex, mesh.vertices.count)
            for sourceIndex in mesh.indices {
                let mapped = try add(vertexOffset, Int(sourceIndex))
                guard mapped <= Int(UInt32.max) else { throw MeshLinearArrayError.indexOverflow }
                indices.append(UInt32(mapped))
            }
        }

        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        try validateResult(result, source: mesh, transform: transform, plan: plan, options: options)
        return MeshLinearArrayResult(
            mesh: result,
            estimate: plan.estimate,
            analysisFingerprint: plan.fingerprint)
    }

    fileprivate struct Plan {
        let positions: [SIMD3<Float>]
        let worldDirection: SIMD3<Double>
        let estimate: MeshLinearArrayEstimate
        let fingerprint: UInt64
    }

    private struct DoubleTransform {
        let model: simd_double4x4
        let inverse: simd_double4x4

        init(_ transform: ObjectTransform) throws {
            guard transform.isFinite else { throw MeshLinearArrayError.nonFiniteValue }
            let floatModel = transform.sanitized().modelMatrix
            model = simd_double4x4(
                Self.double(floatModel.columns.0),
                Self.double(floatModel.columns.1),
                Self.double(floatModel.columns.2),
                Self.double(floatModel.columns.3))
            inverse = model.inverse
            guard Self.isFinite(model), Self.isFinite(inverse) else {
                throw MeshLinearArrayError.inverseTransformFailure
            }
        }

        func position(_ point: SIMD3<Double>, using matrix: simd_double4x4) throws -> SIMD3<Double> {
            let value = matrix * SIMD4<Double>(point, 1)
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
                  value.w.isFinite, abs(value.w) > Double.leastNonzeroMagnitude else {
                throw MeshLinearArrayError.inverseTransformFailure
            }
            return SIMD3<Double>(value.x, value.y, value.z) / value.w
        }

        private static func isFinite(_ matrix: simd_double4x4) -> Bool {
            [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].allSatisfy {
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
            }
        }

        private static func double(_ value: SIMD4<Float>) -> SIMD4<Double> {
            SIMD4<Double>(Double(value.x), Double(value.y), Double(value.z), Double(value.w))
        }
    }

    private static func makePlan(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshLinearArrayOptions
    ) throws -> Plan {
        guard transform.isFinite else { throw MeshLinearArrayError.nonFiniteValue }
        guard options.count >= minimumCount, options.count <= maximumCount else {
            throw MeshLinearArrayError.invalidCount
        }
        let spacingMagnitude = abs(options.spacingMillimeters)
        guard options.spacingMillimeters.isFinite,
              spacingMagnitude >= minimumSpacingMillimeters,
              spacingMagnitude <= maximumSpacingMillimeters else {
            throw MeshLinearArrayError.invalidSpacing
        }
        let totalSpan = options.spacingMillimeters * Double(options.count - 1)
        guard totalSpan.isFinite else { throw MeshLinearArrayError.totalSpanOverflow }

        let topology = try validateSource(mesh)
        let resultingVertices = try multiply(mesh.vertices.count, options.count)
        let resultingTriangles = try multiply(topology.triangleCount, options.count)
        let resultingComponents = try multiply(topology.connectedComponentCount, options.count)
        let resultingBoundaryEdges = try multiply(topology.boundaryEdgeCount, options.count)
        guard resultingVertices <= maximumVertices else { throw MeshLinearArrayError.vertexLimitExceeded }
        guard resultingTriangles <= maximumTriangles else { throw MeshLinearArrayError.triangleLimitExceeded }
        guard resultingVertices <= Int(UInt32.max) else { throw MeshLinearArrayError.indexOverflow }
        let workingBytes = try estimatedWorkingBytes(
            sourceVertices: mesh.vertices.count,
            sourceTriangles: topology.triangleCount,
            uniqueEdges: topology.uniqueEdgeCount,
            resultingVertices: resultingVertices,
            resultingTriangles: resultingTriangles)
        guard workingBytes <= maximumWorkingBytes else {
            throw MeshLinearArrayError.workingMemoryLimitExceeded
        }

        let matrix = try DoubleTransform(transform)
        let rawDirection4 = matrix.model * SIMD4<Double>(options.axis.localUnitVector, 0)
        let rawDirection = SIMD3<Double>(rawDirection4.x, rawDirection4.y, rawDirection4.z)
        let directionLength = simd_length(rawDirection)
        guard directionLength.isFinite, directionLength > Double.leastNonzeroMagnitude else {
            throw MeshLinearArrayError.worldDirectionFailure
        }
        let worldDirection = rawDirection / directionLength
        guard worldDirection.x.isFinite, worldDirection.y.isFinite, worldDirection.z.isFinite else {
            throw MeshLinearArrayError.worldDirectionFailure
        }

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(resultingVertices)
        var sourceWorldBounds = AxisAlignedBoundingBox()
        var resultWorldBounds = AxisAlignedBoundingBox()
        var resultLocalBounds = AxisAlignedBoundingBox()
        var maximumWorldMagnitude = 0.0
        for copyIndex in 0..<options.count {
            let displacement = worldDirection * (options.spacingMillimeters * Double(copyIndex))
            guard displacement.x.isFinite, displacement.y.isFinite, displacement.z.isFinite else {
                throw MeshLinearArrayError.totalSpanOverflow
            }
            for sourceVertex in mesh.vertices {
                let sourceLocal = DiagnosticMath.double(sourceVertex.position)
                let sourceWorld = try matrix.position(sourceLocal, using: matrix.model)
                let copyWorld = sourceWorld + displacement
                let localDouble = try matrix.position(copyWorld, using: matrix.inverse)
                let stored = copyIndex == 0 ? sourceVertex.position : DiagnosticMath.float(localDouble)
                guard stored.allFinite else { throw MeshLinearArrayError.spacingRoundTripFailure }
                let actualWorld = try matrix.position(DiagnosticMath.double(stored), using: matrix.model)
                guard actualWorld.x.isFinite, actualWorld.y.isFinite, actualWorld.z.isFinite else {
                    throw MeshLinearArrayError.spacingRoundTripFailure
                }
                positions.append(stored)
                resultLocalBounds.include(stored)
                resultWorldBounds.include(DiagnosticMath.float(actualWorld))
                if copyIndex == 0 { sourceWorldBounds.include(DiagnosticMath.float(actualWorld)) }
                maximumWorldMagnitude = max(
                    maximumWorldMagnitude,
                    max(abs(actualWorld.x), max(abs(actualWorld.y), abs(actualWorld.z))))
            }
        }
        guard positions.count == resultingVertices,
              resultLocalBounds.isFinite, sourceWorldBounds.isFinite, resultWorldBounds.isFinite else {
            throw MeshLinearArrayError.boundsFailure
        }
        try validatePlannedGeometry(positions: positions, source: mesh, count: options.count)
        let tolerance = try spacingTolerance(
            spacing: spacingMagnitude,
            maximumWorldMagnitude: maximumWorldMagnitude,
            totalSpan: abs(totalSpan),
            transform: transform)
        try validateStoredSpacing(
            positions: positions,
            sourceVertexCount: mesh.vertices.count,
            count: options.count,
            requestedSpacing: options.spacingMillimeters,
            worldDirection: worldDirection,
            matrix: matrix,
            tolerance: tolerance)

        let estimate = MeshLinearArrayEstimate(
            axis: options.axis,
            count: options.count,
            spacingMillimeters: options.spacingMillimeters,
            totalSpanMillimeters: totalSpan,
            originalVertexCount: mesh.vertices.count,
            resultingVertexCount: resultingVertices,
            originalTriangleCount: topology.triangleCount,
            resultingTriangleCount: resultingTriangles,
            sourceComponentCount: topology.connectedComponentCount,
            resultingComponentCount: resultingComponents,
            sourceBoundaryEdgeCount: topology.boundaryEdgeCount,
            resultingBoundaryEdgeCount: resultingBoundaryEdges,
            sourceLocalBounds: mesh.bounds,
            resultLocalBounds: resultLocalBounds,
            sourceWorldBounds: sourceWorldBounds,
            resultWorldBounds: resultWorldBounds,
            actualSpacingToleranceMillimeters: tolerance,
            estimatedWorkingByteCount: workingBytes)
        return Plan(
            positions: positions,
            worldDirection: worldDirection,
            estimate: estimate,
            fingerprint: fingerprint(mesh: mesh, options: options, estimate: estimate, positions: positions))
    }

    private static func validateSource(_ mesh: EditableMesh) throws -> MeshTopologyReport {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3) else { throw MeshLinearArrayError.invalidMesh }
        guard mesh.vertices.count <= maximumVertices else { throw MeshLinearArrayError.vertexLimitExceeded }
        guard mesh.indices.count / 3 <= maximumTriangles else { throw MeshLinearArrayError.triangleLimitExceeded }
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        guard !topology.hasInvalidStructure, topology.invalidIndexTriangleCount == 0 else {
            throw MeshLinearArrayError.invalidMesh
        }
        guard topology.nonFiniteVertexCount == 0 else { throw MeshLinearArrayError.nonFiniteValue }
        guard topology.degenerateTriangleCount == 0 else { throw MeshLinearArrayError.degenerateTriangle }
        guard topology.duplicateTriangleCount == 0 else { throw MeshLinearArrayError.duplicateTriangle }
        guard let hasGeometricDuplicates = MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(mesh) else {
            throw MeshLinearArrayError.invalidMesh
        }
        guard !hasGeometricDuplicates else { throw MeshLinearArrayError.duplicateTriangle }
        guard topology.nonManifoldEdgeCount == 0 else { throw MeshLinearArrayError.nonManifoldEdge }
        guard topology.inconsistentWindingEdgeCount == 0 else { throw MeshLinearArrayError.windingConflict }
        guard topology.isolatedVertexCount == 0 else { throw MeshLinearArrayError.isolatedVertex }
        guard mesh.bounds.isFinite else { throw MeshLinearArrayError.boundsFailure }
        return topology
    }

    private static func validatePlannedGeometry(
        positions: [SIMD3<Float>],
        source: EditableMesh,
        count: Int
    ) throws {
        guard positions.count == source.vertices.count * count else {
            throw MeshLinearArrayError.validationFailed
        }
        var triangles = Set<PositionTriangleKey>()
        triangles.reserveCapacity(source.indices.count / 3 * count)
        let areaFloor = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: source)
        for copyIndex in 0..<count {
            let base = copyIndex * source.vertices.count
            var storedSourceByPosition: [PositionKey: PositionKey] = [:]
            storedSourceByPosition.reserveCapacity(source.vertices.count)
            for sourceID in source.vertices.indices {
                let sourceKey = PositionKey(source.vertices[sourceID].position)
                let resultKey = PositionKey(positions[base + sourceID])
                if let previousSource = storedSourceByPosition[resultKey], previousSource != sourceKey {
                    throw MeshLinearArrayError.spacingRoundTripFailure
                }
                storedSourceByPosition[resultKey] = sourceKey
            }
            for faceID in 0..<(source.indices.count / 3) {
                let offset = faceID * 3
                let ids = [
                    Int(source.indices[offset]),
                    Int(source.indices[offset + 1]),
                    Int(source.indices[offset + 2]),
                ]
                guard ids.allSatisfy(source.vertices.indices.contains) else {
                    throw MeshLinearArrayError.invalidMesh
                }
                let points = ids.map { positions[base + $0] }
                let sourceArea = twiceArea(mesh: source, faceID: faceID)
                let resultArea = DiagnosticMath.twiceArea(points[0], points[1], points[2])
                let tolerance = max(areaFloor, sourceArea * 1.0e-4)
                guard resultArea.isFinite, resultArea > areaFloor,
                      abs(resultArea - sourceArea) <= tolerance else {
                    throw MeshLinearArrayError.copyWouldCollapseTriangle
                }
                guard triangles.insert(PositionTriangleKey(
                    points[0], points[1], points[2]
                )).inserted else {
                    throw MeshLinearArrayError.copyWouldCreateDuplicateGeometry
                }
            }
        }
    }

    private static func validateStoredSpacing(
        positions: [SIMD3<Float>],
        sourceVertexCount: Int,
        count: Int,
        requestedSpacing: Double,
        worldDirection: SIMD3<Double>,
        matrix: DoubleTransform,
        tolerance: Double
    ) throws {
        guard sourceVertexCount > 0, positions.count == sourceVertexCount * count else {
            throw MeshLinearArrayError.validationFailed
        }
        for copyIndex in 0..<(count - 1) {
            let firstBase = copyIndex * sourceVertexCount
            let secondBase = (copyIndex + 1) * sourceVertexCount
            var anyDistinct = false
            for sourceVertexID in 0..<sourceVertexCount {
                let first = try matrix.position(
                    DiagnosticMath.double(positions[firstBase + sourceVertexID]), using: matrix.model)
                let second = try matrix.position(
                    DiagnosticMath.double(positions[secondBase + sourceVertexID]), using: matrix.model)
                let delta = second - first
                let projection = simd_dot(delta, worldDirection)
                let perpendicular = delta - worldDirection * projection
                let distance = simd_length(delta)
                guard projection.isFinite, distance.isFinite,
                      simd_length(perpendicular).isFinite,
                      abs(projection - requestedSpacing) <= tolerance,
                      abs(distance - abs(requestedSpacing)) <= tolerance,
                      simd_length(perpendicular) <= tolerance else {
                    throw MeshLinearArrayError.spacingRoundTripFailure
                }
                if distance > tolerance { anyDistinct = true }
            }
            guard anyDistinct else { throw MeshLinearArrayError.spacingRoundTripFailure }
        }
    }

    private static func validateResult(
        _ result: EditableMesh,
        source: EditableMesh,
        transform: ObjectTransform,
        plan: Plan,
        options: MeshLinearArrayOptions
    ) throws {
        guard result.vertices.count == plan.estimate.resultingVertexCount,
              result.indices.count == plan.estimate.resultingTriangleCount * 3,
              result.bounds == plan.estimate.resultLocalBounds,
              result.hasCachedAdjacency,
              result.vertices.allSatisfy({ vertex in
                  vertex.position.allFinite && vertex.normal.allFinite
                      && abs(simd_length(vertex.normal) - 1) <= 0.001
              }) else { throw MeshLinearArrayError.validationFailed }
        guard Array(result.vertices.prefix(source.vertices.count)).map(\.position)
                == source.vertices.map(\.position),
              Array(result.indices.prefix(source.indices.count)) == source.indices else {
            throw MeshLinearArrayError.validationFailed
        }
        let topology = MeshTopologyDiagnostics.analyze(result)
        guard !topology.hasInvalidStructure,
              topology.invalidIndexTriangleCount == 0,
              topology.nonFiniteVertexCount == 0,
              topology.nonManifoldEdgeCount == 0,
              topology.inconsistentWindingEdgeCount == 0,
              topology.isolatedVertexCount == 0 else {
            throw MeshLinearArrayError.validationFailed
        }
        guard topology.degenerateTriangleCount == 0 else {
            throw MeshLinearArrayError.copyWouldCollapseTriangle
        }
        guard topology.duplicateTriangleCount == 0 else {
            throw MeshLinearArrayError.copyWouldCreateDuplicateGeometry
        }
        guard MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(result) == false else {
            throw MeshLinearArrayError.copyWouldCreateDuplicateGeometry
        }
        guard topology.connectedComponentCount == plan.estimate.resultingComponentCount else {
            throw MeshLinearArrayError.componentCountFailure
        }
        guard topology.boundaryEdgeCount == plan.estimate.resultingBoundaryEdgeCount else {
            throw MeshLinearArrayError.boundaryCountFailure
        }
        for copyIndex in 0..<options.count {
            let vertexOffset = copyIndex * source.vertices.count
            let indexOffset = copyIndex * source.indices.count
            for sourceOffset in source.indices.indices {
                let expected = UInt32(vertexOffset + Int(source.indices[sourceOffset]))
                guard result.indices[indexOffset + sourceOffset] == expected else {
                    throw MeshLinearArrayError.validationFailed
                }
            }
        }
        let areaFloor = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: result)
        for copyIndex in 0..<options.count {
            for faceID in 0..<(source.indices.count / 3) {
                let sourceArea = twiceArea(mesh: source, faceID: faceID)
                let resultArea = twiceArea(
                    mesh: result,
                    faceID: copyIndex * (source.indices.count / 3) + faceID)
                let tolerance = max(areaFloor, sourceArea * 1.0e-4)
                guard sourceArea.isFinite, resultArea.isFinite,
                      abs(resultArea - sourceArea) <= tolerance else {
                    throw MeshLinearArrayError.copyWouldCollapseTriangle
                }
            }
        }
        let doubleTransform = try DoubleTransform(transform)
        try validateStoredSpacing(
            positions: result.vertices.map(\.position),
            sourceVertexCount: source.vertices.count,
            count: options.count,
            requestedSpacing: options.spacingMillimeters,
            worldDirection: plan.worldDirection,
            matrix: doubleTransform,
            tolerance: plan.estimate.actualSpacingToleranceMillimeters)
        var worldBounds = AxisAlignedBoundingBox()
        for vertex in result.vertices {
            let world = try doubleTransform.position(DiagnosticMath.double(vertex.position), using: doubleTransform.model)
            worldBounds.include(DiagnosticMath.float(world))
        }
        guard worldBounds == plan.estimate.resultWorldBounds else {
            throw MeshLinearArrayError.boundsFailure
        }
    }

    private static func twiceArea(mesh: EditableMesh, faceID: Int) -> Double {
        let offset = faceID * 3
        guard offset >= 0, offset + 2 < mesh.indices.count else { return .nan }
        let ids = [
            Int(mesh.indices[offset]),
            Int(mesh.indices[offset + 1]),
            Int(mesh.indices[offset + 2]),
        ]
        guard ids.allSatisfy(mesh.vertices.indices.contains) else { return .nan }
        return DiagnosticMath.twiceArea(
            mesh.vertices[ids[0]].position,
            mesh.vertices[ids[1]].position,
            mesh.vertices[ids[2]].position)
    }

    static func estimatedWorkingBytes(
        sourceVertices: Int,
        sourceTriangles: Int,
        uniqueEdges: Int,
        resultingVertices: Int,
        resultingTriangles: Int
    ) throws -> Int {
        try add(
            try multiply(sourceVertices, 96),
            try multiply(sourceTriangles, 96),
            try multiply(uniqueEdges, 128),
            try multiply(resultingVertices, 128),
            try multiply(resultingTriangles, 96))
    }

    private static func spacingTolerance(
        spacing: Double,
        maximumWorldMagnitude: Double,
        totalSpan: Double,
        transform: ObjectTransform
    ) throws -> Double {
        let safeScale = transform.sanitized().scale
        let maximumScale = Double(max(safeScale.x, safeScale.y, safeScale.z))
        let precisionFloor = max(max(maximumWorldMagnitude, totalSpan), max(maximumScale, 1))
            * Double(Float.ulpOfOne) * 8
        let requestedFloor = spacing * 1.0e-5
        let cap = spacing * 0.01
        let required = max(1.0e-9, precisionFloor, requestedFloor)
        guard required.isFinite, cap.isFinite, required <= cap else {
            throw MeshLinearArrayError.spacingRoundTripFailure
        }
        return required
    }

    private static func fingerprint(
        mesh: EditableMesh,
        options: MeshLinearArrayOptions,
        estimate: MeshLinearArrayEstimate,
        positions: [SIMD3<Float>]
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) { hash ^= value; hash &*= 1_099_511_628_211 }
        mix(UInt64(options.axis.componentIndex))
        mix(UInt64(options.count))
        mix(options.spacingMillimeters.bitPattern)
        for vertex in mesh.vertices {
            mix(UInt64(vertex.position.x.bitPattern))
            mix(UInt64(vertex.position.y.bitPattern))
            mix(UInt64(vertex.position.z.bitPattern))
        }
        for index in mesh.indices { mix(UInt64(index)) }
        for position in positions {
            mix(UInt64(position.x.bitPattern))
            mix(UInt64(position.y.bitPattern))
            mix(UInt64(position.z.bitPattern))
        }
        mix(UInt64(estimate.resultingVertexCount))
        mix(UInt64(estimate.resultingTriangleCount))
        mix(UInt64(estimate.resultingComponentCount))
        mix(UInt64(estimate.resultingBoundaryEdgeCount))
        return hash
    }

    private static func add(_ values: Int...) throws -> Int {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw MeshLinearArrayError.arithmeticOverflow }
            return result
        }
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw MeshLinearArrayError.arithmeticOverflow }
        return result
    }
}
