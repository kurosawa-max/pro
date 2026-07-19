import Foundation
import simd

struct FaceBevelOptions: Equatable {
    static let defaultWidthMillimeters = 1.0
    static let defaultHeightMillimeters = 0.5
    static let minimumWidthMillimeters = 0.001
    static let maximumWidthMillimeters = 1_000.0
    static let minimumAbsoluteHeightMillimeters = 0.001
    static let maximumAbsoluteHeightMillimeters = 1_000.0

    var widthMillimeters = defaultWidthMillimeters
    var heightMillimeters = defaultHeightMillimeters

    var bevelAngleDegrees: Double {
        atan2(abs(heightMillimeters), widthMillimeters) * 180 / .pi
    }

    var slopeLengthMillimeters: Double {
        hypot(widthMillimeters, heightMillimeters)
    }
}

struct FaceBevelEstimate: Equatable {
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let selectedFaceCount: Int
    let componentCount: Int
    let boundaryLoopCount: Int
    let boundaryEdgeCount: Int
    let selectedUniqueVertexCount: Int
    let interiorVertexCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let removedOriginalVertexCount: Int
    let addedBevelVertexCount: Int
    let addedChamferTriangleCount: Int
    let originalAreaSquareMillimeters: Double
    let innerAreaSquareMillimeters: Double
    let bevelAngleDegrees: Double
    let slopeLengthMillimeters: Double
    let maximumPlanarityDeviationMillimeters: Double
    let estimatedWorkingByteCount: Int
    let resultBounds: AxisAlignedBoundingBox
}

struct FaceBevelSourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: TopologyEditChangeVersion
    let transformChangeVersion: TopologyEditChangeVersion
    let selectionTopologyID: UUID
    let selectionTopologyRevision: UInt64
    let selectionTriangleCount: Int
    let selectionVersion: FaceSelectionVersion
    let selectedFaceCount: Int
    let componentCount: Int
    let boundaryLoopCount: Int
    let transform: ObjectTransform
    let options: FaceBevelOptions
    let analysisFingerprint: UInt64

    func matches(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion,
        options: FaceBevelOptions
    ) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && vertexRevision == mesh.runtime.revision
            && self.meshChangeVersion == meshChangeVersion
            && self.transformChangeVersion == transformChangeVersion
            && selectionTopologyID == selection.sourceTopologyID
            && selectionTopologyRevision == selection.sourceTopologyRevision
            && selectionTriangleCount == selection.triangleCount
            && selectionVersion == selection.version
            && selectedFaceCount == selection.selectedCount
            && self.transform == transform.sanitized()
            && self.options == options
    }
}

struct FaceBevelPreview: Equatable {
    let options: FaceBevelOptions
    let estimate: FaceBevelEstimate
    let source: FaceBevelSourceKey
}

struct FaceBevelResult: Equatable {
    let mesh: EditableMesh
    let estimate: FaceBevelEstimate
    let analysisFingerprint: UInt64
}

enum FaceBevelError: Error, Equatable, LocalizedError {
    case noSelection
    case staleSelection
    case invalidWidth
    case widthTooSmall
    case widthLimitExceeded
    case invalidHeight
    case heightTooSmall
    case heightLimitExceeded
    case invalidMesh
    case nonFiniteValue
    case degenerateTriangle
    case duplicateTriangle
    case openSelectedEdge
    case nonManifoldSelectedEdge
    case windingConflict
    case invalidBoundary
    case multipleBoundaryLoops
    case nonDiskComponent
    case nonPlanarComponent
    case nonConvexBoundary
    case selfIntersectingBoundary
    case collapsedBevel
    case excessiveMiter
    case interiorVertexOutsideInnerBoundary
    case innerTriangulationIntersection
    case innerTriangulationLimitExceeded
    case widthRoundTripFailure
    case heightRoundTripFailure
    case ringValidationFailed
    case invalidTransform
    case inverseTransformFailure
    case selectedFaceLimitExceeded
    case vertexLimitExceeded
    case triangleLimitExceeded
    case indexOverflow
    case arithmeticOverflow
    case workingMemoryLimitExceeded
    case validationFailed
    case stalePreview
    case operationInProgress
    case activeEdit
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noSelection: "Select at least one face before beveling."
        case .staleSelection: "The selected faces belong to an older mesh topology."
        case .invalidWidth: "Enter a finite positive bevel width in millimeters."
        case .widthTooSmall: "Bevel width must be at least 0.001 mm."
        case .widthLimitExceeded: "Bevel width must not exceed 1000 mm."
        case .invalidHeight: "Enter a finite nonzero signed bevel height in millimeters."
        case .heightTooSmall: "Absolute bevel height must be at least 0.001 mm."
        case .heightLimitExceeded: "Absolute bevel height must not exceed 1000 mm."
        case .invalidMesh: "Face Bevel found an invalid mesh structure or index."
        case .nonFiniteValue: "Face Bevel requires finite vertex positions and normals."
        case .degenerateTriangle: "Face Bevel requires the entire mesh to contain no degenerate triangles."
        case .duplicateTriangle: "Face Bevel requires the entire mesh to contain no duplicate triangles."
        case .openSelectedEdge: "The selected region touches an open mesh boundary."
        case .nonManifoldSelectedEdge: "The selected region uses a non-manifold edge."
        case .windingConflict: "The selected region has inconsistent edge winding."
        case .invalidBoundary: "Each selected component must have one simple oriented boundary loop."
        case .multipleBoundaryLoops: "Face Bevel does not support holes or multiple boundary loops."
        case .nonDiskComponent: "Each selected component must be a disk without handles or holes."
        case .nonPlanarComponent: "Each selected component must be planar in world space."
        case .nonConvexBoundary: "Face Bevel currently supports strictly convex boundaries only."
        case .selfIntersectingBoundary: "The selected boundary intersects itself."
        case .collapsedBevel: "The bevel width collapses or reverses the inner boundary."
        case .excessiveMiter: "The bevel would create an unsafe miter at a sharp corner."
        case .interiorVertexOutsideInnerBoundary: "An interior selected vertex would fall outside the inner boundary."
        case .innerTriangulationIntersection: "The bevel would make inner cap triangles cross or overlap."
        case .innerTriangulationLimitExceeded: "The selected region is too large for the conservative inner-intersection safety check."
        case .widthRoundTripFailure: "Stored Float positions cannot preserve the requested world-space bevel width."
        case .heightRoundTripFailure: "Stored Float positions cannot preserve the requested world-space bevel height."
        case .ringValidationFailed: "The chamfer ring failed geometry validation."
        case .invalidTransform: "The Object Transform is not finite or invertible."
        case .inverseTransformFailure: "The world-space bevel could not be converted to object-local coordinates."
        case .selectedFaceLimitExceeded: "Face Bevel supports up to 1,000,000 selected triangles."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Bevel size calculation overflowed."
        case .workingMemoryLimitExceeded: "Bevel would exceed the 768 MiB working-memory limit."
        case .validationFailed: "The bevel mesh failed geometry validation."
        case .stalePreview: "The mesh, Transform, selection, width, or height changed. Recalculate the preview."
        case .operationInProgress: "Face Bevel is already running."
        case .activeEdit: "Finish or prepare the active edit before beveling."
        case .unavailable: "Face Bevel is unavailable during the current operation."
        }
    }
}

enum FaceBevel {
    static let maximumVertices = FaceInset.maximumVertices
    static let maximumTriangles = FaceInset.maximumTriangles
    static let maximumSelectedFaces = FaceInset.maximumSelectedFaces
    static let maximumWorkingBytes = FaceInset.maximumWorkingBytes
    static let maximumInnerIntersectionPairChecks = FaceInset.maximumInnerIntersectionPairChecks

    static func makePreview(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceBevelOptions,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion
    ) throws -> FaceBevelPreview {
        let plan = try makePlan(
            mesh: mesh, selection: selection, transform: transform, options: options)
        return FaceBevelPreview(
            options: options,
            estimate: plan.estimate,
            source: FaceBevelSourceKey(
                topologyID: mesh.runtime.topologyID,
                topologyRevision: mesh.runtime.topologyRevision,
                vertexRevision: mesh.runtime.revision,
                meshChangeVersion: meshChangeVersion,
                transformChangeVersion: transformChangeVersion,
                selectionTopologyID: selection.sourceTopologyID,
                selectionTopologyRevision: selection.sourceTopologyRevision,
                selectionTriangleCount: selection.triangleCount,
                selectionVersion: selection.version,
                selectedFaceCount: selection.selectedCount,
                componentCount: plan.estimate.componentCount,
                boundaryLoopCount: plan.estimate.boundaryLoopCount,
                transform: transform.sanitized(),
                options: options,
                analysisFingerprint: plan.fingerprint))
    }

    static func estimate(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceBevelOptions
    ) throws -> FaceBevelEstimate {
        try makePlan(
            mesh: mesh, selection: selection, transform: transform, options: options).estimate
    }

    static func bevel(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceBevelOptions
    ) throws -> FaceBevelResult {
        let plan = try makePlan(
            mesh: mesh, selection: selection, transform: transform, options: options)
        do {
            let resultMesh = try PlanarFaceRegionMeshBuilder.build(
                source: mesh,
                analysis: plan.analysis,
                innerLocalPositions: plan.innerLocalPositions)
            try PlanarFaceRegionMeshValidator.validate(
                mesh: resultMesh,
                expectedVertexCount: plan.estimate.resultingVertexCount,
                expectedTriangleCount: plan.estimate.resultingTriangleCount,
                expectedLocalBounds: plan.resultLocalBounds,
                sourceBoundaryEdgeCount: plan.analysis.sourceBoundaryEdgeCount,
                sourceNonManifoldEdgeCount: plan.analysis.sourceNonManifoldEdgeCount,
                sourceWindingConflictCount: plan.analysis.sourceWindingConflictCount)
            guard worldBounds(of: resultMesh, transform: transform) == plan.estimate.resultBounds else {
                throw FaceBevelError.validationFailed
            }
            return FaceBevelResult(
                mesh: resultMesh,
                estimate: plan.estimate,
                analysisFingerprint: plan.fingerprint)
        } catch let error as FaceBevelError {
            throw error
        } catch let error as FaceInsetError {
            throw map(error)
        }
    }

    static func estimatedWorkingBytes(
        baseWorkingBytes: Int,
        duplicateVertices: Int,
        boundaryEdges: Int,
        resultingVertices: Int,
        resultingTriangles: Int
    ) throws -> Int {
        guard [baseWorkingBytes, duplicateVertices, boundaryEdges,
               resultingVertices, resultingTriangles].allSatisfy({ $0 >= 0 }) else {
            throw FaceBevelError.arithmeticOverflow
        }
        return try add([
            baseWorkingBytes,
            try multiply(duplicateVertices, 128),
            try multiply(boundaryEdges, 160),
            try multiply(resultingVertices, 32),
            try multiply(resultingTriangles, 24)
        ])
    }

    private struct Plan {
        let analysis: FaceInset.Plan
        let innerLocalPositions: [[SIMD3<Float>]]
        let resultLocalBounds: AxisAlignedBoundingBox
        let estimate: FaceBevelEstimate
        let fingerprint: UInt64
    }

    private static func makePlan(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceBevelOptions
    ) throws -> Plan {
        try validate(options: options)
        let analysis: FaceInset.Plan
        do {
            analysis = try PlanarFaceRegionAnalyzer.analyze(
                mesh: mesh,
                selection: selection,
                transform: transform,
                widthMillimeters: options.widthMillimeters)
        } catch let error as FaceInsetError {
            throw map(error)
        }

        var resultLocalBounds = AxisAlignedBoundingBox()
        var resultWorldBounds = AxisAlignedBoundingBox()
        for vertexID in mesh.vertices.indices where analysis.referencedOriginalVertices[vertexID] {
            let local = mesh.vertices[vertexID].position
            resultLocalBounds.include(local)
            do {
                let world = try PlanarFaceRegionGeometry.worldPosition(
                    local, matrix: transform.modelMatrix)
                resultWorldBounds.include(try PlanarFaceRegionGeometry.finiteFloatPosition(world))
            } catch let error as FaceInsetError {
                throw map(error)
            }
        }

        var positionsByComponent: [[SIMD3<Float>]] = []
        positionsByComponent.reserveCapacity(analysis.components.count)
        for component in analysis.components {
            var localPositions: [SIMD3<Float>] = []
            var actualWorldByVertex: [UInt32: SIMD3<Double>] = [:]
            var actualPointByVertex: [UInt32: FaceInsetPoint2D] = [:]
            localPositions.reserveCapacity(component.originalVertexIDs.count)
            actualWorldByVertex.reserveCapacity(component.originalVertexIDs.count)
            actualPointByVertex.reserveCapacity(component.originalVertexIDs.count)
            var maximumCoordinateMagnitude = 0.0
            for (offset, vertexID) in component.originalVertexIDs.enumerated() {
                do {
                    let insetWorld = try PlanarFaceRegionGeometry.worldPosition(
                        component.insetLocalPositions[offset], matrix: transform.modelMatrix)
                    let destination = insetWorld + component.basis.normal * options.heightMillimeters
                    let local = try PlanarFaceRegionGeometry.localPosition(
                        destination, matrix: transform.inverseModelMatrix)
                    let actualWorld = try PlanarFaceRegionGeometry.worldPosition(
                        local, matrix: transform.modelMatrix)
                    let relative = actualWorld - component.planeOrigin
                    let point = FaceInsetPoint2D(
                        x: simd_dot(relative, component.basis.u),
                        y: simd_dot(relative, component.basis.v))
                    maximumCoordinateMagnitude = max(
                        maximumCoordinateMagnitude,
                        max(abs(actualWorld.x), max(abs(actualWorld.y), abs(actualWorld.z))))
                    localPositions.append(local)
                    actualWorldByVertex[vertexID] = actualWorld
                    actualPointByVertex[vertexID] = point
                    resultLocalBounds.include(local)
                    resultWorldBounds.include(
                        try PlanarFaceRegionGeometry.finiteFloatPosition(actualWorld))
                } catch let error as FaceInsetError {
                    throw map(error)
                }
            }
            let tolerance = max(
                component.floatRoundTripTolerance,
                max(
                    maximumCoordinateMagnitude * Double(Float.ulpOfOne) * 16,
                    max(
                        component.worldDiagonalLength * Double(Float.ulpOfOne) * 24,
                        max(abs(options.heightMillimeters) * 1.0e-5, 1.0e-6))))
            try validateShiftedComponent(
                component: component,
                mesh: mesh,
                transform: transform,
                options: options,
                actualWorldByVertex: actualWorldByVertex,
                actualPointByVertex: actualPointByVertex,
                tolerance: tolerance)
            positionsByComponent.append(localPositions)
        }

        guard resultLocalBounds.isFinite, resultWorldBounds.isFinite else {
            throw FaceBevelError.validationFailed
        }
        let base = analysis.estimate
        let workingBytes = try estimatedWorkingBytes(
            baseWorkingBytes: base.estimatedWorkingByteCount,
            duplicateVertices: base.addedInsetVertexCount,
            boundaryEdges: base.boundaryEdgeCount,
            resultingVertices: base.resultingVertexCount,
            resultingTriangles: base.resultingTriangleCount)
        guard workingBytes <= maximumWorkingBytes else {
            throw FaceBevelError.workingMemoryLimitExceeded
        }
        let estimate = FaceBevelEstimate(
            originalVertexCount: base.originalVertexCount,
            originalTriangleCount: base.originalTriangleCount,
            selectedFaceCount: base.selectedFaceCount,
            componentCount: base.componentCount,
            boundaryLoopCount: base.boundaryLoopCount,
            boundaryEdgeCount: base.boundaryEdgeCount,
            selectedUniqueVertexCount: base.selectedUniqueVertexCount,
            interiorVertexCount: base.interiorVertexCount,
            resultingVertexCount: base.resultingVertexCount,
            resultingTriangleCount: base.resultingTriangleCount,
            removedOriginalVertexCount: base.removedOriginalVertexCount,
            addedBevelVertexCount: base.addedInsetVertexCount,
            addedChamferTriangleCount: base.addedRingTriangleCount,
            originalAreaSquareMillimeters: base.originalAreaSquareMillimeters,
            innerAreaSquareMillimeters: base.insetAreaSquareMillimeters,
            bevelAngleDegrees: options.bevelAngleDegrees,
            slopeLengthMillimeters: options.slopeLengthMillimeters,
            maximumPlanarityDeviationMillimeters: base.maximumPlanarityDeviationMillimeters,
            estimatedWorkingByteCount: workingBytes,
            resultBounds: resultWorldBounds)
        let fingerprint = fingerprint(
            analysis: analysis,
            positions: positionsByComponent,
            options: options,
            estimate: estimate)
        return Plan(
            analysis: analysis,
            innerLocalPositions: positionsByComponent,
            resultLocalBounds: resultLocalBounds,
            estimate: estimate,
            fingerprint: fingerprint)
    }

    private static func validateShiftedComponent(
        component: FaceInset.ComponentPlan,
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: FaceBevelOptions,
        actualWorldByVertex: [UInt32: SIMD3<Double>],
        actualPointByVertex: [UInt32: FaceInsetPoint2D],
        tolerance: Double
    ) throws {
        guard tolerance.isFinite, tolerance >= 0 else { throw FaceBevelError.validationFailed }
        let widthTolerance = min(
            tolerance,
            max(abs(options.widthMillimeters) * 0.02, 1.0e-6))
        let heightTolerance = min(
            tolerance,
            max(abs(options.heightMillimeters) * 0.02, 1.0e-6))
        var minimumHeight = Double.infinity
        var maximumHeight = -Double.infinity
        for vertexID in component.originalVertexIDs {
            guard let world = actualWorldByVertex[vertexID] else {
                throw FaceBevelError.validationFailed
            }
            let height = simd_dot(world - component.planeOrigin, component.basis.normal)
            guard height.isFinite,
                  abs(height - options.heightMillimeters) <= heightTolerance else {
                throw FaceBevelError.heightRoundTripFailure
            }
            minimumHeight = min(minimumHeight, height)
            maximumHeight = max(maximumHeight, height)
        }
        guard maximumHeight - minimumHeight <= heightTolerance * 2 else {
            throw FaceBevelError.heightRoundTripFailure
        }
        let actualBoundary = try component.boundaryVertexIDs.map { vertexID -> FaceInsetPoint2D in
            guard let point = actualPointByVertex[vertexID] else {
                throw FaceBevelError.validationFailed
            }
            return point
        }
        do {
            try PlanarFaceRegionGeometry.validateStrictlyConvexSimplePolygon(actualBoundary)
            try PlanarFaceRegionGeometry.validateInsetEdgeDistances(
                source: component.sourcePolygon,
                inset: actualBoundary,
                distance: options.widthMillimeters,
                tolerance: widthTolerance)
        } catch let error as FaceInsetError {
            if error == .collapsedInset { throw FaceBevelError.widthRoundTripFailure }
            throw map(error)
        }

        let boundarySet = Set(component.boundaryVertexIDs)
        let strictInteriorTolerance = max(
            component.worldDiagonalLength * component.worldDiagonalLength * 1.0e-10,
            1.0e-12)
        for vertexID in component.originalVertexIDs where !boundarySet.contains(vertexID) {
            guard let point = actualPointByVertex[vertexID],
                  PlanarFaceRegionGeometry.isInsideConvexPolygon(
                    point, polygon: actualBoundary, epsilon: -strictInteriorTolerance) else {
                throw FaceBevelError.interiorVertexOutsideInnerBoundary
            }
        }
        let triangles = try component.faceIDs.map {
            try triangleIndices(faceID: $0, mesh: mesh)
        }
        let areaEpsilon = max(
            component.worldDiagonalLength * component.worldDiagonalLength * 1.0e-12,
            1.0e-18)
        do {
            try PlanarFaceRegionGeometry.validateInnerTriangulation(
                triangles: triangles,
                pointsByVertex: actualPointByVertex,
                areaEpsilon: areaEpsilon)
        } catch let error as FaceInsetError {
            throw map(error)
        }
        var triangleArea = 0.0
        for triangle in triangles {
            guard let a = actualPointByVertex[triangle[0]],
                  let b = actualPointByVertex[triangle[1]],
                  let c = actualPointByVertex[triangle[2]] else {
                throw FaceBevelError.validationFailed
            }
            let twiceArea = PlanarFaceRegionGeometry.cross(b - a, c - a)
            guard twiceArea > areaEpsilon else { throw FaceBevelError.collapsedBevel }
            triangleArea += twiceArea * 0.5
        }
        let innerArea = PlanarFaceRegionGeometry.signedArea(actualBoundary)
        guard abs(triangleArea - innerArea) <= max(
            max(innerArea * 1.0e-9, tolerance * component.worldDiagonalLength),
            1.0e-12) else {
            throw FaceBevelError.innerTriangulationIntersection
        }
        try validateRing(
            component: component,
            mesh: mesh,
            transform: transform,
            actualWorldByVertex: actualWorldByVertex,
            options: options,
            widthTolerance: widthTolerance,
            heightTolerance: heightTolerance,
            geometryTolerance: tolerance)
    }

    private static func validateRing(
        component: FaceInset.ComponentPlan,
        mesh: EditableMesh,
        transform: ObjectTransform,
        actualWorldByVertex: [UInt32: SIMD3<Double>],
        options: FaceBevelOptions,
        widthTolerance: Double,
        heightTolerance: Double,
        geometryTolerance: Double
    ) throws {
        let loop = component.boundaryVertexIDs
        let expectedSlope = options.slopeLengthMillimeters
        let slopeTolerance = min(
            geometryTolerance * 2,
            max(expectedSlope * 0.02, 2.0e-6))
        let areaEpsilon = max(
            component.worldDiagonalLength * component.worldDiagonalLength * 1.0e-12,
            1.0e-18)
        for index in loop.indices {
            let aID = loop[index]
            let bID = loop[(index + 1) % loop.count]
            guard Int(aID) < mesh.vertices.count, Int(bID) < mesh.vertices.count,
                  let innerA = actualWorldByVertex[aID],
                  let innerB = actualWorldByVertex[bID] else {
                throw FaceBevelError.ringValidationFailed
            }
            let outerA: SIMD3<Double>
            let outerB: SIMD3<Double>
            do {
                outerA = try PlanarFaceRegionGeometry.worldPosition(
                    mesh.vertices[Int(aID)].position, matrix: transform.modelMatrix)
                outerB = try PlanarFaceRegionGeometry.worldPosition(
                    mesh.vertices[Int(bID)].position, matrix: transform.modelMatrix)
            } catch let error as FaceInsetError {
                throw map(error)
            }
            let sourceEdge = outerB - outerA
            let actualInnerEdge = innerB - innerA
            let sourceLength = simd_length(sourceEdge)
            let innerLength = simd_length(actualInnerEdge)
            guard sourceLength.isFinite, innerLength.isFinite,
                  sourceLength > 0, innerLength > 0 else {
                throw FaceBevelError.ringValidationFailed
            }
            let sourceDirection = sourceEdge / sourceLength
            let innerDirection = actualInnerEdge / innerLength
            let directionError = simd_length(simd_cross(sourceDirection, innerDirection))
            let directionTolerance = min(
                0.01,
                max(widthTolerance / max(sourceLength, innerLength), 1.0e-7))
            guard directionError.isFinite, directionError <= directionTolerance,
                  simd_dot(sourceDirection, innerDirection) > 0 else {
                throw FaceBevelError.ringValidationFailed
            }

            let firstNormal = simd_cross(sourceEdge, innerB - outerA)
            let secondNormal = simd_cross(innerB - outerA, innerA - outerA)
            let firstArea = simd_length(firstNormal)
            let secondArea = simd_length(secondNormal)
            guard firstArea.isFinite, secondArea.isFinite,
                  firstArea > areaEpsilon, secondArea > areaEpsilon else {
                throw FaceBevelError.ringValidationFailed
            }
            let normal = component.basis.normal
            let inward = simd_cross(normal, sourceDirection)
            guard simd_dot(firstNormal, normal) > areaEpsilon,
                  simd_dot(secondNormal, normal) > areaEpsilon else {
                throw FaceBevelError.ringValidationFailed
            }

            let expectedInwardSign = options.heightMillimeters > 0 ? -1.0 : 1.0
            let firstFacing = simd_dot(firstNormal, inward) * expectedInwardSign
            let secondFacing = simd_dot(secondNormal, inward) * expectedInwardSign
            guard firstFacing > areaEpsilon, secondFacing > areaEpsilon else {
                throw FaceBevelError.ringValidationFailed
            }

            // The constant-width slope is the cross-section perpendicular to
            // corresponding outer and inner edges. Corner-to-corner distance
            // includes the polygon miter and is intentionally not constant.
            let innerCrossSectionPoint = innerA
                + sourceDirection * simd_dot(outerA - innerA, sourceDirection)
            let actualCrossSection = innerCrossSectionPoint - outerA
            let actualHeight = simd_dot(actualCrossSection, normal)
            let inPlane = actualCrossSection - normal * actualHeight
            let actualWidth = simd_dot(inPlane, inward)
            let actualSlope = simd_length(actualCrossSection)
            guard actualWidth.isFinite, actualHeight.isFinite, actualSlope.isFinite,
                  abs(actualWidth - options.widthMillimeters) <= widthTolerance,
                  abs(actualHeight - options.heightMillimeters) <= heightTolerance,
                  abs(actualSlope - expectedSlope) <= slopeTolerance else {
                throw FaceBevelError.ringValidationFailed
            }
        }
    }

    private static func validate(options: FaceBevelOptions) throws {
        let width = options.widthMillimeters
        guard width.isFinite else { throw FaceBevelError.invalidWidth }
        guard width >= FaceBevelOptions.minimumWidthMillimeters else {
            throw FaceBevelError.widthTooSmall
        }
        guard width <= FaceBevelOptions.maximumWidthMillimeters else {
            throw FaceBevelError.widthLimitExceeded
        }
        let height = options.heightMillimeters
        guard height.isFinite else { throw FaceBevelError.invalidHeight }
        guard abs(height) >= FaceBevelOptions.minimumAbsoluteHeightMillimeters else {
            throw FaceBevelError.heightTooSmall
        }
        guard abs(height) <= FaceBevelOptions.maximumAbsoluteHeightMillimeters else {
            throw FaceBevelError.heightLimitExceeded
        }
        guard options.bevelAngleDegrees.isFinite,
              options.bevelAngleDegrees > 0,
              options.bevelAngleDegrees < 90,
              options.slopeLengthMillimeters.isFinite else {
            throw FaceBevelError.invalidHeight
        }
    }

    private static func triangleIndices(faceID: Int, mesh: EditableMesh) throws -> [UInt32] {
        let (offset, overflow) = faceID.multipliedReportingOverflow(by: 3)
        let (last, lastOverflow) = offset.addingReportingOverflow(2)
        guard faceID >= 0, !overflow, !lastOverflow, last < mesh.indices.count else {
            throw FaceBevelError.invalidMesh
        }
        let result = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
        guard result.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw FaceBevelError.invalidMesh
        }
        return result
    }

    private static func worldBounds(
        of mesh: EditableMesh, transform: ObjectTransform
    ) -> AxisAlignedBoundingBox {
        var bounds = AxisAlignedBoundingBox()
        for vertex in mesh.vertices {
            bounds.include(transform.worldPosition(fromLocal: vertex.position))
        }
        return bounds
    }

    private static func fingerprint(
        analysis: FaceInset.Plan,
        positions: [[SIMD3<Float>]],
        options: FaceBevelOptions,
        estimate: FaceBevelEstimate
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) { hash ^= value; hash &*= 1_099_511_628_211 }
        mix(analysis.fingerprint)
        mix(options.widthMillimeters.bitPattern)
        mix(options.heightMillimeters.bitPattern)
        for component in positions {
            for position in component {
                mix(UInt64(position.x.bitPattern))
                mix(UInt64(position.y.bitPattern))
                mix(UInt64(position.z.bitPattern))
            }
        }
        mix(UInt64(estimate.resultingVertexCount))
        mix(UInt64(estimate.resultingTriangleCount))
        return hash
    }

    private static func map(_ error: FaceInsetError) -> FaceBevelError {
        switch error {
        case .noSelection: .noSelection
        case .staleSelection: .staleSelection
        case .invalidDistance: .invalidWidth
        case .distanceTooSmall: .widthTooSmall
        case .distanceLimitExceeded: .widthLimitExceeded
        case .invalidMesh: .invalidMesh
        case .nonFiniteValue: .nonFiniteValue
        case .degenerateTriangle: .degenerateTriangle
        case .duplicateTriangle: .duplicateTriangle
        case .openSelectedEdge: .openSelectedEdge
        case .nonManifoldSelectedEdge: .nonManifoldSelectedEdge
        case .windingConflict: .windingConflict
        case .invalidBoundary: .invalidBoundary
        case .multipleBoundaryLoops: .multipleBoundaryLoops
        case .nonDiskComponent: .nonDiskComponent
        case .nonPlanarComponent: .nonPlanarComponent
        case .nonConvexBoundary: .nonConvexBoundary
        case .selfIntersectingBoundary: .selfIntersectingBoundary
        case .collapsedInset: .collapsedBevel
        case .excessiveMiter: .excessiveMiter
        case .interiorVertexOutsideInset: .interiorVertexOutsideInnerBoundary
        case .innerTriangulationIntersection: .innerTriangulationIntersection
        case .innerTriangulationLimitExceeded: .innerTriangulationLimitExceeded
        case .invalidTransform: .invalidTransform
        case .inverseTransformFailure: .inverseTransformFailure
        case .selectedFaceLimitExceeded: .selectedFaceLimitExceeded
        case .vertexLimitExceeded: .vertexLimitExceeded
        case .triangleLimitExceeded: .triangleLimitExceeded
        case .indexOverflow: .indexOverflow
        case .arithmeticOverflow: .arithmeticOverflow
        case .workingMemoryLimitExceeded: .workingMemoryLimitExceeded
        case .validationFailed: .validationFailed
        case .stalePreview: .stalePreview
        case .operationInProgress: .operationInProgress
        case .activeEdit: .activeEdit
        case .unavailable: .unavailable
        }
    }

    private static func add(_ values: [Int]) throws -> Int {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw FaceBevelError.arithmeticOverflow }
            return result
        }
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw FaceBevelError.arithmeticOverflow }
        return result
    }
}
