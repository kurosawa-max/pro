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

    var canonicalized: Self {
        var value = self
        switch distribution {
        case .fullCircle:
            value.sweepDegrees = 0
        case .openArc:
            value.direction = .positive
        }
        return value
    }

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
    let pivotWorld: SIMD3<Float>
    let axisWorld: SIMD3<Float>
    let axisVertexCount: Int
    let offAxisVertexCount: Int
    let minimumPositiveSourceRadiusMillimeters: Double
    let maximumSourceRadiusMillimeters: Double
    let axisClassificationToleranceMillimeters: Double
    let radialToleranceMillimeters: Double
    let axialToleranceMillimeters: Double
    let maximumAngularToleranceDegrees: Double
    let minimumFeatureChordMillimeters: Double
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
            && self.options == options.canonicalized
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
    case renderSpacePrecisionFailure
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
        case .renderSpacePrecisionFailure: "The requested Radial Array cannot preserve the displayed mesh in render-space Float precision."
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

    private struct RenderTolerances {
        let position: Double
        let radial: Double
        let axial: Double
        let angularDegrees: Double
        let axisClassification: Double
        let positionByVertex: [Double]
        let angularDegreesByVertex: [Double]
    }

    private struct SourceRenderAnalysis {
        let worldFloat: [SIMD3<Float>]
        let world: [SIMD3<Double>]
        let pivotFloat: SIMD3<Float>
        let pivot: SIMD3<Double>
        let axisFloat: SIMD3<Float>
        let axis: SIMD3<Double>
        let radii: [Double]
        let axisThresholds: [Double]
        let isAxisVertex: [Bool]
        let axisVertexCount: Int
        let offAxisVertexCount: Int
        let minimumPositiveRadius: Double
        let maximumRadius: Double
        let maximumCoordinateULP: Double
        let coordinateULPs: [Double]
        let worldBounds: AxisAlignedBoundingBox
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
        let options = options.canonicalized
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
        let options = options.canonicalized
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
        let options = options.canonicalized
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
        let options = options.canonicalized
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
        let sourceAnalysis = try analyzeSourceRenderSpace(
            mesh: mesh, transform: transform, axis: options.axis)
        let anglesRadians = try anglesDegrees(for: options).map { angle in
            let radians = angle * .pi / 180
            guard radians.isFinite else { throw MeshRadialArrayError.invalidSweep }
            return radians
        }
        let minimumAngularStep = abs(options.stepDegrees) * .pi / 180
        let minimumFeatureChord = 2 * sourceAnalysis.minimumPositiveRadius
            * abs(sin(minimumAngularStep / 2))
        let tolerances = try renderTolerances(
            analysis: sourceAnalysis,
            minimumFeatureChord: minimumFeatureChord)
        guard minimumFeatureChord.isFinite else {
            throw MeshRadialArrayError.renderSpacePrecisionFailure
        }
        for sourceVertexID in mesh.vertices.indices
        where !sourceAnalysis.isAxisVertex[sourceVertexID] {
            let featureChord = 2 * sourceAnalysis.radii[sourceVertexID]
                * abs(sin(minimumAngularStep / 2))
            guard featureChord.isFinite,
                  featureChord > tolerances.positionByVertex[sourceVertexID] * 2 else {
                throw MeshRadialArrayError.renderSpacePrecisionFailure
            }
        }
        try validateSourceRenderGeometry(
            mesh: mesh, analysis: sourceAnalysis, tolerances: tolerances)

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(resultingVertices)
        var resultLocalBounds = AxisAlignedBoundingBox()
        var resultWorldBounds = AxisAlignedBoundingBox()
        for copyIndex in 0..<options.count {
            let angle = anglesRadians[copyIndex]
            for sourceVertexID in mesh.vertices.indices {
                let rotatedWorld = rotate(
                    point: sourceAnalysis.world[sourceVertexID],
                    around: sourceAnalysis.axis,
                    pivot: sourceAnalysis.pivot,
                    angle: angle)
                let local = try matrix.position(rotatedWorld, using: matrix.inverse)
                let stored = copyIndex == 0 ? mesh.vertices[sourceVertexID].position : DiagnosticMath.float(local)
                guard stored.allFinite else { throw MeshRadialArrayError.rotationRoundTripFailure }
                let actualWorldFloat = transform.worldPosition(fromLocal: stored)
                guard actualWorldFloat.allFinite else { throw MeshRadialArrayError.renderSpacePrecisionFailure }
                positions.append(stored)
                resultLocalBounds.include(stored)
                resultWorldBounds.include(actualWorldFloat)
            }
        }
        guard positions.count == resultingVertices,
              sourceAnalysis.worldBounds.isFinite,
              resultLocalBounds.isFinite, resultWorldBounds.isFinite else {
            throw MeshRadialArrayError.boundsFailure
        }
        try validatePlannedGeometry(positions: positions, source: mesh, count: options.count)
        let statistics = try validateStoredRotation(
            positions: positions,
            source: mesh,
            transform: transform,
            analysis: sourceAnalysis,
            count: options.count,
            angles: anglesRadians,
            distribution: options.distribution,
            tolerances: tolerances)

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
            sourceWorldBounds: sourceAnalysis.worldBounds,
            resultWorldBounds: resultWorldBounds,
            pivotWorld: sourceAnalysis.pivotFloat,
            axisWorld: sourceAnalysis.axisFloat,
            axisVertexCount: sourceAnalysis.axisVertexCount,
            offAxisVertexCount: sourceAnalysis.offAxisVertexCount,
            minimumPositiveSourceRadiusMillimeters: sourceAnalysis.minimumPositiveRadius,
            maximumSourceRadiusMillimeters: sourceAnalysis.maximumRadius,
            axisClassificationToleranceMillimeters: tolerances.axisClassification,
            radialToleranceMillimeters: tolerances.radial,
            axialToleranceMillimeters: tolerances.axial,
            maximumAngularToleranceDegrees: tolerances.angularDegrees,
            minimumFeatureChordMillimeters: minimumFeatureChord,
            maximumRadiusErrorMillimeters: statistics.maximumRadiusError,
            maximumAxialErrorMillimeters: statistics.maximumAxialError,
            maximumAngularErrorDegrees: statistics.maximumAngularErrorDegrees,
            maximumChordErrorMillimeters: statistics.maximumChordError,
            validationToleranceMillimeters: tolerances.position,
            estimatedWorkingByteCount: workingBytes)
        return Plan(
            positions: positions,
            worldPivot: sourceAnalysis.pivot,
            worldAxis: sourceAnalysis.axis,
            anglesRadians: anglesRadians,
            estimate: estimate,
            fingerprint: fingerprint(
                mesh: mesh,
                options: options,
                estimate: estimate,
                sourceWorld: sourceAnalysis.worldFloat,
                positions: positions))
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

    private static func analyzeSourceRenderSpace(
        mesh: EditableMesh,
        transform: ObjectTransform,
        axis: LinearArrayAxis
    ) throws -> SourceRenderAnalysis {
        let localAxis = SIMD3<Float>(
            Float(axis.localUnitVector.x),
            Float(axis.localUnitVector.y),
            Float(axis.localUnitVector.z))
        let pivotFloat = transform.worldPosition(fromLocal: .zero)
        let axisFloat = transform.worldDirection(fromLocal: localAxis)
        guard pivotFloat.allFinite, axisFloat.allFinite else {
            throw MeshRadialArrayError.worldAxisFailure
        }
        let axisLength = simd_length(axisFloat)
        guard axisLength.isFinite, abs(axisLength - 1) <= 0.000_01 else {
            throw MeshRadialArrayError.worldAxisFailure
        }
        let pivot = DiagnosticMath.double(pivotFloat)
        let worldAxis = DiagnosticMath.double(axisFloat)
        let worldAxisLength = simd_length(worldAxis)
        guard worldAxisLength.isFinite, worldAxisLength > Double.leastNonzeroMagnitude else {
            throw MeshRadialArrayError.worldAxisFailure
        }
        let normalizedAxis = worldAxis / worldAxisLength

        var worldFloat: [SIMD3<Float>] = []
        var world: [SIMD3<Double>] = []
        var radii: [Double] = []
        var axisThresholds: [Double] = []
        var coordinateULPs: [Double] = []
        var isAxisVertex: [Bool] = []
        var bounds = AxisAlignedBoundingBox()
        worldFloat.reserveCapacity(mesh.vertices.count)
        world.reserveCapacity(mesh.vertices.count)
        radii.reserveCapacity(mesh.vertices.count)
        axisThresholds.reserveCapacity(mesh.vertices.count)
        coordinateULPs.reserveCapacity(mesh.vertices.count)
        isAxisVertex.reserveCapacity(mesh.vertices.count)
        var maximumCoordinateULP = maximumComponentULP(pivotFloat)
        var minimumPositiveRadius = Double.greatestFiniteMagnitude
        var maximumRadius = 0.0
        var axisVertexCount = 0

        for vertex in mesh.vertices {
            let rendered = transform.worldPosition(fromLocal: vertex.position)
            guard rendered.allFinite else { throw MeshRadialArrayError.renderSpacePrecisionFailure }
            let renderedDouble = DiagnosticMath.double(rendered)
            let offset = renderedDouble - pivot
            let axial = simd_dot(offset, normalizedAxis)
            let radius = simd_length(offset - normalizedAxis * axial)
            guard radius.isFinite else { throw MeshRadialArrayError.renderSpacePrecisionFailure }
            let coordinateULP = max(maximumComponentULP(rendered), maximumComponentULP(pivotFloat))
            let projectionNoise = simd_length(offset) * Double(Float.ulpOfOne) * 2
            let axisThreshold = max(1.0e-12, coordinateULP * 0.5, projectionNoise)
            let onAxis = radius <= axisThreshold
            if onAxis {
                axisVertexCount += 1
            } else {
                minimumPositiveRadius = min(minimumPositiveRadius, radius)
                maximumRadius = max(maximumRadius, radius)
            }
            maximumCoordinateULP = max(maximumCoordinateULP, coordinateULP)
            worldFloat.append(rendered)
            world.append(renderedDouble)
            radii.append(radius)
            axisThresholds.append(axisThreshold)
            coordinateULPs.append(coordinateULP)
            isAxisVertex.append(onAxis)
            bounds.include(rendered)
        }
        let offAxisVertexCount = mesh.vertices.count - axisVertexCount
        guard offAxisVertexCount > 0, minimumPositiveRadius.isFinite,
              maximumRadius.isFinite, maximumRadius > 0 else {
            throw MeshRadialArrayError.renderSpacePrecisionFailure
        }
        guard bounds.isFinite else { throw MeshRadialArrayError.boundsFailure }
        return SourceRenderAnalysis(
            worldFloat: worldFloat,
            world: world,
            pivotFloat: pivotFloat,
            pivot: pivot,
            axisFloat: axisFloat,
            axis: normalizedAxis,
            radii: radii,
            axisThresholds: axisThresholds,
            isAxisVertex: isAxisVertex,
            axisVertexCount: axisVertexCount,
            offAxisVertexCount: offAxisVertexCount,
            minimumPositiveRadius: minimumPositiveRadius,
            maximumRadius: maximumRadius,
            maximumCoordinateULP: maximumCoordinateULP,
            coordinateULPs: coordinateULPs,
            worldBounds: bounds)
    }

    private static func renderTolerances(
        analysis: SourceRenderAnalysis,
        minimumFeatureChord: Double
    ) throws -> RenderTolerances {
        let positionByVertex = analysis.radii.indices.map { index in
            max(
                1.0e-9,
                analysis.coordinateULPs[index] * 2,
                analysis.radii[index] * Double(Float.ulpOfOne) * 2)
        }
        let angularByVertex = analysis.radii.indices.map { index in
            guard !analysis.isAxisVertex[index] else { return 0.0 }
            return min(
                0.01,
                max(1.0e-8, positionByVertex[index]
                    / analysis.radii[index] * 180 / .pi))
        }
        let position = positionByVertex.max() ?? 1.0e-9
        let radial = position
        let axial = position
        let angular = angularByVertex.max() ?? 1.0e-8
        let axisClassification = analysis.axisThresholds.max() ?? 1.0e-12
        guard position.isFinite, radial.isFinite, axial.isFinite,
              angular.isFinite, axisClassification.isFinite,
              minimumFeatureChord.isFinite else {
            throw MeshRadialArrayError.renderSpacePrecisionFailure
        }
        return RenderTolerances(
            position: position,
            radial: radial,
            axial: axial,
            angularDegrees: min(0.01, angular),
            axisClassification: axisClassification,
            positionByVertex: positionByVertex,
            angularDegreesByVertex: angularByVertex)
    }

    private static func validateSourceRenderGeometry(
        mesh: EditableMesh,
        analysis: SourceRenderAnalysis,
        tolerances: RenderTolerances
    ) throws {
        var renderedTriangles = Set<PositionTriangleKey>()
        renderedTriangles.reserveCapacity(mesh.indices.count / 3)
        for faceID in 0..<(mesh.indices.count / 3) {
            let ids = try triangleVertexIDs(mesh: mesh, faceID: faceID)
            let points = ids.map { analysis.world[$0] }
            let pointFloats = ids.map { analysis.worldFloat[$0] }
            let edges = [
                simd_length(points[1] - points[0]),
                simd_length(points[2] - points[1]),
                simd_length(points[0] - points[2]),
            ]
            let vertexTolerance = ids.map { tolerances.positionByVertex[$0] }.max() ?? 1.0e-9
            guard edges.allSatisfy({ $0.isFinite && $0 > vertexTolerance }) else {
                throw MeshRadialArrayError.renderSpacePrecisionFailure
            }
            let twiceArea = simd_length(simd_cross(
                points[1] - points[0], points[2] - points[0]))
            let maximumEdge = edges.max() ?? 0
            let areaFloor = vertexTolerance * maximumEdge * 2
            guard twiceArea.isFinite, twiceArea > areaFloor else {
                throw MeshRadialArrayError.renderSpacePrecisionFailure
            }
            guard renderedTriangles.insert(PositionTriangleKey(
                pointFloats[0], pointFloats[1], pointFloats[2])).inserted else {
                throw MeshRadialArrayError.copyWouldCreateDuplicateGeometry
            }
        }
    }

    private static func maximumComponentULP(_ value: SIMD3<Float>) -> Double {
        Double(max(value.x.ulp, max(value.y.ulp, value.z.ulp)))
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
                guard resultArea.isFinite, resultArea > 0 else {
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
        source: EditableMesh,
        transform: ObjectTransform,
        analysis: SourceRenderAnalysis,
        count: Int,
        angles: [Double],
        distribution: RadialArrayDistribution,
        tolerances: RenderTolerances
    ) throws -> ValidationStatistics {
        guard analysis.world.count == source.vertices.count,
              positions.count == source.vertices.count * count,
              angles.count == count else { throw MeshRadialArrayError.validationFailed }
        var statistics = ValidationStatistics()
        var actualWorld = Array(repeating: SIMD3<Double>.zero, count: positions.count)
        var actualWorldFloat = Array(repeating: SIMD3<Float>.zero, count: positions.count)
        for copyIndex in 0..<count {
            let base = copyIndex * source.vertices.count
            let angle = angles[copyIndex]
            let principalExpected = principalAngle(angle)
            for sourceVertexID in source.vertices.indices {
                let vertexTolerance = tolerances.positionByVertex[sourceVertexID]
                let actualFloat = transform.worldPosition(
                    fromLocal: positions[base + sourceVertexID])
                guard actualFloat.allFinite else {
                    throw MeshRadialArrayError.renderSpacePrecisionFailure
                }
                let actual = DiagnosticMath.double(actualFloat)
                let ideal = rotate(
                    point: analysis.world[sourceVertexID],
                    around: analysis.axis,
                    pivot: analysis.pivot,
                    angle: angle)
                let positionError = simd_length(actual - ideal)
                guard positionError.isFinite,
                      positionError <= vertexTolerance * 2 else {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                actualWorld[base + sourceVertexID] = actual
                actualWorldFloat[base + sourceVertexID] = actualFloat
                let sourceOffset = analysis.world[sourceVertexID] - analysis.pivot
                let actualOffset = actual - analysis.pivot
                let sourceAxial = simd_dot(sourceOffset, analysis.axis)
                let actualAxial = simd_dot(actualOffset, analysis.axis)
                let sourceRadial = sourceOffset - analysis.axis * sourceAxial
                let actualRadial = actualOffset - analysis.axis * actualAxial
                let sourceRadius = analysis.radii[sourceVertexID]
                let actualRadius = simd_length(actualRadial)
                let axialError = abs(actualAxial - sourceAxial)
                let radiusError = abs(actualRadius - sourceRadius)
                statistics.maximumAxialError = max(statistics.maximumAxialError, axialError)
                statistics.maximumRadiusError = max(statistics.maximumRadiusError, radiusError)
                guard axialError <= vertexTolerance * 2,
                      radiusError <= vertexTolerance * 2 else {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                let actualChord = simd_length(actual - analysis.world[sourceVertexID])
                let expectedChord = 2 * sourceRadius * abs(sin(angle / 2))
                let chordError = abs(actualChord - expectedChord)
                statistics.maximumChordError = max(statistics.maximumChordError, chordError)
                guard actualChord.isFinite,
                      chordError <= vertexTolerance * 2 else {
                    throw MeshRadialArrayError.rotationRoundTripFailure
                }
                if !analysis.isAxisVertex[sourceVertexID] {
                    guard actualRadius > analysis.axisThresholds[sourceVertexID] else {
                        throw MeshRadialArrayError.renderSpacePrecisionFailure
                    }
                    let raw = atan2(
                        simd_dot(analysis.axis, simd_cross(sourceRadial, actualRadial)),
                        simd_dot(sourceRadial, actualRadial))
                    let angularError = abs(principalAngle(raw - principalExpected))
                    statistics.maximumAngularErrorDegrees = max(
                        statistics.maximumAngularErrorDegrees, angularError * 180 / .pi)
                    guard angularError.isFinite,
                          angularError * 180 / .pi
                            <= tolerances.angularDegreesByVertex[sourceVertexID] else {
                        throw MeshRadialArrayError.rotationRoundTripFailure
                    }
                } else {
                    guard actualRadius <= analysis.axisThresholds[sourceVertexID]
                            + vertexTolerance else {
                        throw MeshRadialArrayError.rotationRoundTripFailure
                    }
                }
            }
        }

        for sourceVertexID in source.vertices.indices
        where !analysis.isAxisVertex[sourceVertexID] {
            let sourceRadius = analysis.radii[sourceVertexID]
            let vertexTolerance = tolerances.positionByVertex[sourceVertexID]
            for copyIndex in 1..<count {
                let previous = actualWorld[(copyIndex - 1) * source.vertices.count + sourceVertexID]
                let current = actualWorld[copyIndex * source.vertices.count + sourceVertexID]
                let step = abs(angles[copyIndex] - angles[copyIndex - 1])
                let expected = 2 * sourceRadius * abs(sin(step / 2))
                let actual = simd_length(current - previous)
                guard actual.isFinite, actual > 0,
                      abs(actual - expected) <= vertexTolerance * 2 else {
                    throw MeshRadialArrayError.renderSpacePrecisionFailure
                }
            }
            if distribution == .fullCircle {
                let first = actualWorld[sourceVertexID]
                let last = actualWorld[(count - 1) * source.vertices.count + sourceVertexID]
                let expected = 2 * sourceRadius * abs(sin(abs(angles[1] - angles[0]) / 2))
                let actual = simd_length(first - last)
                guard actual.isFinite, actual > 0,
                      abs(actual - expected) <= vertexTolerance * 2 else {
                    throw MeshRadialArrayError.renderSpacePrecisionFailure
                }
            }
        }

        var renderedTriangles = Set<PositionTriangleKey>()
        renderedTriangles.reserveCapacity(source.indices.count / 3 * count)
        for copyIndex in 0..<count {
            let base = copyIndex * source.vertices.count
            for faceID in 0..<(source.indices.count / 3) {
                let ids = try triangleVertexIDs(mesh: source, faceID: faceID)
                let sourcePoints = ids.map { analysis.world[$0] }
                let resultPoints = ids.map { actualWorld[base + $0] }
                let resultPointFloats = ids.map { actualWorldFloat[base + $0] }
                let vertexTolerance = ids.map {
                    tolerances.positionByVertex[$0]
                }.max() ?? tolerances.position
                for edge in [(0, 1), (1, 2), (2, 0)] {
                    let sourceLength = simd_length(sourcePoints[edge.1] - sourcePoints[edge.0])
                    let resultLength = simd_length(resultPoints[edge.1] - resultPoints[edge.0])
                    guard sourceLength.isFinite, resultLength.isFinite,
                          resultLength > vertexTolerance,
                          abs(resultLength - sourceLength) <= vertexTolerance * 4 else {
                        throw MeshRadialArrayError.copyWouldCollapseTriangle
                    }
                }
                let sourceNormal = simd_cross(
                    sourcePoints[1] - sourcePoints[0], sourcePoints[2] - sourcePoints[0])
                let idealNormal = rotateVector(
                    sourceNormal, around: analysis.axis, angle: angles[copyIndex])
                let resultNormal = simd_cross(
                    resultPoints[1] - resultPoints[0], resultPoints[2] - resultPoints[0])
                let sourceArea = simd_length(sourceNormal)
                let resultArea = simd_length(resultNormal)
                let maximumEdge = max(
                    simd_length(sourcePoints[1] - sourcePoints[0]),
                    max(simd_length(sourcePoints[2] - sourcePoints[1]),
                        simd_length(sourcePoints[0] - sourcePoints[2])))
                let areaTolerance = max(
                    sourceArea * 1.0e-5,
                    vertexTolerance * maximumEdge * 8)
                guard sourceArea.isFinite, resultArea.isFinite, resultArea > 0,
                      abs(resultArea - sourceArea) <= areaTolerance,
                      simd_dot(idealNormal, resultNormal) > 0 else {
                    throw MeshRadialArrayError.copyWouldCollapseTriangle
                }
                guard renderedTriangles.insert(PositionTriangleKey(
                    resultPointFloats[0], resultPointFloats[1], resultPointFloats[2])).inserted else {
                    throw MeshRadialArrayError.copyWouldCreateDuplicateGeometry
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
        let analysis = try analyzeSourceRenderSpace(
            mesh: source, transform: transform, axis: options.axis)
        guard analysis.pivotFloat == plan.estimate.pivotWorld,
              analysis.axisFloat == plan.estimate.axisWorld,
              analysis.axisVertexCount == plan.estimate.axisVertexCount,
              analysis.offAxisVertexCount == plan.estimate.offAxisVertexCount,
              analysis.minimumPositiveRadius == plan.estimate.minimumPositiveSourceRadiusMillimeters,
              analysis.maximumRadius == plan.estimate.maximumSourceRadiusMillimeters else {
            throw MeshRadialArrayError.validationFailed
        }
        let minimumFeatureChord = 2 * analysis.minimumPositiveRadius
            * abs(sin(abs(options.stepDegrees) * .pi / 360))
        let tolerances = try renderTolerances(
            analysis: analysis, minimumFeatureChord: minimumFeatureChord)
        guard minimumFeatureChord == plan.estimate.minimumFeatureChordMillimeters,
              tolerances.position == plan.estimate.validationToleranceMillimeters,
              tolerances.radial == plan.estimate.radialToleranceMillimeters,
              tolerances.axial == plan.estimate.axialToleranceMillimeters,
              tolerances.angularDegrees == plan.estimate.maximumAngularToleranceDegrees,
              tolerances.axisClassification
                == plan.estimate.axisClassificationToleranceMillimeters else {
            throw MeshRadialArrayError.validationFailed
        }
        _ = try validateStoredRotation(
            positions: result.vertices.map(\.position),
            source: source,
            transform: transform,
            analysis: analysis,
            count: options.count,
            angles: plan.anglesRadians,
            distribution: options.distribution,
            tolerances: tolerances)
        var worldBounds = AxisAlignedBoundingBox()
        for vertex in result.vertices {
            worldBounds.include(transform.worldPosition(fromLocal: vertex.position))
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

    private static func rotateVector(
        _ vector: SIMD3<Double>,
        around axis: SIMD3<Double>,
        angle: Double
    ) -> SIMD3<Double> {
        let (sine, cosine) = canonicalTrigonometry(angle)
        return vector * cosine
            + simd_cross(axis, vector) * sine
            + axis * simd_dot(axis, vector) * (1 - cosine)
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
        sourceWorld: [SIMD3<Float>],
        positions: [SIMD3<Float>]
    ) -> UInt64 {
        let options = options.canonicalized
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
        for position in sourceWorld {
            mix(UInt64(position.x.bitPattern))
            mix(UInt64(position.y.bitPattern))
            mix(UInt64(position.z.bitPattern))
        }
        for position in positions {
            mix(UInt64(position.x.bitPattern))
            mix(UInt64(position.y.bitPattern))
            mix(UInt64(position.z.bitPattern))
        }
        mix(UInt64(estimate.resultingVertexCount))
        mix(UInt64(estimate.resultingTriangleCount))
        mix(UInt64(estimate.resultingComponentCount))
        mix(UInt64(estimate.resultingBoundaryEdgeCount))
        mix(UInt64(estimate.pivotWorld.x.bitPattern))
        mix(UInt64(estimate.pivotWorld.y.bitPattern))
        mix(UInt64(estimate.pivotWorld.z.bitPattern))
        mix(UInt64(estimate.axisWorld.x.bitPattern))
        mix(UInt64(estimate.axisWorld.y.bitPattern))
        mix(UInt64(estimate.axisWorld.z.bitPattern))
        mix(UInt64(estimate.axisVertexCount))
        mix(UInt64(estimate.offAxisVertexCount))
        mix(estimate.minimumPositiveSourceRadiusMillimeters.bitPattern)
        mix(estimate.maximumSourceRadiusMillimeters.bitPattern)
        mix(estimate.axisClassificationToleranceMillimeters.bitPattern)
        mix(estimate.radialToleranceMillimeters.bitPattern)
        mix(estimate.axialToleranceMillimeters.bitPattern)
        mix(estimate.maximumAngularToleranceDegrees.bitPattern)
        mix(estimate.minimumFeatureChordMillimeters.bitPattern)
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
