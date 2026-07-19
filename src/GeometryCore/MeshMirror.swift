import Foundation
import simd

enum MirrorAxis: String, CaseIterable, Identifiable {
    case x = "X"
    case y = "Y"
    case z = "Z"

    var id: Self { self }

    fileprivate var componentIndex: Int {
        switch self {
        case .x: 0
        case .y: 1
        case .z: 2
        }
    }

    fileprivate func reflected(_ position: SIMD3<Float>) -> SIMD3<Float> {
        var result = position
        result[componentIndex] = -result[componentIndex]
        if result[componentIndex] == 0 { result[componentIndex] = 0 }
        return result
    }
}

enum MeshMirrorSourceSide: String, Equatable {
    case positive = "Positive"
    case negative = "Negative"
}

struct MeshMirrorOptions: Equatable {
    var axis: MirrorAxis = .x
}

struct MeshMirrorEstimate: Equatable {
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let sourceComponentCount: Int
    let closedComponentCount: Int
    let openComponentCount: Int
    let seamLoopCount: Int
    let boundaryEdgeCount: Int
    let seamVertexCount: Int
    let snappedVertexCount: Int
    let maximumSeamSnapDistance: Float
    let mirroredVertexCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let resultingComponentCount: Int
    let sourceSide: MeshMirrorSourceSide
    let seamTolerance: Float
    let resultLocalBounds: AxisAlignedBoundingBox
    let resultWorldBounds: AxisAlignedBoundingBox
    let estimatedWorkingByteCount: Int
}

struct MeshMirrorSourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: TopologyEditChangeVersion
    let transformChangeVersion: TopologyEditChangeVersion
    let transform: ObjectTransform
    let options: MeshMirrorOptions
    let sourceSide: MeshMirrorSourceSide
    let sourceComponentCount: Int
    let closedComponentCount: Int
    let openComponentCount: Int
    let seamLoopCount: Int
    let boundaryEdgeCount: Int
    let seamVertexCount: Int
    let maximumSeamSnapDistance: Float
    let seamTolerance: Float
    let analysisFingerprint: UInt64

    func matches(
        mesh: EditableMesh,
        transform: ObjectTransform,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion,
        options: MeshMirrorOptions
    ) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && vertexRevision == mesh.runtime.revision
            && self.meshChangeVersion == meshChangeVersion
            && self.transformChangeVersion == transformChangeVersion
            && self.transform == transform.sanitized()
            && self.options == options
    }
}

struct MeshMirrorPreview: Equatable {
    let options: MeshMirrorOptions
    let estimate: MeshMirrorEstimate
    let source: MeshMirrorSourceKey
}

struct MeshMirrorResult: Equatable {
    let mesh: EditableMesh
    let estimate: MeshMirrorEstimate
    let analysisFingerprint: UInt64
}

enum MeshMirrorError: Error, Equatable, LocalizedError {
    case invalidMesh
    case nonFiniteValue
    case degenerateTriangle
    case duplicateTriangle
    case nonManifoldEdge
    case windingConflict
    case isolatedVertex
    case noOffPlaneVertices
    case crossesMirrorPlane
    case mixedSourceSides
    case closedComponentTouchesPlane
    case openBoundaryOffPlane
    case seamInteriorEdge
    case seamInteriorVertex
    case seamTriangle
    case invalidSeamLoop
    case seamSnapCollision
    case seamSnapWouldCollapseTriangle
    case seamSnapWouldCreateDuplicateTriangle
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
        case .invalidMesh: "Mirror Copy requires a nonempty, valid triangle mesh."
        case .nonFiniteValue: "Mirror Copy requires finite vertex positions and normals."
        case .degenerateTriangle: "The source already contains degenerate triangles. Review Mesh Diagnostics or run Mesh Cleanup before retrying."
        case .duplicateTriangle: "The source already contains duplicate triangles. Review Mesh Diagnostics or run Mesh Cleanup before retrying."
        case .nonManifoldEdge: "Mirror Copy requires manifold source edges."
        case .windingConflict: "Mirror Copy requires consistent triangle winding."
        case .isolatedVertex: "Mirror Copy requires every vertex to be referenced by a triangle."
        case .noOffPlaneVertices: "The mesh has no vertices away from the selected mirror plane."
        case .crossesMirrorPlane: "The mesh crosses the selected local mirror plane. Split it first."
        case .mixedSourceSides: "All off-plane vertices must be on the same side of the mirror plane."
        case .closedComponentTouchesPlane: "A closed component may not touch the mirror plane."
        case .openBoundaryOffPlane: "Every boundary edge of an open half mesh must lie on the mirror plane."
        case .seamInteriorEdge: "An edge on the mirror plane is used as an interior edge."
        case .seamInteriorVertex: "Every mirror-plane vertex of an open component must belong to its boundary."
        case .seamTriangle: "A triangle lying on the mirror plane cannot be mirrored safely."
        case .invalidSeamLoop: "The mirror-plane boundary must consist of closed, unbranched degree-two loops."
        case .seamSnapCollision: "Snapping the seam would merge distinct source vertices. Adjust the axis or geometry before retrying."
        case .seamSnapWouldCollapseTriangle: "Snapping the accepted seam to the plane would collapse a triangle. Adjust the axis or geometry before retrying."
        case .seamSnapWouldCreateDuplicateTriangle: "Snapping the accepted seam to the plane would create duplicate triangles. Adjust the axis or geometry before retrying."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Mirror Copy size calculation overflowed."
        case .workingMemoryLimitExceeded: "Mirror Copy would exceed the 768 MiB working-memory limit."
        case .validationFailed: "The mirrored mesh failed geometry or symmetry validation."
        case .stalePreview: "The mesh, Transform, axis, or analyzed source changed. Recalculate the preview."
        case .operationInProgress: "Mirror Copy is already running."
        case .activeEdit: "Finish or prepare the active edit before mirroring."
        case .unavailable: "Mirror Copy is unavailable during the current operation."
        }
    }
}

enum MeshMirror {
    static let maximumVertices = MeshCleanup.maximumVertices
    static let maximumTriangles = MeshCleanup.maximumTriangles
    static let maximumWorkingBytes = MeshCleanup.maximumWorkingBytes

    static func makePreview(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshMirrorOptions,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion
    ) throws -> MeshMirrorPreview {
        let plan = try makePlan(mesh: mesh, transform: transform, options: options)
        return MeshMirrorPreview(
            options: options,
            estimate: plan.estimate,
            source: MeshMirrorSourceKey(
                topologyID: mesh.runtime.topologyID,
                topologyRevision: mesh.runtime.topologyRevision,
                vertexRevision: mesh.runtime.revision,
                meshChangeVersion: meshChangeVersion,
                transformChangeVersion: transformChangeVersion,
                transform: transform.sanitized(),
                options: options,
                sourceSide: plan.estimate.sourceSide,
                sourceComponentCount: plan.estimate.sourceComponentCount,
                closedComponentCount: plan.estimate.closedComponentCount,
                openComponentCount: plan.estimate.openComponentCount,
                seamLoopCount: plan.estimate.seamLoopCount,
                boundaryEdgeCount: plan.estimate.boundaryEdgeCount,
                seamVertexCount: plan.estimate.seamVertexCount,
                maximumSeamSnapDistance: plan.estimate.maximumSeamSnapDistance,
                seamTolerance: plan.estimate.seamTolerance,
                analysisFingerprint: plan.fingerprint))
    }

    static func estimate(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshMirrorOptions
    ) throws -> MeshMirrorEstimate {
        try makePlan(mesh: mesh, transform: transform, options: options).estimate
    }

    static func analysisStatistics(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshMirrorOptions
    ) throws -> MeshMirrorAnalysisStatistics {
        try makePlan(mesh: mesh, transform: transform, options: options).statistics
    }

    static func mirror(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshMirrorOptions
    ) throws -> MeshMirrorResult {
        let plan = try makePlan(mesh: mesh, transform: transform, options: options)
        var resultVertices = plan.snappedVertices
        resultVertices.reserveCapacity(plan.estimate.resultingVertexCount)
        var mirrorMap = Array<UInt32?>(repeating: nil, count: plan.snappedVertices.count)

        for vertexID in plan.snappedVertices.indices {
            if plan.isSeam[vertexID] {
                mirrorMap[vertexID] = UInt32(vertexID)
            } else {
                guard resultVertices.count < Int(UInt32.max) else { throw MeshMirrorError.indexOverflow }
                mirrorMap[vertexID] = UInt32(resultVertices.count)
                let source = plan.snappedVertices[vertexID]
                resultVertices.append(MeshVertex(
                    position: options.axis.reflected(source.position),
                    normal: options.axis.reflected(source.normal)))
            }
        }

        var resultIndices = mesh.indices
        resultIndices.reserveCapacity(plan.estimate.resultingTriangleCount * 3)
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[offset])
            let b = Int(mesh.indices[offset + 1])
            let c = Int(mesh.indices[offset + 2])
            guard let ma = mirrorMap[a], let mb = mirrorMap[b], let mc = mirrorMap[c] else {
                throw MeshMirrorError.validationFailed
            }
            resultIndices.append(contentsOf: [ma, mc, mb])
        }

        var result = EditableMesh(vertices: resultVertices, indices: resultIndices)
        result.recalculateNormals()
        _ = result.adjacency()
        try validateResult(
            result, source: mesh, transform: transform,
            plan: plan, mirrorMap: mirrorMap, options: options)
        return MeshMirrorResult(
            mesh: result,
            estimate: plan.estimate,
            analysisFingerprint: plan.fingerprint)
    }

    fileprivate struct Plan {
        let snappedVertices: [MeshVertex]
        let isSeam: [Bool]
        let estimate: MeshMirrorEstimate
        let fingerprint: UInt64
        let statistics: MeshMirrorAnalysisStatistics
    }

    struct MeshMirrorAnalysisStatistics: Equatable {
        let uniqueEdgeCount: Int
        let edgeGroupingVisitCount: Int
        let componentEdgeVisitCount: Int
    }

    private struct EdgeUse {
        let faceID: Int
        let from: UInt32
        let to: UInt32
    }

    private struct ComponentPlan {
        let faceIDs: [Int]
        let edgeKeys: [DiagnosticEdgeKey]
        let boundaryEdges: [DiagnosticEdgeKey]
        let seamVertexIDs: [Int]
        let seamLoopCount: Int
        let isClosed: Bool
    }

    private struct ComponentAnalysis {
        let edges: [DiagnosticEdgeKey: [EdgeUse]]
        let edgeOrder: [DiagnosticEdgeKey]
        let components: [ComponentPlan]
        let statistics: MeshMirrorAnalysisStatistics
    }

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

    private enum Side: Equatable { case seam, positive, negative }

    private static func makePlan(
        mesh: EditableMesh,
        transform: ObjectTransform,
        options: MeshMirrorOptions
    ) throws -> Plan {
        guard transform.isFinite else { throw MeshMirrorError.nonFiniteValue }
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3) else { throw MeshMirrorError.invalidMesh }
        let sourceTriangleCount = mesh.indices.count / 3
        guard mesh.vertices.count <= maximumVertices else { throw MeshMirrorError.vertexLimitExceeded }
        guard sourceTriangleCount <= maximumTriangles else { throw MeshMirrorError.triangleLimitExceeded }
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        guard !topology.hasInvalidStructure, topology.invalidIndexTriangleCount == 0 else {
            throw MeshMirrorError.invalidMesh
        }
        guard topology.nonFiniteVertexCount == 0 else { throw MeshMirrorError.nonFiniteValue }
        guard topology.degenerateTriangleCount == 0 else { throw MeshMirrorError.degenerateTriangle }
        guard topology.duplicateTriangleCount == 0 else { throw MeshMirrorError.duplicateTriangle }
        guard try hasGeometricDuplicateTriangles(
            vertices: mesh.vertices, indices: mesh.indices
        ) == false else { throw MeshMirrorError.duplicateTriangle }
        guard topology.nonManifoldEdgeCount == 0 else { throw MeshMirrorError.nonManifoldEdge }
        guard topology.inconsistentWindingEdgeCount == 0 else { throw MeshMirrorError.windingConflict }
        guard topology.isolatedVertexCount == 0 else { throw MeshMirrorError.isolatedVertex }

        let tolerance = seamTolerance(mesh: mesh, axis: options.axis)
        guard tolerance.isFinite, tolerance > 0 else { throw MeshMirrorError.validationFailed }
        var sides: [Side] = []
        sides.reserveCapacity(mesh.vertices.count)
        var hasPositive = false
        var hasNegative = false
        for vertex in mesh.vertices {
            let coordinate = vertex.position[options.axis.componentIndex]
            let side: Side
            if abs(coordinate) <= tolerance { side = .seam }
            else if coordinate > 0 { side = .positive; hasPositive = true }
            else { side = .negative; hasNegative = true }
            sides.append(side)
        }
        guard hasPositive || hasNegative else { throw MeshMirrorError.noOffPlaneVertices }
        if hasPositive && hasNegative {
            for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
                let triangleSides = [
                    sides[Int(mesh.indices[offset])],
                    sides[Int(mesh.indices[offset + 1])],
                    sides[Int(mesh.indices[offset + 2])],
                ]
                if triangleSides.contains(.positive) && triangleSides.contains(.negative) {
                    throw MeshMirrorError.crossesMirrorPlane
                }
            }
            throw MeshMirrorError.mixedSourceSides
        }
        let sourceSide: MeshMirrorSourceSide = hasPositive ? .positive : .negative

        var snappedVertices = mesh.vertices
        var snappedCount = 0
        var maximumSeamSnapDistance: Float = 0
        var snappedPositions: [PositionKey: Int] = [:]
        snappedPositions.reserveCapacity(mesh.vertices.count)
        for vertexID in snappedVertices.indices {
            let original = mesh.vertices[vertexID].position
            if sides[vertexID] == .seam {
                let distance = abs(original[options.axis.componentIndex])
                guard distance.isFinite, distance <= tolerance else {
                    throw MeshMirrorError.validationFailed
                }
                maximumSeamSnapDistance = max(maximumSeamSnapDistance, distance)
                if distance != 0 { snappedCount += 1 }
                snappedVertices[vertexID].position[options.axis.componentIndex] = 0
            }
        }
        try validateSnappedSource(
            source: mesh,
            snappedVertices: snappedVertices)
        for vertexID in snappedVertices.indices {
            let original = mesh.vertices[vertexID].position
            let key = PositionKey(snappedVertices[vertexID].position)
            if let previous = snappedPositions[key],
               PositionKey(mesh.vertices[previous].position) != PositionKey(original),
               (sides[previous] == .seam || sides[vertexID] == .seam) {
                throw MeshMirrorError.seamSnapCollision
            }
            snappedPositions[key] = vertexID
        }

        let analysis = try analyzeComponents(mesh: mesh, sides: sides)
        let edges = analysis.edges
        let edgeOrder = analysis.edgeOrder
        let components = analysis.components
        var closedCount = 0
        var openCount = 0
        var seamLoopCount = 0
        var boundaryEdgeCount = 0
        var seamVertexIDs = Set<Int>()
        for component in components {
            if component.isClosed { closedCount += 1 }
            else { openCount += 1 }
            seamLoopCount += component.seamLoopCount
            boundaryEdgeCount += component.boundaryEdges.count
            seamVertexIDs.formUnion(component.seamVertexIDs)
        }

        let offPlaneCount = mesh.vertices.count - seamVertexIDs.count
        let resultingVertices = try add(mesh.vertices.count, offPlaneCount)
        let sourceTriangles = sourceTriangleCount
        let resultingTriangles = try multiply(sourceTriangles, 2)
        guard resultingVertices <= maximumVertices else { throw MeshMirrorError.vertexLimitExceeded }
        guard resultingTriangles <= maximumTriangles else { throw MeshMirrorError.triangleLimitExceeded }
        guard resultingVertices <= Int(UInt32.max) else { throw MeshMirrorError.indexOverflow }
        let workingBytes = try estimatedWorkingBytes(
            sourceVertices: mesh.vertices.count,
            sourceTriangles: sourceTriangles,
            uniqueEdges: edges.count,
            resultingVertices: resultingVertices,
            resultingTriangles: resultingTriangles)
        guard workingBytes <= maximumWorkingBytes else { throw MeshMirrorError.workingMemoryLimitExceeded }

        var localBounds = AxisAlignedBoundingBox()
        var worldBounds = AxisAlignedBoundingBox()
        for vertex in snappedVertices {
            localBounds.include(vertex.position)
            localBounds.include(options.axis.reflected(vertex.position))
            let first = transform.worldPosition(fromLocal: vertex.position)
            let second = transform.worldPosition(fromLocal: options.axis.reflected(vertex.position))
            guard first.allFinite, second.allFinite else { throw MeshMirrorError.validationFailed }
            worldBounds.include(first)
            worldBounds.include(second)
        }
        guard localBounds.isFinite, worldBounds.isFinite else { throw MeshMirrorError.validationFailed }

        let resultingComponentCount = try add(openCount, try multiply(closedCount, 2))
        let estimate = MeshMirrorEstimate(
            originalVertexCount: mesh.vertices.count,
            originalTriangleCount: sourceTriangles,
            sourceComponentCount: components.count,
            closedComponentCount: closedCount,
            openComponentCount: openCount,
            seamLoopCount: seamLoopCount,
            boundaryEdgeCount: boundaryEdgeCount,
            seamVertexCount: seamVertexIDs.count,
            snappedVertexCount: snappedCount,
            maximumSeamSnapDistance: maximumSeamSnapDistance,
            mirroredVertexCount: offPlaneCount,
            resultingVertexCount: resultingVertices,
            resultingTriangleCount: resultingTriangles,
            resultingComponentCount: resultingComponentCount,
            sourceSide: sourceSide,
            seamTolerance: tolerance,
            resultLocalBounds: localBounds,
            resultWorldBounds: worldBounds,
            estimatedWorkingByteCount: workingBytes)
        let fingerprint = fingerprint(
            mesh: mesh, axis: options.axis, sides: sides, components: components,
            edgeOrder: edgeOrder, tolerance: tolerance, sourceSide: sourceSide, estimate: estimate)
        return Plan(
            snappedVertices: snappedVertices,
            isSeam: sides.map { $0 == .seam },
            estimate: estimate,
            fingerprint: fingerprint,
            statistics: analysis.statistics)
    }

    private static func analyzeComponents(
        mesh: EditableMesh,
        sides: [Side]
    ) throws -> ComponentAnalysis {
        let triangleCount = mesh.indices.count / 3
        var edges: [DiagnosticEdgeKey: [EdgeUse]] = [:]
        edges.reserveCapacity(mesh.indices.count)
        var edgeOrder: [DiagnosticEdgeKey] = []
        var union = MirrorUnionFind(count: triangleCount)
        var seamTriangleByFace = Array(repeating: false, count: triangleCount)
        for faceID in 0..<triangleCount {
            let offset = faceID * 3
            let ids = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
            guard ids.allSatisfy({ Int($0) < mesh.vertices.count }) else { throw MeshMirrorError.invalidMesh }
            seamTriangleByFace[faceID] = ids.allSatisfy { sides[Int($0)] == .seam }
            for (from, to) in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
                let key = DiagnosticEdgeKey(from, to)
                if let first = edges[key]?.first { union.union(faceID, first.faceID) }
                else { edgeOrder.append(key) }
                edges[key, default: []].append(EdgeUse(faceID: faceID, from: from, to: to))
            }
        }

        var facesByRoot: [Int: [Int]] = [:]
        var rootByFace = Array(repeating: 0, count: triangleCount)
        var roots: [Int] = []
        for faceID in 0..<triangleCount {
            let root = union.find(faceID)
            rootByFace[faceID] = root
            if facesByRoot[root] == nil { roots.append(root) }
            facesByRoot[root, default: []].append(faceID)
        }
        roots.sort { (facesByRoot[$0]?.first ?? .max) < (facesByRoot[$1]?.first ?? .max) }

        var edgesByRoot: [Int: [DiagnosticEdgeKey]] = [:]
        var boundaryEdgesByRoot: [Int: [DiagnosticEdgeKey]] = [:]
        edgesByRoot.reserveCapacity(roots.count)
        boundaryEdgesByRoot.reserveCapacity(roots.count)
        var edgeGroupingVisitCount = 0
        for key in edgeOrder {
            edgeGroupingVisitCount += 1
            guard let uses = edges[key], let first = uses.first else {
                throw MeshMirrorError.invalidMesh
            }
            let root = rootByFace[first.faceID]
            guard uses.allSatisfy({ rootByFace[$0.faceID] == root }) else {
                throw MeshMirrorError.invalidMesh
            }
            edgesByRoot[root, default: []].append(key)
            if uses.count == 1 { boundaryEdgesByRoot[root, default: []].append(key) }
        }

        var verticesByRoot: [Int: Set<Int>] = [:]
        verticesByRoot.reserveCapacity(roots.count)
        var vertexOwnerRoot = Array<Int?>(repeating: nil, count: mesh.vertices.count)
        for faceID in 0..<triangleCount {
            let root = rootByFace[faceID]
            let offset = faceID * 3
            for rawID in mesh.indices[offset..<(offset + 3)] {
                let vertexID = Int(rawID)
                if let owner = vertexOwnerRoot[vertexID], owner != root {
                    if sides[vertexID] == .seam {
                        throw MeshMirrorError.invalidSeamLoop
                    }
                    throw MeshMirrorError.invalidMesh
                }
                vertexOwnerRoot[vertexID] = root
                verticesByRoot[root, default: []].insert(vertexID)
            }
        }

        var plans: [ComponentPlan] = []
        plans.reserveCapacity(roots.count)
        var componentEdgeVisitCount = 0
        for root in roots {
            let faceIDs = facesByRoot[root] ?? []
            let componentEdges = edgesByRoot[root] ?? []
            componentEdgeVisitCount += componentEdges.count
            let boundary = boundaryEdgesByRoot[root] ?? []
            let vertexIDs = verticesByRoot[root] ?? Set<Int>()
            let seamVertices = vertexIDs.filter { sides[$0] == .seam }.sorted()
            if boundary.isEmpty {
                guard seamVertices.isEmpty else { throw MeshMirrorError.closedComponentTouchesPlane }
                plans.append(ComponentPlan(
                    faceIDs: faceIDs, edgeKeys: componentEdges,
                    boundaryEdges: [], seamVertexIDs: [],
                    seamLoopCount: 0, isClosed: true))
                continue
            }

            if faceIDs.contains(where: { seamTriangleByFace[$0] }) {
                throw MeshMirrorError.seamTriangle
            }

            guard boundary.allSatisfy({ sides[Int($0.low)] == .seam && sides[Int($0.high)] == .seam }) else {
                throw MeshMirrorError.openBoundaryOffPlane
            }
            let boundaryVertices = Set(boundary.flatMap { [Int($0.low), Int($0.high)] })
            guard Set(seamVertices) == boundaryVertices else { throw MeshMirrorError.seamInteriorVertex }
            for key in componentEdges
                where sides[Int(key.low)] == .seam && sides[Int(key.high)] == .seam {
                guard edges[key]?.count == 1 else { throw MeshMirrorError.seamInteriorEdge }
            }
            let loops = try validateSeamLoops(boundary)
            plans.append(ComponentPlan(
                faceIDs: faceIDs, edgeKeys: componentEdges, boundaryEdges: boundary,
                seamVertexIDs: seamVertices, seamLoopCount: loops, isClosed: false))
        }
        return ComponentAnalysis(
            edges: edges,
            edgeOrder: edgeOrder,
            components: plans,
            statistics: MeshMirrorAnalysisStatistics(
                uniqueEdgeCount: edgeOrder.count,
                edgeGroupingVisitCount: edgeGroupingVisitCount,
                componentEdgeVisitCount: componentEdgeVisitCount))
    }

    private static func validateSeamLoops(_ boundary: [DiagnosticEdgeKey]) throws -> Int {
        var neighbors: [UInt32: [UInt32]] = [:]
        for edge in boundary {
            neighbors[edge.low, default: []].append(edge.high)
            neighbors[edge.high, default: []].append(edge.low)
        }
        guard neighbors.values.allSatisfy({ $0.count == 2 }) else {
            throw MeshMirrorError.invalidSeamLoop
        }
        for key in neighbors.keys { neighbors[key]?.sort() }
        var visited = Set<DiagnosticEdgeKey>()
        var loopCount = 0
        for start in neighbors.keys.sorted() {
            guard let first = neighbors[start]?.first,
                  !visited.contains(DiagnosticEdgeKey(start, first)) else { continue }
            loopCount += 1
            var previous: UInt32?
            var current = start
            var steps = 0
            repeat {
                guard let candidates = neighbors[current], candidates.count == 2 else {
                    throw MeshMirrorError.invalidSeamLoop
                }
                let next = candidates[0] == previous ? candidates[1] : candidates[0]
                let edge = DiagnosticEdgeKey(current, next)
                guard !visited.contains(edge) else {
                    if next == start { break }
                    throw MeshMirrorError.invalidSeamLoop
                }
                visited.insert(edge)
                previous = current
                current = next
                steps += 1
                guard steps <= boundary.count else { throw MeshMirrorError.invalidSeamLoop }
            } while current != start
        }
        guard visited.count == boundary.count, loopCount > 0 else { throw MeshMirrorError.invalidSeamLoop }
        return loopCount
    }

    private static func validateSnappedSource(
        source: EditableMesh,
        snappedVertices: [MeshVertex]
    ) throws {
        guard snappedVertices.count == source.vertices.count,
              snappedVertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw MeshMirrorError.validationFailed
        }
        let snapped = EditableMesh(vertices: snappedVertices, indices: source.indices)
        let report = MeshTopologyDiagnostics.analyze(snapped)
        guard !report.hasInvalidStructure,
              report.invalidIndexTriangleCount == 0,
              report.nonFiniteVertexCount == 0 else {
            throw MeshMirrorError.validationFailed
        }
        guard report.degenerateTriangleCount == 0 else {
            throw MeshMirrorError.seamSnapWouldCollapseTriangle
        }
        guard try hasGeometricDuplicateTriangles(
            vertices: snappedVertices,
            indices: source.indices
        ) == false else {
            throw MeshMirrorError.seamSnapWouldCreateDuplicateTriangle
        }
    }

    private static func hasGeometricDuplicateTriangles(
        vertices: [MeshVertex],
        indices: [UInt32]
    ) throws -> Bool {
        let candidate = EditableMesh(vertices: vertices, indices: indices)
        guard let result = MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(candidate) else {
            guard vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
                throw MeshMirrorError.nonFiniteValue
            }
            throw MeshMirrorError.invalidMesh
        }
        return result
    }

    private static func validateResult(
        _ result: EditableMesh,
        source: EditableMesh,
        transform: ObjectTransform,
        plan: Plan,
        mirrorMap: [UInt32?],
        options: MeshMirrorOptions
    ) throws {
        guard result.vertices.count == plan.estimate.resultingVertexCount,
              result.indices.count / 3 == plan.estimate.resultingTriangleCount,
              result.bounds == plan.estimate.resultLocalBounds,
              result.hasCachedAdjacency,
              result.vertices.allSatisfy({ vertex in
                  vertex.position.allFinite && vertex.normal.allFinite
                      && abs(simd_length(vertex.normal) - 1) <= 0.001
              }),
              plan.estimate.maximumSeamSnapDistance.isFinite,
              plan.estimate.maximumSeamSnapDistance >= 0,
              plan.estimate.maximumSeamSnapDistance <= plan.estimate.seamTolerance else {
            throw MeshMirrorError.validationFailed
        }
        let report = MeshTopologyDiagnostics.analyze(result)
        guard !report.hasInvalidStructure,
              report.invalidIndexTriangleCount == 0,
              report.nonFiniteVertexCount == 0,
              report.boundaryEdgeCount == 0,
              report.nonManifoldEdgeCount == 0,
              report.inconsistentWindingEdgeCount == 0,
              report.degenerateTriangleCount == 0,
              report.duplicateTriangleCount == 0,
              report.isolatedVertexCount == 0,
              report.connectedComponentCount == plan.estimate.resultingComponentCount else {
            throw MeshMirrorError.validationFailed
        }
        guard Array(result.indices.prefix(source.indices.count)) == source.indices else {
            throw MeshMirrorError.validationFailed
        }
        for vertexID in plan.snappedVertices.indices {
            guard let mirroredID = mirrorMap[vertexID], Int(mirroredID) < result.vertices.count else {
                throw MeshMirrorError.validationFailed
            }
            let expected = options.axis.reflected(plan.snappedVertices[vertexID].position)
            guard result.vertices[Int(mirroredID)].position == expected else {
                throw MeshMirrorError.validationFailed
            }
            if plan.isSeam[vertexID], mirroredID != UInt32(vertexID) {
                throw MeshMirrorError.validationFailed
            }
        }
        let sourceTriangleCount = source.indices.count / 3
        for faceID in 0..<sourceTriangleCount {
            let sourceOffset = faceID * 3
            let mirrorOffset = source.indices.count + sourceOffset
            let a = Int(source.indices[sourceOffset])
            let b = Int(source.indices[sourceOffset + 1])
            let c = Int(source.indices[sourceOffset + 2])
            guard let ma = mirrorMap[a], let mb = mirrorMap[b], let mc = mirrorMap[c],
                  result.indices[mirrorOffset] == ma,
                  result.indices[mirrorOffset + 1] == mc,
                  result.indices[mirrorOffset + 2] == mb else {
                throw MeshMirrorError.validationFailed
            }
        }
        let axis = options.axis.componentIndex
        guard abs(result.bounds.minimum[axis] + result.bounds.maximum[axis])
                <= max(plan.estimate.seamTolerance, 1.0e-5) else {
            throw MeshMirrorError.validationFailed
        }
        guard worldBounds(of: result, transform: transform) == plan.estimate.resultWorldBounds else {
            throw MeshMirrorError.validationFailed
        }
    }

    private static func worldBounds(
        of mesh: EditableMesh,
        transform: ObjectTransform
    ) -> AxisAlignedBoundingBox {
        var bounds = AxisAlignedBoundingBox()
        for vertex in mesh.vertices { bounds.include(transform.worldPosition(fromLocal: vertex.position)) }
        return bounds
    }

    private static func seamTolerance(mesh: EditableMesh, axis: MirrorAxis) -> Float {
        var minimum = SIMD3<Double>(repeating: .infinity)
        var maximum = SIMD3<Double>(repeating: -.infinity)
        var maximumAxisCoordinate = Double.zero
        for vertex in mesh.vertices {
            let position = SIMD3<Double>(
                Double(vertex.position.x),
                Double(vertex.position.y),
                Double(vertex.position.z))
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
            maximumAxisCoordinate = max(
                maximumAxisCoordinate,
                abs(position[axis.componentIndex]))
        }
        let extent = maximum - minimum
        let diagonal = max(simd_length(extent), Double.leastNonzeroMagnitude)
        let axisExtent = max(extent[axis.componentIndex], 0)
        let minimumTolerance = 1.0e-5
        let axisRelativeCap = max(minimumTolerance, axisExtent * 1.0e-4)
        let diagonalRelative = min(diagonal * 1.0e-6, axisRelativeCap)
        let base = max(minimumTolerance, diagonalRelative)
        let precision = maximumAxisCoordinate * Double(Float.ulpOfOne) * 4
        let tolerance = max(base, min(precision, axisRelativeCap))
        guard tolerance.isFinite, tolerance <= Double(Float.greatestFiniteMagnitude) else {
            return .infinity
        }
        return Float(tolerance)
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
            try multiply(resultingVertices, 64),
            try multiply(resultingTriangles, 48))
    }

    private static func fingerprint(
        mesh: EditableMesh,
        axis: MirrorAxis,
        sides: [Side],
        components: [ComponentPlan],
        edgeOrder: [DiagnosticEdgeKey],
        tolerance: Float,
        sourceSide: MeshMirrorSourceSide,
        estimate: MeshMirrorEstimate
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) { hash ^= value; hash &*= 1_099_511_628_211 }
        mix(UInt64(axis.componentIndex))
        mix(UInt64(tolerance.bitPattern))
        mix(sourceSide == .positive ? 1 : 2)
        for (index, vertex) in mesh.vertices.enumerated() {
            mix(UInt64(index))
            mix(UInt64(vertex.position.x.bitPattern))
            mix(UInt64(vertex.position.y.bitPattern))
            mix(UInt64(vertex.position.z.bitPattern))
            switch sides[index] {
            case .seam: mix(0)
            case .positive: mix(1)
            case .negative: mix(2)
            }
        }
        for edge in edgeOrder { mix(UInt64(edge.low)); mix(UInt64(edge.high)) }
        for component in components {
            mix(component.isClosed ? 1 : 0)
            mix(UInt64(component.seamLoopCount))
            for faceID in component.faceIDs { mix(UInt64(faceID)) }
            for edge in component.edgeKeys { mix(UInt64(edge.low)); mix(UInt64(edge.high)) }
            for edge in component.boundaryEdges { mix(UInt64(edge.low)); mix(UInt64(edge.high)) }
            for vertexID in component.seamVertexIDs { mix(UInt64(vertexID)) }
        }
        mix(UInt64(estimate.resultingVertexCount))
        mix(UInt64(estimate.resultingTriangleCount))
        mix(UInt64(estimate.boundaryEdgeCount))
        mix(UInt64(estimate.maximumSeamSnapDistance.bitPattern))
        return hash
    }

    private static func add(_ values: Int...) throws -> Int {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw MeshMirrorError.arithmeticOverflow }
            return result
        }
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw MeshMirrorError.arithmeticOverflow }
        return result
    }
}

private struct MirrorUnionFind {
    private var parents: [Int]
    private var ranks: [UInt8]

    init(count: Int) {
        parents = Array(0..<count)
        ranks = Array(repeating: 0, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        var root = value
        while parents[root] != root { root = parents[root] }
        var current = value
        while parents[current] != current {
            let next = parents[current]
            parents[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let first = find(lhs)
        let second = find(rhs)
        guard first != second else { return }
        if ranks[first] < ranks[second] { parents[first] = second }
        else if ranks[first] > ranks[second] { parents[second] = first }
        else { parents[second] = first; ranks[first] &+= 1 }
    }
}
