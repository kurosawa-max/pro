import Foundation
import simd

enum RadialArrayDistribution: String, CaseIterable, Identifiable {
    case fullCircle = "Full Circle"
    case openArc = "Open Arc"

    var id: Self { self }
}

enum RadialArrayDirection: String, CaseIterable, Identifiable {
    case positive = "Positive"
    case negative = "Negative"

    var id: Self { self }
    var sign: Double { self == .positive ? 1 : -1 }
}

struct MeshRadialArrayOptions: Equatable {
    var axis: LinearArrayAxis = .z
    var distribution: RadialArrayDistribution = .fullCircle
    var count = 6
    var direction: RadialArrayDirection = .positive
    var sweepDegrees = 180.0

    var effectiveSweepDegrees: Double {
        switch distribution {
        case .fullCircle:
            direction.sign * 360
        case .openArc:
            sweepDegrees
        }
    }

    var stepDegrees: Double {
        switch distribution {
        case .fullCircle:
            effectiveSweepDegrees / Double(count)
        case .openArc:
            effectiveSweepDegrees / Double(count - 1)
        }
    }

    func angleDegrees(copyIndex: Int) -> Double {
        stepDegrees * Double(copyIndex)
    }
}

struct MeshRadialArrayEstimate: Equatable {
    let axis: LinearArrayAxis
    let distribution: RadialArrayDistribution
    let count: Int
    let effectiveSweepDegrees: Double
    let stepDegrees: Double
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
    let maximumRadiusErrorMillimeters: Double
    let maximumAxialErrorMillimeters: Double
    let maximumAngularErrorDegrees: Double
    let maximumChordErrorMillimeters: Double
    let validationToleranceMillimeters: Double
    let estimatedWorkingByteCount: Int
}

struct MeshRadialArraySourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: TopologyEditChangeVersion
    let transformChangeVersion: TopologyEditChangeVersion
    let transform: ObjectTransform
    let options: MeshRadialArrayOptions
    let sourceVertexCount: Int
    let sourceTriangleCount: Int
    let sourceComponentCount: Int
    let sourceBoundaryEdgeCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let analysisFingerprint: UInt64

    func matchesRuntimeIdentity(
        mesh: EditableMesh,
        transform: ObjectTransform,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion,
        options: MeshRadialArrayOptions
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

struct MeshRadialArrayPreview: Equatable {
    let options: MeshRadialArrayOptions
    let estimate: MeshRadialArrayEstimate
    let source: MeshRadialArraySourceKey
}

struct MeshRadialArrayResult: Equatable {
    let mesh: EditableMesh
    let estimate: MeshRadialArrayEstimate
    let analysisFingerprint: UInt64
}

enum MeshRadialArrayError: Error, Equatable, LocalizedError {
    case invalidMesh
    case nonFiniteValue
    case degenerateTriangle
    case duplicateTriangle
    case nonManifoldEdge
    case windingConflict
    case isolatedVertex
    case invalidCount
    case invalidSweep
    case vertexLimitExceeded
    case triangleLimitExceeded
    case indexOverflow
    case arithmeticOverflow
    case workingMemoryLimitExceeded
    case worldAxisFailure
    case inverseTransformFailure
    case noRadialExtent
    case rotationRoundTripFailure
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
        case .invalidMesh: "Radial Array requires a nonempty, valid triangle mesh."
        case .nonFiniteValue: "Radial Array requires finite vertex positions, normals, Transform, and parameters."
        case .degenerateTriangle: "The source contains degenerate triangles. Review Mesh Diagnostics or run Mesh Cleanup first."
        case .duplicateTriangle: "The source contains duplicate triangles. Review Mesh Diagnostics or run Mesh Cleanup first."
        case .nonManifoldEdge: "Radial Array requires manifold source edges. Open boundary edges are supported."
        case .windingConflict: "Radial Array requires consistent triangle winding."
        case .isolatedVertex: "Radial Array requires every vertex to be referenced by a triangle."
        case .invalidCount: "Count must include the source and be between 2 and 256."
        case .invalidSweep: "Open Arc sweep must be finite and from -359.99 to -0.01 degrees or from 0.01 to 359.99 degrees."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Radial Array size calculation overflowed."
        case .workingMemoryLimitExceeded: "Radial Array would exceed the 768 MiB working-memory limit."
        case .worldAxisFailure: "The selected local axis cannot be converted to a finite world axis."
        case .inverseTransformFailure: "The current Object Transform cannot be inverted safely."
        case .noRadialExtent: "Every source vertex lies on the selected rotation axis. Choose another axis or source mesh."
        case .rotationRoundTripFailure: "The requested rotation cannot be represented accurately with the current Transform and coordinate magnitude."
        case .copyWouldCollapseTriangle: "Float conversion would collapse or distort a copied triangle."
        case .copyWouldCreateDuplicateGeometry: "The requested Radial Array would create exactly duplicate triangle geometry."
        case .componentCountFailure: "The result did not preserve the expected detached component count."
        case .boundaryCountFailure: "The result did not preserve the expected boundary topology."
        case .boundsFailure: "Radial Array could not produce finite, consistent bounds."
        case .validationFailed: "The Radial Array result failed geometry validation."
        case .stalePreview: "The mesh, Transform, axis, distribution, Count, direction, or sweep changed. Recalculate the preview."
        case .operationInProgress: "Another topology operation is already running."
        case .activeEdit: "Finish or prepare the active edit before applying Radial Array."
        case .unavailable: "Radial Array is unavailable during the current operation."
        }
    }
}

enum MeshRadialArray {
    static let minimumCount = 2
    static let maximumCount = 256
    static let minimumSweepDegrees = 0.01
    static let maximumSweepDegrees = 359.99
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

    fileprivate struct Plan {
        let positions: [SIMD3<Float>]
        let worldPivot: SIMD3<Double>
        let worldAxis: SIMD3<Double>
        let anglesRadians: [Double]
        let estimate: MeshRadialArrayEstimate
        let fingerprint: UInt64
    }

    private struct ValidationStatistics {
        var maximumRadiusError = 0.0
        var maximumAxialError = 0.0
        var maximumAngularErrorDegrees = 0.0
        var maximumChordError = 0.0
    }

    private struct DoubleTransform {
        let model: simd_double4x4
        let inverse: simd_double4x4

        init(_ transform: ObjectTransform) throws {
            guard transform.isFinite else { throw MeshRadialArrayError.nonFiniteValue }
            let floatModel = transform.sanitized().modelMatrix
            model = simd_double4x4(
                Self.double(floatModel.columns.0),
                Self.double(floatModel.columns.1),
                Self.double(floatModel.columns.2),
                Self.double(floatModel.columns.3))
            inverse = model.inverse
            guard Self.isFinite(model), Self.isFinite(inverse) else {
                throw MeshRadialArrayError.inverseTransformFailure
            }
        }

        func position(_ point: SIMD3<Double>, using matrix: simd_double4x4) throws -> SIMD3<Double> {
            let value = matrix * SIMD4<Double>(point, 1)
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
                  value.w.isFinite, abs(value.w) > Double.leastNonzeroMagnitude else {
                throw MeshRadialArrayError.inverseTransformFailure
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

    static func makePreview(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshRadialArrayOptions,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion
    ) throws -> MeshRadialArrayPreview {
        let plan = try makePlan(mesh: mesh, transform: transform, options: options)
        let estimate = plan.estimate
        return MeshRadialArrayPreview(
            options: options,
            estimate: estimate,
            source: MeshRadialArraySourceKey(
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
                analysisFingerprint: plan.fingerprint))
    }

    static func estimate(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshRadialArrayOptions
    ) throws -> MeshRadialArrayEstimate {
        try makePlan(mesh: mesh, transform: transform, options: options).estimate
    }

    static func array(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshRadialArrayOptions
    ) throws -> MeshRadialArrayResult {
        let plan = try makePlan(mesh: mesh, transform: transform, options: options)
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(plan.estimate.resultingVertexCount)
        for copyIndex in 0..<options.count {
            let base = copyIndex * mesh.vertices.count
            for sourceVertexID in mesh.vertices.indices {
                vertices.append(MeshVertex(
                    position: plan.positions[base + sourceVertexID],
                    normal: mesh.vertices[sourceVertexID].normal))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(plan.estimate.resultingTriangleCount * 3)
        for copyIndex in 0..<options.count {
            let vertexOffset = try multiply(copyIndex, mesh.vertices.count)
            for sourceIndex in mesh.indices {
                let mapped = try add(vertexOffset, Int(sourceIndex))
                guard mapped <= Int(UInt32.max) else { throw MeshRadialArrayError.indexOverflow }
                indices.append(UInt32(mapped))
            }
        }

        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals()
        _ = result.adjacency()
        try validateResult(result, source: mesh, transform: transform, plan: plan, options: options)
        return MeshRadialArrayResult(
            mesh: result,
            estimate: plan.estimate,
            analysisFingerprint: plan.fingerprint)
    }

    static func anglesDegrees(for options: MeshRadialArrayOptions) throws -> [Double] {
        try validateOptions(options)
        return (0..<options.count).map { options.angleDegrees(copyIndex: $0) }
    }

    static func preparedResultMatchesPreview(
        _ result: MeshRadialArrayResult,
        preview: MeshRadialArrayPreview
    ) -> Bool {
        result.estimate == preview.estimate
            && result.analysisFingerprint == preview.source.analysisFingerprint
    }

    private static func makePlan(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshRadialArrayOptions
    ) throws -> Plan {
        guard transform.isFinite else { throw MeshRadialArrayError.nonFiniteValue }
        try validateOptions(options)
        let topology = try validateSource(mesh, axis: options.axis)
        let resultingVertices = try multiply(mesh.vertices.count, options.count)
        let resultingTriangles = try multiply(topology.triangleCount, options.count)
        let resultingComponents = try multiply(topology.connectedComponentCount, options.count)
        let resultingBoundaryEdges = try multiply(topology.boundaryEdgeCount, options.count)
        guard resultingVertices <= maximumVertices else { throw MeshRadialArrayError.vertexLimitExceeded }
        guard resultingTriangles <= maximumTriangles else { throw MeshRadialArrayError.triangleLimitExceeded }
        guard resultingVertices <= Int(UInt32.max) else { throw MeshRadialArrayError.indexOverflow }
        let workingBytes = try estimatedWorkingBytes(
            sourceVertices: mesh.vertices.count,
            sourceTriangles: topology.triangleCount,
            uniqueEdges: topology.uniqueEdgeCount,
            resultingVertices: resultingVertices,
            resultingTriangles: resultingTriangles)
        guard workingBytes <= maximumWorkingBytes else {
            throw MeshRadialArrayError.workingMemoryLimitExceeded
        }

        let matrix = try DoubleTransform(transform)
        let worldPivot = try matrix.position(.zero, using: matrix.model)
        let rawAxis4 = matrix.model * SIMD4<Double>(options.axis.localUnitVector, 0)
        let rawAxis = SIMD3<Double>(rawAxis4.x, rawAxis4.y, rawAxis4.z)
        let axisLength = simd_length(rawAxis)
        guard axisLength.isFinite, axisLength > Double.leastNonzeroMagnitude else {
            throw MeshRadialArrayError.worldAxisFailure
        }
        let worldAxis = rawAxis / axisLength
        guard worldAxis.x.isFinite, worldAxis.y.isFinite, worldAxis.z.isFinite else {
            throw MeshRadialArrayError.worldAxisFailure
        }
        let anglesRadians = try anglesDegrees(for: options).map { angle in
            let radians = angle * .pi / 180
            guard radians.isFinite else { throw MeshRadialArrayError.invalidSweep }
            return radians
        }

        var sourceWorld: [SIMD3<Double>] = []
        sourceWorld.reserveCapacity(mesh.vertices.count)
        var sourceWorldBounds = AxisAlignedBoundingBox()
        var maximumWorldMagnitude = max(abs(worldPivot.x), max(abs(worldPivot.y), abs(worldPivot.z)))
        var maximumRadius = 0.0
        for vertex in mesh.vertices {
            let world = try matrix.position(DiagnosticMath.double(vertex.position), using: matrix.model)
            sourceWorld.append(world)
            sourceWorldBounds.include(transform.worldPosition(fromLocal: vertex.position))
            maximumWorldMagnitude = max(maximumWorldMagnitude, max(abs(world.x), max(abs(world.y), abs(world.z))))
            let offset = world - worldPivot
            let axial = simd_dot(offset, worldAxis)
            let radius = simd_length(offset - worldAxis * axial)
            guard radius.isFinite else { throw MeshRadialArrayError.nonFiniteValue }
            maximumRadius = max(maximumRadius, radius)
        }
        let axisTolerance = max(1.0e-9, maximumWorldMagnitude * Double.ulpOfOne * 64)
        guard maximumRadius > axisTolerance else { throw MeshRadialArrayError.noRadialExtent }

        let minimumAngularStep = abs(options.stepDegrees) * .pi / 180
        let minimumChord = 2 * maximumRadius * sin(minimumAngularStep / 2)
        let tolerance = try rotationTolerance(
            maximumWorldMagnitude: maximumWorldMagnitude,
            maximumRadius: maximumRadius,
            minimumChord: minimumChord,
            transform: transform)

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(resultingVertices)
        var resultLocalBounds = AxisAlignedBoundingBox()
        var resultWorldBounds = AxisAlignedBoundingBox()
        for copyIndex in 0..<options.count {
            let angle = anglesRadians[copyIndex]
            for sourceVertexID in mesh.vertices.indices {
                let rotatedWorld = rotate(
                    point: sourceWorld[sourceVertexID],
                    around: worldAxis,
                    pivot: worldPivot,
                    angle: angle)
                let local = try matrix.position(rotatedWorld, using: matrix.inverse)
                let stored = copyIndex == 0 ? mesh.vertices[sourceVertexID].position : DiagnosticMath.float(local)
                guard stored.allFinite else { throw MeshRadialArrayError.rotationRoundTripFailure }
                let actualWorld = try matrix.position(DiagnosticMath.double(stored), using: matrix.model)
                guard actualWorld.x.isFinite, actualWorld.y.isFinite, actualWorld.z.isFinite else {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                positions.append(stored)
                resultLocalBounds.include(stored)
                resultWorldBounds.include(transform.worldPosition(fromLocal: stored))
            }
        }
        guard positions.count == resultingVertices,
              sourceWorldBounds.isFinite, resultLocalBounds.isFinite, resultWorldBounds.isFinite else {
            throw MeshRadialArrayError.boundsFailure
        }
        try validatePlannedGeometry(positions: positions, source: mesh, count: options.count)
        let statistics = try validateStoredRotation(
            positions: positions,
            sourceWorld: sourceWorld,
            source: mesh,
            count: options.count,
            angles: anglesRadians,
            worldAxis: worldAxis,
            worldPivot: worldPivot,
            matrix: matrix,
            axisTolerance: axisTolerance,
            tolerance: tolerance)

        let estimate = MeshRadialArrayEstimate(
            axis: options.axis,
            distribution: options.distribution,
            count: options.count,
            effectiveSweepDegrees: options.effectiveSweepDegrees,
            stepDegrees: options.stepDegrees,
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
            maximumRadiusErrorMillimeters: statistics.maximumRadiusError,
            maximumAxialErrorMillimeters: statistics.maximumAxialError,
            maximumAngularErrorDegrees: statistics.maximumAngularErrorDegrees,
            maximumChordErrorMillimeters: statistics.maximumChordError,
            validationToleranceMillimeters: tolerance,
            estimatedWorkingByteCount: workingBytes)
        return Plan(
            positions: positions,
            worldPivot: worldPivot,
            worldAxis: worldAxis,
            anglesRadians: anglesRadians,
            estimate: estimate,
            fingerprint: fingerprint(mesh: mesh, options: options, estimate: estimate, positions: positions))
    }

    private static func validateOptions(_ options: MeshRadialArrayOptions) throws {
        guard options.count >= minimumCount, options.count <= maximumCount else {
            throw MeshRadialArrayError.invalidCount
        }
        if options.distribution == .openArc {
            let magnitude = abs(options.sweepDegrees)
            guard options.sweepDegrees.isFinite,
                  magnitude >= minimumSweepDegrees,
                  magnitude <= maximumSweepDegrees else {
                throw MeshRadialArrayError.invalidSweep
            }
        }
        guard options.effectiveSweepDegrees.isFinite, options.stepDegrees.isFinite else {
            throw MeshRadialArrayError.invalidSweep
        }
    }

    private static func validateSource(
        _ mesh: EditableMesh,
        axis: LinearArrayAxis
    ) throws -> MeshTopologyReport {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3) else { throw MeshRadialArrayError.invalidMesh }
        guard mesh.vertices.count <= maximumVertices else { throw MeshRadialArrayError.vertexLimitExceeded }
        guard mesh.indices.count / 3 <= maximumTriangles else { throw MeshRadialArrayError.triangleLimitExceeded }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw MeshRadialArrayError.nonFiniteValue
        }
        let radialComponents: (Int, Int)
        switch axis {
        case .x: radialComponents = (1, 2)
        case .y: radialComponents = (0, 2)
        case .z: radialComponents = (0, 1)
        }
        guard mesh.vertices.contains(where: {
            $0.position[radialComponents.0] != 0 || $0.position[radialComponents.1] != 0
        }) else { throw MeshRadialArrayError.noRadialExtent }
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        guard !topology.hasInvalidStructure, topology.invalidIndexTriangleCount == 0 else {
            throw MeshRadialArrayError.invalidMesh
        }
        guard topology.nonFiniteVertexCount == 0 else { throw MeshRadialArrayError.nonFiniteValue }
        guard topology.degenerateTriangleCount == 0 else { throw MeshRadialArrayError.degenerateTriangle }
        guard topology.duplicateTriangleCount == 0 else { throw MeshRadialArrayError.duplicateTriangle }
        guard let hasGeometricDuplicates = MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(mesh) else {
            throw MeshRadialArrayError.invalidMesh
        }
        guard !hasGeometricDuplicates else { throw MeshRadialArrayError.duplicateTriangle }
        guard topology.nonManifoldEdgeCount == 0 else { throw MeshRadialArrayError.nonManifoldEdge }
        guard topology.inconsistentWindingEdgeCount == 0 else { throw MeshRadialArrayError.windingConflict }
        guard topology.isolatedVertexCount == 0 else { throw MeshRadialArrayError.isolatedVertex }
        guard mesh.bounds.isFinite else { throw MeshRadialArrayError.boundsFailure }
        return topology
    }

    private static func validatePlannedGeometry(
        positions: [SIMD3<Float>],
        source: EditableMesh,
        count: Int
    ) throws {
        guard positions.count == source.vertices.count * count else {
            throw MeshRadialArrayError.validationFailed
        }
        var triangles = Set<PositionTriangleKey>()
        triangles.reserveCapacity(source.indices.count / 3 * count)
        for copyIndex in 0..<count {
            let base = copyIndex * source.vertices.count
            var storedSourceByPosition: [PositionKey: PositionKey] = [:]
            storedSourceByPosition.reserveCapacity(source.vertices.count)
            for sourceID in source.vertices.indices {
                let sourceKey = PositionKey(source.vertices[sourceID].position)
                let resultKey = PositionKey(positions[base + sourceID])
                if let previousSource = storedSourceByPosition[resultKey], previousSource != sourceKey {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                storedSourceByPosition[resultKey] = sourceKey
            }
            for faceID in 0..<(source.indices.count / 3) {
                let ids = try triangleVertexIDs(mesh: source, faceID: faceID)
                let points = ids.map { positions[base + $0] }
                let resultArea = DiagnosticMath.twiceArea(points[0], points[1], points[2])
                guard resultArea.isFinite, resultArea > MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: source) else {
                    throw MeshRadialArrayError.copyWouldCollapseTriangle
                }
                guard triangles.insert(PositionTriangleKey(points[0], points[1], points[2])).inserted else {
                    throw MeshRadialArrayError.copyWouldCreateDuplicateGeometry
                }
            }
        }
    }

    private static func validateStoredRotation(
        positions: [SIMD3<Float>],
        sourceWorld: [SIMD3<Double>],
        source: EditableMesh,
        count: Int,
        angles: [Double],
        worldAxis: SIMD3<Double>,
        worldPivot: SIMD3<Double>,
        matrix: DoubleTransform,
        axisTolerance: Double,
        tolerance: Double
    ) throws -> ValidationStatistics {
        guard sourceWorld.count == source.vertices.count,
              positions.count == source.vertices.count * count,
              angles.count == count else { throw MeshRadialArrayError.validationFailed }
        var statistics = ValidationStatistics()
        var actualWorld = Array(repeating: SIMD3<Double>.zero, count: positions.count)
        for copyIndex in 0..<count {
            let base = copyIndex * source.vertices.count
            let angle = angles[copyIndex]
            let principalExpected = principalAngle(angle)
            for sourceVertexID in source.vertices.indices {
                let actual = try matrix.position(
                    DiagnosticMath.double(positions[base + sourceVertexID]), using: matrix.model)
                actualWorld[base + sourceVertexID] = actual
                let sourceOffset = sourceWorld[sourceVertexID] - worldPivot
                let actualOffset = actual - worldPivot
                let sourceAxial = simd_dot(sourceOffset, worldAxis)
                let actualAxial = simd_dot(actualOffset, worldAxis)
                let sourceRadial = sourceOffset - worldAxis * sourceAxial
                let actualRadial = actualOffset - worldAxis * actualAxial
                let sourceRadius = simd_length(sourceRadial)
                let actualRadius = simd_length(actualRadial)
                let axialError = abs(actualAxial - sourceAxial)
                let radiusError = abs(actualRadius - sourceRadius)
                statistics.maximumAxialError = max(statistics.maximumAxialError, axialError)
                statistics.maximumRadiusError = max(statistics.maximumRadiusError, radiusError)
                guard axialError <= tolerance, radiusError <= tolerance else {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                let actualChord = simd_length(actual - sourceWorld[sourceVertexID])
                let expectedChord = 2 * sourceRadius * abs(sin(angle / 2))
                let chordError = abs(actualChord - expectedChord)
                statistics.maximumChordError = max(statistics.maximumChordError, chordError)
                guard actualChord.isFinite, chordError <= tolerance * 2 else {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                if sourceRadius > max(axisTolerance, tolerance * 2) {
                    let raw = atan2(
                        simd_dot(worldAxis, simd_cross(sourceRadial, actualRadial)),
                        simd_dot(sourceRadial, actualRadial))
                    let angularError = abs(principalAngle(raw - principalExpected))
                    let angularTolerance = min(0.01, max(1.0e-8, tolerance / sourceRadius * 180 / .pi * 2))
                    statistics.maximumAngularErrorDegrees = max(
                        statistics.maximumAngularErrorDegrees, angularError * 180 / .pi)
                    guard angularError.isFinite, angularError <= angularTolerance * .pi / 180 else {
                        throw MeshRadialArrayError.rotationRoundTripFailure
                    }
                } else {
                    guard actualRadius <= max(axisTolerance, tolerance * 2) else {
                        throw MeshRadialArrayError.rotationRoundTripFailure
                    }
                }
            }
        }

        for copyIndex in 0..<count {
            let base = copyIndex * source.vertices.count
            for faceID in 0..<(source.indices.count / 3) {
                let ids = try triangleVertexIDs(mesh: source, faceID: faceID)
                let sourcePoints = ids.map { sourceWorld[$0] }
                let resultPoints = ids.map { actualWorld[base + $0] }
                for edge in [(0, 1), (1, 2), (2, 0)] {
                    let sourceLength = simd_length(sourcePoints[edge.1] - sourcePoints[edge.0])
                    let resultLength = simd_length(resultPoints[edge.1] - resultPoints[edge.0])
                    guard sourceLength.isFinite, resultLength.isFinite,
                          abs(resultLength - sourceLength) <= tolerance * 2 else {
                        throw MeshRadialArrayError.rotationRoundTripFailure
                    }
                }
                let sourceArea = simd_length(simd_cross(
                    sourcePoints[1] - sourcePoints[0], sourcePoints[2] - sourcePoints[0]))
                let resultArea = simd_length(simd_cross(
                    resultPoints[1] - resultPoints[0], resultPoints[2] - resultPoints[0]))
                let maximumEdge = max(
                    simd_length(sourcePoints[1] - sourcePoints[0]),
                    max(simd_length(sourcePoints[2] - sourcePoints[1]),
                        simd_length(sourcePoints[0] - sourcePoints[2])))
                let areaTolerance = max(sourceArea * 1.0e-4, tolerance * maximumEdge * 4)
                guard sourceArea.isFinite, resultArea.isFinite, resultArea > 0,
                      abs(resultArea - sourceArea) <= areaTolerance else {
                    throw MeshRadialArrayError.copyWouldCollapseTriangle
                }
            }
        }
        return statistics
    }

    private static func validateResult(
        _ result: EditableMesh,
        source: EditableMesh,
        transform: ObjectTransform,
        plan: Plan,
        options: MeshRadialArrayOptions
    ) throws {
        guard result.vertices.count == plan.estimate.resultingVertexCount,
              result.indices.count == plan.estimate.resultingTriangleCount * 3,
              result.bounds == plan.estimate.resultLocalBounds,
              result.hasCachedAdjacency,
              result.vertices.allSatisfy({ vertex in
                  vertex.position.allFinite && vertex.normal.allFinite
                      && abs(simd_length(vertex.normal) - 1) <= 0.001
              }) else { throw MeshRadialArrayError.validationFailed }
        guard Array(result.vertices.prefix(source.vertices.count)).map(\.position)
                == source.vertices.map(\.position),
              Array(result.indices.prefix(source.indices.count)) == source.indices else {
            throw MeshRadialArrayError.validationFailed
        }
        let topology = MeshTopologyDiagnostics.analyze(result)
        guard !topology.hasInvalidStructure,
              topology.invalidIndexTriangleCount == 0,
              topology.nonFiniteVertexCount == 0,
              topology.nonManifoldEdgeCount == 0,
              topology.inconsistentWindingEdgeCount == 0,
              topology.isolatedVertexCount == 0 else {
            throw MeshRadialArrayError.validationFailed
        }
        guard topology.degenerateTriangleCount == 0 else {
            throw MeshRadialArrayError.copyWouldCollapseTriangle
        }
        guard topology.duplicateTriangleCount == 0,
              MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(result) == false else {
            throw MeshRadialArrayError.copyWouldCreateDuplicateGeometry
        }
        guard topology.connectedComponentCount == plan.estimate.resultingComponentCount else {
            throw MeshRadialArrayError.componentCountFailure
        }
        guard topology.boundaryEdgeCount == plan.estimate.resultingBoundaryEdgeCount else {
            throw MeshRadialArrayError.boundaryCountFailure
        }
        for copyIndex in 0..<options.count {
            let vertexOffset = copyIndex * source.vertices.count
            let indexOffset = copyIndex * source.indices.count
            for sourceOffset in source.indices.indices {
                let expected = UInt32(vertexOffset + Int(source.indices[sourceOffset]))
                guard result.indices[indexOffset + sourceOffset] == expected else {
                    throw MeshRadialArrayError.validationFailed
                }
            }
        }
        let matrix = try DoubleTransform(transform)
        var sourceWorld: [SIMD3<Double>] = []
        sourceWorld.reserveCapacity(source.vertices.count)
        for vertex in source.vertices {
            sourceWorld.append(try matrix.position(DiagnosticMath.double(vertex.position), using: matrix.model))
        }
        _ = try validateStoredRotation(
            positions: result.vertices.map(\.position),
            sourceWorld: sourceWorld,
            source: source,
            count: options.count,
            angles: plan.anglesRadians,
            worldAxis: plan.worldAxis,
            worldPivot: plan.worldPivot,
            matrix: matrix,
            axisTolerance: plan.estimate.validationToleranceMillimeters,
            tolerance: plan.estimate.validationToleranceMillimeters)
        var worldBounds = AxisAlignedBoundingBox()
        for vertex in result.vertices {
            let world = try matrix.position(DiagnosticMath.double(vertex.position), using: matrix.model)
            worldBounds.include(DiagnosticMath.float(world))
        }
        guard worldBounds == plan.estimate.resultWorldBounds else {
            throw MeshRadialArrayError.boundsFailure
        }
    }

    static func estimatedWorkingBytes(
        sourceVertices: Int,
        sourceTriangles: Int,
        uniqueEdges: Int,
        resultingVertices: Int,
        resultingTriangles: Int
    ) throws -> Int {
        try add(
            try multiply(sourceVertices, 144),
            try multiply(sourceTriangles, 112),
            try multiply(uniqueEdges, 128),
            try multiply(resultingVertices, 160),
            try multiply(resultingTriangles, 112))
    }

    private static func rotationTolerance(
        maximumWorldMagnitude: Double,
        maximumRadius: Double,
        minimumChord: Double,
        transform: ObjectTransform
    ) throws -> Double {
        let safeScale = transform.sanitized().scale
        let maximumScale = Double(max(safeScale.x, max(safeScale.y, safeScale.z)))
        let precisionFloor = max(max(maximumWorldMagnitude, maximumRadius), max(maximumScale, 1))
            * Double(Float.ulpOfOne) * 2
        let requestedFloor = max(maximumRadius, 1) * 1.0e-7
        let cap = max(1.0e-8, minimumChord * 0.5)
        let required = max(1.0e-9, precisionFloor, requestedFloor)
        guard required.isFinite, cap.isFinite, required <= cap else {
            throw MeshRadialArrayError.rotationRoundTripFailure
        }
        return required
    }

    private static func rotate(
        point: SIMD3<Double>,
        around axis: SIMD3<Double>,
        pivot: SIMD3<Double>,
        angle: Double
    ) -> SIMD3<Double> {
        let offset = point - pivot
        let (sine, cosine) = canonicalTrigonometry(angle)
        return pivot + offset * cosine
            + simd_cross(axis, offset) * sine
            + axis * simd_dot(axis, offset) * (1 - cosine)
    }

    private static func canonicalTrigonometry(_ angle: Double) -> (sine: Double, cosine: Double) {
        func canonical(_ value: Double) -> Double {
            if abs(value) <= 1.0e-14 { return 0 }
            if abs(value - 1) <= 1.0e-14 { return 1 }
            if abs(value + 1) <= 1.0e-14 { return -1 }
            return value
        }
        return (canonical(sin(angle)), canonical(cos(angle)))
    }

    private static func principalAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    private static func triangleVertexIDs(mesh: EditableMesh, faceID: Int) throws -> [Int] {
        let offset = try multiply(faceID, 3)
        guard offset + 2 < mesh.indices.count else { throw MeshRadialArrayError.invalidMesh }
        let ids = [
            Int(mesh.indices[offset]),
            Int(mesh.indices[offset + 1]),
            Int(mesh.indices[offset + 2]),
        ]
        guard ids.allSatisfy(mesh.vertices.indices.contains) else { throw MeshRadialArrayError.invalidMesh }
        return ids
    }

    private static func fingerprint(
        mesh: EditableMesh,
        options: MeshRadialArrayOptions,
        estimate: MeshRadialArrayEstimate,
        positions: [SIMD3<Float>]
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) { hash ^= value; hash &*= 1_099_511_628_211 }
        mix(UInt64(options.axis.componentIndex))
        mix(UInt64(options.distribution == .fullCircle ? 0 : 1))
        mix(UInt64(options.count))
        mix(UInt64(options.direction == .positive ? 0 : 1))
        mix(options.sweepDegrees.bitPattern)
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
            guard value >= 0, !overflow else { throw MeshRadialArrayError.arithmeticOverflow }
            return result
        }
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw MeshRadialArrayError.arithmeticOverflow }
        return result
    }
}
