import Foundation
import simd

struct FaceInsetOptions: Equatable {
    static let defaultDistanceMillimeters = 1.0
    static let minimumDistanceMillimeters = 0.001
    static let maximumDistanceMillimeters = 1_000.0

    var distanceMillimeters = defaultDistanceMillimeters
}

struct FaceInsetEstimate: Equatable {
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
    let addedInsetVertexCount: Int
    let addedRingTriangleCount: Int
    let originalAreaSquareMillimeters: Double
    let insetAreaSquareMillimeters: Double
    let maximumPlanarityDeviationMillimeters: Double
    let estimatedWorkingByteCount: Int
    let resultBounds: AxisAlignedBoundingBox
}

struct FaceInsetSourceKey: Equatable {
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
    let options: FaceInsetOptions
    let analysisFingerprint: UInt64

    func matches(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion,
        options: FaceInsetOptions
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

struct FaceInsetPreview: Equatable {
    let options: FaceInsetOptions
    let estimate: FaceInsetEstimate
    let source: FaceInsetSourceKey
}

struct FaceInsetResult: Equatable {
    let mesh: EditableMesh
    let estimate: FaceInsetEstimate
    let analysisFingerprint: UInt64
}

enum FaceInsetError: Error, Equatable, LocalizedError {
    case noSelection
    case staleSelection
    case invalidDistance
    case distanceTooSmall
    case distanceLimitExceeded
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
    case collapsedInset
    case excessiveMiter
    case interiorVertexOutsideInset
    case innerTriangulationIntersection
    case innerTriangulationLimitExceeded
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
        case .noSelection: "Select at least one face before insetting."
        case .staleSelection: "The selected faces belong to an older mesh topology."
        case .invalidDistance: "Enter a finite positive inset distance in millimeters."
        case .distanceTooSmall: "Inset distance must be at least 0.001 mm."
        case .distanceLimitExceeded: "Inset distance must not exceed 1000 mm."
        case .invalidMesh: "Face Inset found an invalid mesh structure or index."
        case .nonFiniteValue: "Face Inset requires finite vertex positions and normals."
        case .degenerateTriangle: "Face Inset requires the entire mesh to contain no degenerate triangles."
        case .duplicateTriangle: "Face Inset requires the entire mesh to contain no duplicate triangles."
        case .openSelectedEdge: "The selected region touches an open mesh boundary."
        case .nonManifoldSelectedEdge: "The selected region uses a non-manifold edge."
        case .windingConflict: "The selected region has inconsistent edge winding."
        case .invalidBoundary: "Each selected component must have one simple oriented boundary loop."
        case .multipleBoundaryLoops: "Face Inset does not support holes or multiple boundary loops."
        case .nonDiskComponent: "Each selected component must be a disk without handles or holes."
        case .nonPlanarComponent: "Each selected component must be planar in world space."
        case .nonConvexBoundary: "Face Inset currently supports strictly convex boundaries only."
        case .selfIntersectingBoundary: "The selected boundary intersects itself."
        case .collapsedInset: "The inset distance collapses or reverses the inner boundary."
        case .excessiveMiter: "The inset would create an unsafe miter at a sharp corner."
        case .interiorVertexOutsideInset: "An interior selected vertex would fall outside the inset boundary."
        case .innerTriangulationIntersection: "The inset would make inner triangles cross or overlap."
        case .innerTriangulationLimitExceeded: "The selected region is too large for the conservative inner-intersection safety check."
        case .invalidTransform: "The Object Transform is not finite or invertible."
        case .inverseTransformFailure: "The world-space inset could not be converted to object-local coordinates."
        case .selectedFaceLimitExceeded: "Face Inset supports up to 1,000,000 selected triangles."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Inset size calculation overflowed."
        case .workingMemoryLimitExceeded: "Inset would exceed the 768 MiB working-memory limit."
        case .validationFailed: "The inset mesh failed geometry validation."
        case .stalePreview: "The mesh, Transform, selection, or distance changed. Recalculate the preview."
        case .operationInProgress: "Face Inset is already running."
        case .activeEdit: "Finish or prepare the active edit before insetting."
        case .unavailable: "Face Inset is unavailable during the current operation."
        }
    }
}

enum FaceInset {
    static let maximumVertices = MeshCleanup.maximumVertices
    static let maximumTriangles = MeshCleanup.maximumTriangles
    static let maximumSelectedFaces = FaceSelectionConnectivity.maximumTriangleCount
    static let maximumWorkingBytes = MeshCleanup.maximumWorkingBytes
    static let maximumMiterRatio = PlanarFaceRegionGeometry.maximumMiterRatio
    static let maximumInnerIntersectionPairChecks = PlanarFaceRegionGeometry.maximumIntersectionPairChecks

    static func makePreview(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceInsetOptions,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion
    ) throws -> FaceInsetPreview {
        let plan = try PlanarFaceRegionAnalyzer.analyze(
            mesh: mesh, selection: selection, transform: transform,
            widthMillimeters: options.distanceMillimeters)
        return FaceInsetPreview(
            options: options,
            estimate: plan.estimate,
            source: FaceInsetSourceKey(
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
        options: FaceInsetOptions
    ) throws -> FaceInsetEstimate {
        try PlanarFaceRegionAnalyzer.analyze(
            mesh: mesh, selection: selection, transform: transform,
            widthMillimeters: options.distanceMillimeters).estimate
    }

    static func inset(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceInsetOptions
    ) throws -> FaceInsetResult {
        let plan = try PlanarFaceRegionAnalyzer.analyze(
            mesh: mesh, selection: selection, transform: transform,
            widthMillimeters: options.distanceMillimeters)
        let resultMesh = try PlanarFaceRegionMeshBuilder.build(
            source: mesh, analysis: plan,
            innerLocalPositions: plan.components.map(\.insetLocalPositions))
        try validateResult(mesh: resultMesh, plan: plan)
        return FaceInsetResult(mesh: resultMesh, estimate: plan.estimate,
                               analysisFingerprint: plan.fingerprint)
    }

    static func deterministicBasis(normal: SIMD3<Double>) throws -> FaceInsetBasis {
        try PlanarFaceRegionGeometry.deterministicBasis(normal: normal)
    }

    static func insetPolygon(_ polygon: [FaceInsetPoint2D], distance: Double) throws -> [FaceInsetPoint2D] {
        try PlanarFaceRegionGeometry.insetPolygon(polygon, distance: distance)
    }

    static func signedArea(_ polygon: [FaceInsetPoint2D]) -> Double {
        PlanarFaceRegionGeometry.signedArea(polygon)
    }

    static func validateStrictlyConvexSimplePolygon(
        _ polygon: [FaceInsetPoint2D], areaEpsilon: Double? = nil, lengthEpsilon: Double? = nil
    ) throws {
        try PlanarFaceRegionGeometry.validateStrictlyConvexSimplePolygon(
            polygon, areaEpsilon: areaEpsilon, lengthEpsilon: lengthEpsilon)
    }

    static func validateInsetEdgeDistances(
        source: [FaceInsetPoint2D], inset: [FaceInsetPoint2D],
        distance: Double, tolerance: Double
    ) throws {
        try PlanarFaceRegionGeometry.validateInsetEdgeDistances(
            source: source, inset: inset, distance: distance, tolerance: tolerance)
    }

    static func validateInnerTriangulation(
        triangles: [[UInt32]], pointsByVertex: [UInt32: FaceInsetPoint2D],
        areaEpsilon: Double
    ) throws {
        try PlanarFaceRegionGeometry.validateInnerTriangulation(
            triangles: triangles, pointsByVertex: pointsByVertex, areaEpsilon: areaEpsilon)
    }

    static func estimatedWorkingBytes(
        originalVertices: Int, originalTriangles: Int, selectedFaces: Int,
        boundaryEdges: Int, resultingVertices: Int, resultingTriangles: Int
    ) throws -> Int {
        guard [originalVertices, originalTriangles, selectedFaces, boundaryEdges,
               resultingVertices, resultingTriangles].allSatisfy({ $0 >= 0 }) else {
            throw FaceInsetError.arithmeticOverflow
        }
        return try add([
            try multiply(originalVertices, MemoryLayout<MeshVertex>.stride * 3),
            try multiply(originalTriangles, 3 * MemoryLayout<UInt32>.stride * 3),
            try multiply(resultingVertices, MemoryLayout<MeshVertex>.stride * 5),
            try multiply(resultingTriangles, 3 * MemoryLayout<UInt32>.stride * 4),
            try multiply(originalTriangles, 240),
            try multiply(selectedFaces, 160),
            try multiply(boundaryEdges, 192),
            try multiply(resultingVertices, 32),
            try multiply(resultingTriangles, 112)
        ])
    }

    private struct EdgeUse { let faceID: Int; let from: UInt32; let to: UInt32 }
    private struct EdgeRecord { var uses: [EdgeUse] = [] }
    struct ComponentPlan {
        let id: Int
        let faceIDs: [Int]
        let originalVertexIDs: [UInt32]
        let boundaryVertexIDs: [UInt32]
        let insetLocalPositions: [SIMD3<Float>]
        let basis: FaceInsetBasis
        let planeOrigin: SIMD3<Double>
        let sourcePolygon: [FaceInsetPoint2D]
        let actualInsetPointByVertex: [UInt32: FaceInsetPoint2D]
        let floatRoundTripTolerance: Double
        let worldDiagonalLength: Double
        let originalArea: Double
        let insetArea: Double
        let maximumPlanarityDeviation: Double
    }
    struct Plan {
        let originalTriangleCount: Int
        let selectedFaceIDs: [Int]
        let selectedFaces: [Bool]
        let componentByFace: [Int: Int]
        let components: [ComponentPlan]
        let referencedOriginalVertices: [Bool]
        let sourceBoundaryEdgeCount: Int
        let sourceNonManifoldEdgeCount: Int
        let sourceWindingConflictCount: Int
        let resultLocalBounds: AxisAlignedBoundingBox
        let estimate: FaceInsetEstimate
        let fingerprint: UInt64
    }

    static func makePlan(
        mesh: EditableMesh, selection: FaceSelection,
        transform: ObjectTransform, options: FaceInsetOptions
    ) throws -> Plan {
        try validate(options: options)
        guard selection.matches(mesh) else { throw FaceInsetError.staleSelection }
        guard selection.selectedCount > 0 else { throw FaceInsetError.noSelection }
        guard selection.selectedCount <= maximumSelectedFaces else { throw FaceInsetError.selectedFaceLimitExceeded }
        guard mesh.vertices.count >= 3, !mesh.indices.isEmpty, mesh.indices.count.isMultiple(of: 3) else {
            throw FaceInsetError.invalidMesh
        }
        let triangleCount = mesh.indices.count / 3
        guard mesh.vertices.count <= maximumVertices else { throw FaceInsetError.vertexLimitExceeded }
        guard triangleCount <= maximumTriangles else { throw FaceInsetError.triangleLimitExceeded }
        guard mesh.vertices.count < Int(UInt32.max) else { throw FaceInsetError.indexOverflow }
        guard transform.isFinite, matrixIsFinite(transform.modelMatrix), matrixIsFinite(transform.inverseModelMatrix) else {
            throw FaceInsetError.invalidTransform
        }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw FaceInsetError.nonFiniteValue
        }
        let sourceTopology = MeshTopologyDiagnostics.analyze(mesh)
        guard !sourceTopology.hasInvalidStructure, sourceTopology.invalidIndexTriangleCount == 0 else {
            throw FaceInsetError.invalidMesh
        }
        guard sourceTopology.nonFiniteVertexCount == 0 else { throw FaceInsetError.nonFiniteValue }
        guard sourceTopology.degenerateTriangleCount == 0 else { throw FaceInsetError.degenerateTriangle }
        guard sourceTopology.duplicateTriangleCount == 0 else { throw FaceInsetError.duplicateTriangle }

        let selectedFaceIDs = selection.selectedFaceIDs()
        guard selectedFaceIDs.count == selection.selectedCount else { throw FaceInsetError.validationFailed }
        var selectedFaces = Array(repeating: false, count: triangleCount)
        for faceID in selectedFaceIDs {
            guard selectedFaces.indices.contains(faceID) else { throw FaceInsetError.staleSelection }
            selectedFaces[faceID] = true
        }

        var edgeRecords: [DiagnosticEdgeKey: EdgeRecord] = [:]
        edgeRecords.reserveCapacity(try multiply(triangleCount, 2))
        for faceID in 0..<triangleCount {
            let triangle = try triangleIndices(faceID: faceID, mesh: mesh)
            for pair in [(triangle[0], triangle[1]), (triangle[1], triangle[2]), (triangle[2], triangle[0])] {
                edgeRecords[DiagnosticEdgeKey(pair.0, pair.1), default: EdgeRecord()].uses.append(
                    EdgeUse(faceID: faceID, from: pair.0, to: pair.1))
            }
        }

        var adjacency: [Int: [Int]] = [:]
        var boundaryUses: [EdgeUse] = []
        var processed: Set<DiagnosticEdgeKey> = []
        for faceID in selectedFaceIDs {
            let triangle = try triangleIndices(faceID: faceID, mesh: mesh)
            for pair in [(triangle[0], triangle[1]), (triangle[1], triangle[2]), (triangle[2], triangle[0])] {
                let key = DiagnosticEdgeKey(pair.0, pair.1)
                guard processed.insert(key).inserted, let record = edgeRecords[key] else { continue }
                guard record.uses.count == 2 else {
                    if record.uses.count == 1 { throw FaceInsetError.openSelectedEdge }
                    throw FaceInsetError.nonManifoldSelectedEdge
                }
                guard (record.uses[0].from == key.low) != (record.uses[1].from == key.low) else {
                    throw FaceInsetError.windingConflict
                }
                let selectedUses = record.uses.filter { selectedFaces[$0.faceID] }
                if selectedUses.count == 1 { boundaryUses.append(selectedUses[0]) }
                else if selectedUses.count == 2 {
                    adjacency[selectedUses[0].faceID, default: []].append(selectedUses[1].faceID)
                    adjacency[selectedUses[1].faceID, default: []].append(selectedUses[0].faceID)
                } else { throw FaceInsetError.invalidBoundary }
            }
        }
        for key in Array(adjacency.keys) { adjacency[key]?.sort() }

        var componentByFace: [Int: Int] = [:]
        var componentFaces: [[Int]] = []
        for seed in selectedFaceIDs where componentByFace[seed] == nil {
            let componentID = componentFaces.count
            var pending = [seed]
            componentByFace[seed] = componentID
            var faces: [Int] = []
            while let faceID = pending.popLast() {
                faces.append(faceID)
                for neighbor in adjacency[faceID] ?? [] where componentByFace[neighbor] == nil {
                    componentByFace[neighbor] = componentID
                    pending.append(neighbor)
                }
            }
            componentFaces.append(faces.sorted())
        }

        var boundaryByComponent = Array(repeating: [EdgeUse](), count: componentFaces.count)
        for use in boundaryUses {
            guard let componentID = componentByFace[use.faceID] else { throw FaceInsetError.validationFailed }
            boundaryByComponent[componentID].append(use)
        }
        var referencedOriginalVertices = Array(repeating: false, count: mesh.vertices.count)
        for faceID in 0..<triangleCount where !selectedFaces[faceID] {
            for vertexID in try triangleIndices(faceID: faceID, mesh: mesh) { referencedOriginalVertices[Int(vertexID)] = true }
        }
        for use in boundaryUses {
            referencedOriginalVertices[Int(use.from)] = true
            referencedOriginalVertices[Int(use.to)] = true
        }

        var resultLocalBounds = AxisAlignedBoundingBox()
        var resultWorldBounds = AxisAlignedBoundingBox()
        for vertexID in mesh.vertices.indices where referencedOriginalVertices[vertexID] {
            let local = mesh.vertices[vertexID].position
            resultLocalBounds.include(local)
            resultWorldBounds.include(try finiteFloatPosition(worldPosition(local, matrix: transform.modelMatrix)))
        }

        var components: [ComponentPlan] = []
        var selectedUniqueVertices: Set<UInt32> = []
        var totalInteriorVertices = 0
        var totalOriginalArea = 0.0
        var totalInsetArea = 0.0
        var maximumDeviation = 0.0
        for componentID in componentFaces.indices {
            let faces = componentFaces[componentID]
            let boundary = try orderedBoundary(boundaryByComponent[componentID])
            var componentVertices: Set<UInt32> = []
            var componentEdges: Set<DiagnosticEdgeKey> = []
            var areaVector = SIMD3<Double>(repeating: 0)
            var centroidSum = SIMD3<Double>(repeating: 0)
            var worldByVertex: [UInt32: SIMD3<Double>] = [:]
            for faceID in faces {
                let triangle = try triangleIndices(faceID: faceID, mesh: mesh)
                for vertexID in triangle {
                    componentVertices.insert(vertexID)
                    selectedUniqueVertices.insert(vertexID)
                    if worldByVertex[vertexID] == nil {
                        let world = try worldPosition(mesh.vertices[Int(vertexID)].position, matrix: transform.modelMatrix)
                        worldByVertex[vertexID] = world
                        centroidSum += world
                    }
                }
                componentEdges.insert(DiagnosticEdgeKey(triangle[0], triangle[1]))
                componentEdges.insert(DiagnosticEdgeKey(triangle[1], triangle[2]))
                componentEdges.insert(DiagnosticEdgeKey(triangle[2], triangle[0]))
                let a = worldByVertex[triangle[0]]!, b = worldByVertex[triangle[1]]!, c = worldByVertex[triangle[2]]!
                areaVector += simd_cross(b - a, c - a)
            }
            guard componentVertices.count - componentEdges.count + faces.count == 1 else {
                throw FaceInsetError.nonDiskComponent
            }
            let areaLength = simd_length(areaVector)
            guard areaLength.isFinite, areaLength > 1.0e-15 else { throw FaceInsetError.nonPlanarComponent }
            let basis = try deterministicBasis(normal: areaVector / areaLength)
            let origin = centroidSum / Double(componentVertices.count)
            var worldBounds = DoubleBounds()
            for world in worldByVertex.values { worldBounds.include(world) }
            let planarityTolerance = max(worldBounds.diagonalLength * 1.0e-5, 0.000_1)
            var componentMaximumDeviation = 0.0
            var projectedByVertex: [UInt32: FaceInsetPoint2D] = [:]
            for (vertexID, world) in worldByVertex {
                let relative = world - origin
                let deviation = abs(simd_dot(relative, basis.normal))
                componentMaximumDeviation = max(componentMaximumDeviation, deviation)
                projectedByVertex[vertexID] = FaceInsetPoint2D(
                    x: simd_dot(relative, basis.u), y: simd_dot(relative, basis.v))
            }
            guard componentMaximumDeviation <= planarityTolerance else { throw FaceInsetError.nonPlanarComponent }
            let polygon = try boundary.map { vertexID -> FaceInsetPoint2D in
                guard let value = projectedByVertex[vertexID] else { throw FaceInsetError.invalidBoundary }
                return value
            }
            try validateStrictlyConvexSimplePolygon(polygon)
            let insetPolygonPoints = try insetPolygon(polygon, distance: options.distanceMillimeters)
            let polygonArea = signedArea(polygon)
            let insetArea = signedArea(insetPolygonPoints)
            let areaTolerance = max(polygonArea * 1.0e-9, 1.0e-12)
            guard abs(areaLength * 0.5 - polygonArea) <= areaTolerance else {
                throw FaceInsetError.invalidBoundary
            }
            var insetPointByVertex: [UInt32: FaceInsetPoint2D] = [:]
            for (index, vertexID) in boundary.enumerated() { insetPointByVertex[vertexID] = insetPolygonPoints[index] }
            for vertexID in componentVertices where insetPointByVertex[vertexID] == nil {
                insetPointByVertex[vertexID] = projectedByVertex[vertexID]
            }
            let originalVertexIDs = componentVertices.sorted()
            let boundaryIndexByVertex = Dictionary(uniqueKeysWithValues: boundary.enumerated().map { ($0.element, $0.offset) })
            var insetLocalPositions: [SIMD3<Float>] = []
            var actualInsetPointByVertex: [UInt32: FaceInsetPoint2D] = [:]
            insetLocalPositions.reserveCapacity(originalVertexIDs.count)
            actualInsetPointByVertex.reserveCapacity(originalVertexIDs.count)
            for vertexID in originalVertexIDs {
                guard let point = insetPointByVertex[vertexID] else { throw FaceInsetError.validationFailed }
                let destinationWorld = origin + basis.u * point.x + basis.v * point.y
                let local = try localPosition(destinationWorld, matrix: transform.inverseModelMatrix)
                let actualWorld = try worldPosition(local, matrix: transform.modelMatrix)
                let actualRelative = actualWorld - origin
                let actualPoint = FaceInsetPoint2D(
                    x: simd_dot(actualRelative, basis.u), y: simd_dot(actualRelative, basis.v))
                insetLocalPositions.append(local)
                actualInsetPointByVertex[vertexID] = actualPoint
                resultLocalBounds.include(local)
                resultWorldBounds.include(try finiteFloatPosition(actualWorld))
            }
            let actualInsetBoundary = try boundary.map { vertexID -> FaceInsetPoint2D in
                guard let point = actualInsetPointByVertex[vertexID] else { throw FaceInsetError.validationFailed }
                return point
            }
            let maximumCoordinateMagnitude = worldByVertex.values.reduce(0.0) { partial, point in
                max(partial, max(abs(point.x), max(abs(point.y), abs(point.z))))
            }
            let floatRoundTripTolerance = max(
                max(maximumCoordinateMagnitude * Double(Float.ulpOfOne) * 8,
                    worldBounds.diagonalLength * Double(Float.ulpOfOne) * 16),
                max(options.distanceMillimeters * 1.0e-5, 1.0e-6))
            try validateStrictlyConvexSimplePolygon(actualInsetBoundary)
            try validateInsetEdgeDistances(
                source: polygon, inset: actualInsetBoundary,
                distance: options.distanceMillimeters, tolerance: floatRoundTripTolerance)

            let boundarySet = Set(boundary)
            let strictInteriorAreaTolerance = max(
                worldBounds.diagonalLength * worldBounds.diagonalLength * 1.0e-10, 1.0e-12)
            for vertexID in componentVertices where !boundarySet.contains(vertexID) {
                guard let point = actualInsetPointByVertex[vertexID],
                      PlanarFaceRegionGeometry.isInsideConvexPolygon(
                        point, polygon: actualInsetBoundary,
                        epsilon: -strictInteriorAreaTolerance) else {
                    throw FaceInsetError.interiorVertexOutsideInset
                }
            }
            let triangleAreaEpsilon = max(worldBounds.diagonalLength * worldBounds.diagonalLength * 1.0e-12, 1.0e-18)
            let innerTriangles = try faces.map { try triangleIndices(faceID: $0, mesh: mesh) }
            try validateInnerTriangulation(
                triangles: innerTriangles, pointsByVertex: actualInsetPointByVertex,
                areaEpsilon: triangleAreaEpsilon)
            var insetTriangleArea = 0.0
            for triangle in innerTriangles {
                let a = actualInsetPointByVertex[triangle[0]]!
                let b = actualInsetPointByVertex[triangle[1]]!
                let c = actualInsetPointByVertex[triangle[2]]!
                let twiceArea = PlanarFaceRegionGeometry.cross(b - a, c - a)
                guard twiceArea > triangleAreaEpsilon else { throw FaceInsetError.collapsedInset }
                insetTriangleArea += twiceArea * 0.5
            }
            let actualInsetArea = signedArea(actualInsetBoundary)
            guard abs(insetTriangleArea - actualInsetArea) <= max(
                max(actualInsetArea * 1.0e-9,
                    floatRoundTripTolerance * worldBounds.diagonalLength), 1.0e-12
            ) else {
                throw FaceInsetError.collapsedInset
            }
            totalInteriorVertices += componentVertices.count - boundary.count
            totalOriginalArea += polygonArea
            totalInsetArea += insetArea
            maximumDeviation = max(maximumDeviation, componentMaximumDeviation)
            components.append(ComponentPlan(
                id: componentID, faceIDs: faces, originalVertexIDs: originalVertexIDs,
                boundaryVertexIDs: boundary, insetLocalPositions: insetLocalPositions,
                basis: basis, planeOrigin: origin, sourcePolygon: polygon,
                actualInsetPointByVertex: actualInsetPointByVertex,
                floatRoundTripTolerance: floatRoundTripTolerance,
                worldDiagonalLength: worldBounds.diagonalLength,
                originalArea: polygonArea, insetArea: insetArea,
                maximumPlanarityDeviation: componentMaximumDeviation))
        }

        let retainedOriginalCount = referencedOriginalVertices.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        let addedInsetVertexCount = try add(components.map { $0.originalVertexIDs.count })
        let resultingVertexCount = try add([retainedOriginalCount, addedInsetVertexCount])
        let addedRingTriangleCount = try multiply(boundaryUses.count, 2)
        let resultingTriangleCount = try add([triangleCount, addedRingTriangleCount])
        guard resultingVertexCount <= maximumVertices else { throw FaceInsetError.vertexLimitExceeded }
        guard resultingTriangleCount <= maximumTriangles else { throw FaceInsetError.triangleLimitExceeded }
        guard resultingVertexCount < Int(UInt32.max) else { throw FaceInsetError.indexOverflow }
        guard resultLocalBounds.isFinite, resultWorldBounds.isFinite else { throw FaceInsetError.validationFailed }
        let workingBytes = try estimatedWorkingBytes(
            originalVertices: mesh.vertices.count, originalTriangles: triangleCount,
            selectedFaces: selectedFaceIDs.count, boundaryEdges: boundaryUses.count,
            resultingVertices: resultingVertexCount, resultingTriangles: resultingTriangleCount)
        guard workingBytes <= maximumWorkingBytes else { throw FaceInsetError.workingMemoryLimitExceeded }
        let estimate = FaceInsetEstimate(
            originalVertexCount: mesh.vertices.count, originalTriangleCount: triangleCount,
            selectedFaceCount: selectedFaceIDs.count, componentCount: components.count,
            boundaryLoopCount: components.count, boundaryEdgeCount: boundaryUses.count,
            selectedUniqueVertexCount: selectedUniqueVertices.count,
            interiorVertexCount: totalInteriorVertices,
            resultingVertexCount: resultingVertexCount, resultingTriangleCount: resultingTriangleCount,
            removedOriginalVertexCount: mesh.vertices.count - retainedOriginalCount,
            addedInsetVertexCount: addedInsetVertexCount,
            addedRingTriangleCount: addedRingTriangleCount,
            originalAreaSquareMillimeters: totalOriginalArea,
            insetAreaSquareMillimeters: totalInsetArea,
            maximumPlanarityDeviationMillimeters: maximumDeviation,
            estimatedWorkingByteCount: workingBytes, resultBounds: resultWorldBounds)
        let fingerprint = fingerprint(selectedFaceIDs: selectedFaceIDs, components: components, estimate: estimate)
        return Plan(
            originalTriangleCount: triangleCount, selectedFaceIDs: selectedFaceIDs,
            selectedFaces: selectedFaces, componentByFace: componentByFace, components: components,
            referencedOriginalVertices: referencedOriginalVertices,
            sourceBoundaryEdgeCount: sourceTopology.boundaryEdgeCount,
            sourceNonManifoldEdgeCount: sourceTopology.nonManifoldEdgeCount,
            sourceWindingConflictCount: sourceTopology.inconsistentWindingEdgeCount,
            resultLocalBounds: resultLocalBounds, estimate: estimate, fingerprint: fingerprint)
    }

    private static func validate(options: FaceInsetOptions) throws {
        let distance = options.distanceMillimeters
        guard distance.isFinite else { throw FaceInsetError.invalidDistance }
        guard distance >= FaceInsetOptions.minimumDistanceMillimeters else { throw FaceInsetError.distanceTooSmall }
        guard distance <= FaceInsetOptions.maximumDistanceMillimeters else { throw FaceInsetError.distanceLimitExceeded }
    }

    private static func orderedBoundary(_ uses: [EdgeUse]) throws -> [UInt32] {
        guard uses.count >= 3 else { throw FaceInsetError.invalidBoundary }
        var next: [UInt32: UInt32] = [:]
        var incoming: [UInt32: Int] = [:]
        for use in uses {
            guard next[use.from] == nil else { throw FaceInsetError.multipleBoundaryLoops }
            next[use.from] = use.to
            incoming[use.to, default: 0] += 1
        }
        guard next.count == uses.count, incoming.count == uses.count,
              incoming.values.allSatisfy({ $0 == 1 }), let start = next.keys.min() else {
            throw FaceInsetError.invalidBoundary
        }
        var result: [UInt32] = []
        var current = start
        repeat {
            guard result.count < uses.count, let successor = next[current] else {
                throw FaceInsetError.invalidBoundary
            }
            result.append(current)
            current = successor
        } while current != start
        guard result.count == uses.count else { throw FaceInsetError.multipleBoundaryLoops }
        return result
    }

    private static func validateResult(mesh: EditableMesh, plan: Plan) throws {
        try PlanarFaceRegionMeshValidator.validate(
            mesh: mesh,
            expectedVertexCount: plan.estimate.resultingVertexCount,
            expectedTriangleCount: plan.estimate.resultingTriangleCount,
            expectedLocalBounds: plan.resultLocalBounds,
            sourceBoundaryEdgeCount: plan.sourceBoundaryEdgeCount,
            sourceNonManifoldEdgeCount: plan.sourceNonManifoldEdgeCount,
            sourceWindingConflictCount: plan.sourceWindingConflictCount)
    }

    private static func triangleIndices(faceID: Int, mesh: EditableMesh) throws -> [UInt32] {
        let (offset, overflow) = faceID.multipliedReportingOverflow(by: 3)
        let (last, lastOverflow) = offset.addingReportingOverflow(2)
        guard faceID >= 0, !overflow, !lastOverflow, last < mesh.indices.count else { throw FaceInsetError.invalidMesh }
        let result = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
        guard result.allSatisfy({ Int($0) < mesh.vertices.count }) else { throw FaceInsetError.invalidMesh }
        return result
    }

    private static func worldPosition(_ local: SIMD3<Float>, matrix: simd_float4x4) throws -> SIMD3<Double> {
        try PlanarFaceRegionGeometry.worldPosition(local, matrix: matrix)
    }

    private static func localPosition(_ world: SIMD3<Double>, matrix: simd_float4x4) throws -> SIMD3<Float> {
        try PlanarFaceRegionGeometry.localPosition(world, matrix: matrix)
    }

    private static func finiteFloatPosition(_ value: SIMD3<Double>) throws -> SIMD3<Float> {
        try PlanarFaceRegionGeometry.finiteFloatPosition(value)
    }

    private static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        PlanarFaceRegionGeometry.matrixIsFinite(matrix)
    }

    private static func fingerprint(
        selectedFaceIDs: [Int], components: [ComponentPlan], estimate: FaceInsetEstimate
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) { hash ^= value; hash &*= 1_099_511_628_211 }
        selectedFaceIDs.forEach { mix(UInt64($0)) }
        for component in components {
            mix(UInt64(component.id)); component.faceIDs.forEach { mix(UInt64($0)) }
            component.boundaryVertexIDs.forEach { mix(UInt64($0)) }
            component.insetLocalPositions.forEach {
                mix(UInt64($0.x.bitPattern)); mix(UInt64($0.y.bitPattern)); mix(UInt64($0.z.bitPattern))
            }
        }
        mix(UInt64(estimate.resultingVertexCount)); mix(UInt64(estimate.resultingTriangleCount))
        return hash
    }

    private static func add(_ values: [Int]) throws -> Int {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw FaceInsetError.arithmeticOverflow }
            return result
        }
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw FaceInsetError.arithmeticOverflow }
        return result
    }

    private struct DoubleBounds {
        var minimum = SIMD3<Double>(repeating: .infinity)
        var maximum = SIMD3<Double>(repeating: -.infinity)
        mutating func include(_ point: SIMD3<Double>) { minimum = simd_min(minimum, point); maximum = simd_max(maximum, point) }
        var diagonalLength: Double {
            let value = simd_length(maximum - minimum)
            return value.isFinite ? value : 0
        }
    }
}
