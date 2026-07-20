import Foundation
import simd

enum MeshSeamOperation: String, CaseIterable, Equatable, Identifiable {
    case splitRegion = "Split Region"
    case mergeExactSeam = "Merge Exact Seam"

    var id: Self { self }
}

struct MeshSeamEditEstimate: Equatable {
    let operation: MeshSeamOperation
    let selectedFaceCount: Int
    let hostComponentFaceCount: Int
    let counterpartComponentFaceCount: Int?
    let seamVertexCount: Int
    let seamEdgeCount: Int
    let originalVertexCount: Int
    let resultingVertexCount: Int
    let originalTriangleCount: Int
    let resultingTriangleCount: Int
    let sourceComponentCount: Int
    let resultingComponentCount: Int
    let sourceBoundaryEdgeCount: Int
    let resultingBoundaryEdgeCount: Int
    let sourceBounds: AxisAlignedBoundingBox
    let resultBounds: AxisAlignedBoundingBox
    let estimatedWorkingByteCount: Int
}

struct MeshSeamEditSourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: TopologyEditChangeVersion
    let transformChangeVersion: TopologyEditChangeVersion
    let transform: ObjectTransform
    let selectionVersion: FaceSelectionVersion
    let selectedFaceFingerprint: UInt64
    let operation: MeshSeamOperation
    let sourceVertexCount: Int
    let sourceTriangleCount: Int
    let seamVertexCount: Int
    let seamEdgeCount: Int
    let sourceComponentCount: Int
    let sourceBoundaryEdgeCount: Int
    let analysisFingerprint: UInt64

    func matchesRuntimeIdentity(
        mesh: EditableMesh,
        transform: ObjectTransform,
        selection: FaceSelection,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion,
        operation: MeshSeamOperation
    ) -> Bool {
        topologyID == mesh.runtime.topologyID
            && topologyRevision == mesh.runtime.topologyRevision
            && vertexRevision == mesh.runtime.revision
            && self.meshChangeVersion == meshChangeVersion
            && self.transformChangeVersion == transformChangeVersion
            && self.transform == transform.sanitized()
            && selection.matches(mesh)
            && selectionVersion == selection.version
            && selectedFaceFingerprint == MeshExactSeamEdit.selectionFingerprint(
                selection.selectedFaceIDs())
            && self.operation == operation
            && sourceVertexCount == mesh.vertices.count
            && sourceTriangleCount == mesh.indices.count / 3
    }
}

struct MeshSeamEditPreview: Equatable {
    let operation: MeshSeamOperation
    let estimate: MeshSeamEditEstimate
    let source: MeshSeamEditSourceKey
}

struct MeshSeamEditResult: Equatable {
    let mesh: EditableMesh
    let estimate: MeshSeamEditEstimate
    let analysisFingerprint: UInt64
}

enum MeshSeamEditError: Error, Equatable, LocalizedError {
    case invalidMesh
    case nonFiniteValue
    case degenerateTriangle
    case duplicateTriangle
    case nonManifoldEdge
    case windingConflict
    case isolatedVertex
    case emptySelection
    case staleSelection
    case disconnectedSelection
    case multipleHostComponents
    case wholeComponentSelected
    case disconnectedRemainder
    case selectedRegionTouchesOpenBoundary
    case invalidBoundary
    case multipleBoundaryLoops
    case vertexOnlyContact
    case selectedFacesMustEqualComponent
    case ambiguousCounterpart
    case unmatchedSeamVertex
    case unmatchedSeamEdge
    case componentCountFailure
    case boundaryCountFailure
    case boundsFailure
    case vertexLimitExceeded
    case triangleLimitExceeded
    case workingMemoryLimitExceeded
    case indexOverflow
    case arithmeticOverflow
    case validationFailed
    case stalePreview
    case operationInProgress
    case activeEdit
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidMesh: "Merge / Split requires a nonempty valid triangle mesh."
        case .nonFiniteValue: "Merge / Split requires finite positions, normals, and Transform values."
        case .degenerateTriangle: "The source contains a degenerate triangle."
        case .duplicateTriangle: "The source contains duplicate triangle geometry."
        case .nonManifoldEdge: "The source or result contains a non-manifold edge."
        case .windingConflict: "The seam triangles do not have compatible opposite edge winding."
        case .isolatedVertex: "Every source and result vertex must be referenced."
        case .emptySelection: "Select a face region before calculating the Preview."
        case .staleSelection: "The Face Selection no longer matches the current topology."
        case .disconnectedSelection: "Split Region requires one edge-connected selected region."
        case .multipleHostComponents: "The selected region must belong to one source component."
        case .wholeComponentSelected: "Split Region cannot split an entire connected component."
        case .disconnectedRemainder: "Removing the selected region would leave a disconnected remainder."
        case .selectedRegionTouchesOpenBoundary: "The Split seam cannot touch an existing open boundary."
        case .invalidBoundary: "The seam must be one simple closed loop without branches, repeated vertices, or bow-ties."
        case .multipleBoundaryLoops: "Only a single seam boundary loop is supported."
        case .vertexOnlyContact: "Vertex-only contact across the proposed seam is ambiguous."
        case .selectedFacesMustEqualComponent: "Merge Exact Seam requires one complete connected component to be selected."
        case .ambiguousCounterpart: "The exact seam has no unique counterpart component and one-to-one vertex pairing."
        case .unmatchedSeamVertex: "Every selected seam vertex must have one bit-exact counterpart."
        case .unmatchedSeamEdge: "Every selected seam edge must have one bit-exact counterpart edge."
        case .componentCountFailure: "The result did not produce the expected connected-component count."
        case .boundaryCountFailure: "The result did not produce the expected open-boundary count."
        case .boundsFailure: "The operation must preserve finite mesh bounds."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .workingMemoryLimitExceeded: "The operation exceeds the 768 MiB working-memory limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Merge / Split size calculation overflowed."
        case .validationFailed: "The Merge / Split result failed topology validation."
        case .stalePreview: "The mesh, Transform, Face Selection, or operation changed. Recalculate the Preview."
        case .operationInProgress: "Another topology operation is already running."
        case .activeEdit: "Finish the active edit before using Merge / Split."
        case .unavailable: "Merge / Split is unavailable during the current operation."
        }
    }
}

enum MeshExactSeamEdit {
    static let maximumVertices = MeshCleanup.maximumVertices
    static let maximumTriangles = MeshCleanup.maximumTriangles
    static let maximumWorkingBytes = MeshCleanup.maximumWorkingBytes

    private struct Edge: Hashable, Comparable {
        let low: UInt32
        let high: UInt32
        init(_ a: UInt32, _ b: UInt32) { low = min(a, b); high = max(a, b) }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.low == rhs.low ? lhs.high < rhs.high : lhs.low < rhs.low
        }
    }

    private struct EdgeUse {
        let face: Int
        let from: UInt32
        let to: UInt32
    }

    private struct ExactPositionKey: Hashable, Comparable {
        let x: UInt32
        let y: UInt32
        let z: UInt32
        init(_ value: SIMD3<Float>) {
            x = Self.bits(value.x); y = Self.bits(value.y); z = Self.bits(value.z)
        }
        private static func bits(_ value: Float) -> UInt32 {
            value == 0 ? Float(0).bitPattern : value.bitPattern
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    private struct Analysis {
        let selected: [Int]
        let selectedSet: Set<Int>
        let components: [[Int]]
        let componentOfFace: [Int]
        let edges: [Edge: [EdgeUse]]
        let sourceTopology: MeshTopologyReport
        let seamEdges: [Edge]
        let seamVertices: [UInt32]
        let hostComponent: [Int]
        let counterpartComponent: [Int]?
        let counterpartBySelectedVertex: [UInt32: UInt32]
        let fingerprint: UInt64
    }

    static func makePreview(
        mesh: EditableMesh,
        transform: ObjectTransform,
        selection: FaceSelection,
        operation: MeshSeamOperation,
        meshChangeVersion: TopologyEditChangeVersion,
        transformChangeVersion: TopologyEditChangeVersion
    ) throws -> MeshSeamEditPreview {
        let result = try edit(mesh: mesh, transform: transform, selection: selection,
                              operation: operation)
        return MeshSeamEditPreview(
            operation: operation,
            estimate: result.estimate,
            source: MeshSeamEditSourceKey(
                topologyID: mesh.runtime.topologyID,
                topologyRevision: mesh.runtime.topologyRevision,
                vertexRevision: mesh.runtime.revision,
                meshChangeVersion: meshChangeVersion,
                transformChangeVersion: transformChangeVersion,
                transform: transform.sanitized(),
                selectionVersion: selection.version,
                selectedFaceFingerprint: selectionFingerprint(selection.selectedFaceIDs()),
                operation: operation,
                sourceVertexCount: mesh.vertices.count,
                sourceTriangleCount: mesh.indices.count / 3,
                seamVertexCount: result.estimate.seamVertexCount,
                seamEdgeCount: result.estimate.seamEdgeCount,
                sourceComponentCount: result.estimate.sourceComponentCount,
                sourceBoundaryEdgeCount: result.estimate.sourceBoundaryEdgeCount,
                analysisFingerprint: result.analysisFingerprint))
    }

    static func preparedResultMatchesPreview(
        _ result: MeshSeamEditResult,
        preview: MeshSeamEditPreview
    ) -> Bool {
        result.estimate == preview.estimate
            && result.analysisFingerprint == preview.source.analysisFingerprint
    }

    static func edit(
        mesh: EditableMesh,
        transform: ObjectTransform,
        selection: FaceSelection,
        operation: MeshSeamOperation
    ) throws -> MeshSeamEditResult {
        let analysis = try analyze(mesh: mesh, transform: transform,
                                   selection: selection, operation: operation)
        switch operation {
        case .splitRegion: return try split(mesh: mesh, analysis: analysis)
        case .mergeExactSeam: return try merge(mesh: mesh, analysis: analysis)
        }
    }

    static func selectionFingerprint(_ faceIDs: [Int]) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for faceID in faceIDs { value = (value ^ UInt64(faceID)) &* 0x100000001b3 }
        return value
    }

    private static func analyze(
        mesh: EditableMesh,
        transform: ObjectTransform,
        selection: FaceSelection,
        operation: MeshSeamOperation
    ) throws -> Analysis {
        guard transform.isFinite,
              transform.scale.x > 0, transform.scale.y > 0, transform.scale.z > 0 else {
            throw MeshSeamEditError.nonFiniteValue
        }
        guard selection.matches(mesh) else { throw MeshSeamEditError.staleSelection }
        let selected = selection.selectedFaceIDs()
        guard !selected.isEmpty else { throw MeshSeamEditError.emptySelection }
        let topology = try validateSource(mesh)
        let triangleCount = mesh.indices.count / 3
        var edges: [Edge: [EdgeUse]] = [:]
        var faceNeighbors = Array(repeating: Set<Int>(), count: triangleCount)
        for face in 0..<triangleCount {
            let ids = try triangle(mesh, face)
            for (from, to) in [(ids.0, ids.1), (ids.1, ids.2), (ids.2, ids.0)] {
                edges[Edge(from, to), default: []].append(EdgeUse(face: face, from: from, to: to))
            }
        }
        for uses in edges.values where uses.count > 1 {
            for i in uses.indices {
                for j in uses.indices where i < j {
                    faceNeighbors[uses[i].face].insert(uses[j].face)
                    faceNeighbors[uses[j].face].insert(uses[i].face)
                }
            }
        }
        let (components, componentOfFace) = components(neighbors: faceNeighbors)
        let selectedSet = Set(selected)
        let selectedComponents = connectedSubsets(selectedSet, neighbors: faceNeighbors)
        guard selectedComponents.count == 1 else { throw MeshSeamEditError.disconnectedSelection }
        let hostIDs = Set(selected.map { componentOfFace[$0] })
        guard hostIDs.count == 1, let hostID = hostIDs.first else {
            throw MeshSeamEditError.multipleHostComponents
        }
        let host = components[hostID]

        var seamEdges: [Edge] = []
        for (edge, uses) in edges {
            guard uses.count == 2 else { continue }
            if selectedSet.contains(uses[0].face) != selectedSet.contains(uses[1].face) {
                seamEdges.append(edge)
            }
        }
        seamEdges.sort()
        var counterpart: [Int]?
        var pairing: [UInt32: UInt32] = [:]

        switch operation {
        case .splitRegion:
            guard selected.count < host.count else { throw MeshSeamEditError.wholeComponentSelected }
            let remainder = Set(host).subtracting(selectedSet)
            guard connectedSubsets(remainder, neighbors: faceNeighbors).count == 1 else {
                throw MeshSeamEditError.disconnectedRemainder
            }
            for (edge, uses) in edges where uses.count == 1 {
                if selectedSet.contains(uses[0].face) { throw MeshSeamEditError.selectedRegionTouchesOpenBoundary }
                if seamEdges.contains(where: { $0.low == edge.low || $0.low == edge.high
                    || $0.high == edge.low || $0.high == edge.high }) {
                    throw MeshSeamEditError.selectedRegionTouchesOpenBoundary
                }
            }
        case .mergeExactSeam:
            guard selected.count == host.count else {
                throw MeshSeamEditError.selectedFacesMustEqualComponent
            }
            seamEdges = edges.compactMap { edge, uses in
                uses.count == 1 && selectedSet.contains(uses[0].face) ? edge : nil
            }.sorted()
        }

        let seamVertices = try validateSimpleLoop(seamEdges)
        guard Set(seamVertices.map { ExactPositionKey(mesh.vertices[Int($0)].position) }).count
                == seamVertices.count else { throw MeshSeamEditError.invalidBoundary }

        if operation == .splitRegion {
            let selectedVertices = Set(selected.flatMap { face -> [UInt32] in
                let offset = face * 3
                return Array(mesh.indices[offset..<(offset + 3)])
            })
            let remainderVertices = Set(host.filter { !selectedSet.contains($0) }.flatMap { face -> [UInt32] in
                let offset = face * 3
                return Array(mesh.indices[offset..<(offset + 3)])
            })
            let shared = selectedVertices.intersection(remainderVertices)
            guard shared == Set(seamVertices) else { throw MeshSeamEditError.vertexOnlyContact }
        } else {
            let boundaryEdges = edges.filter { $0.value.count == 1 }
            var boundaryVerticesByPosition: [ExactPositionKey: [UInt32]] = [:]
            for (edge, _) in boundaryEdges {
                boundaryVerticesByPosition[ExactPositionKey(mesh.vertices[Int(edge.low)].position), default: []]
                    .append(edge.low)
                boundaryVerticesByPosition[ExactPositionKey(mesh.vertices[Int(edge.high)].position), default: []]
                    .append(edge.high)
            }
            for key in boundaryVerticesByPosition.keys {
                boundaryVerticesByPosition[key] = Array(Set(boundaryVerticesByPosition[key]!)).sorted()
            }
            var counterpartIDs = Set<Int>()
            for selectedVertex in seamVertices {
                let key = ExactPositionKey(mesh.vertices[Int(selectedVertex)].position)
                let candidates = (boundaryVerticesByPosition[key] ?? []).filter { candidate in
                    candidate != selectedVertex && !host.contains { face in
                        let offset = face * 3
                        return mesh.indices[offset..<(offset + 3)].contains(candidate)
                    }
                }
                guard candidates.count == 1, let candidate = candidates.first else {
                    throw candidates.isEmpty ? MeshSeamEditError.unmatchedSeamVertex
                        : MeshSeamEditError.ambiguousCounterpart
                }
                pairing[selectedVertex] = candidate
                let incident = boundaryEdges.first { $0.key.low == candidate || $0.key.high == candidate }
                guard let incident else { throw MeshSeamEditError.unmatchedSeamVertex }
                counterpartIDs.insert(componentOfFace[incident.value[0].face])
            }
            guard counterpartIDs.count == 1, let counterpartID = counterpartIDs.first,
                  counterpartID != hostID else { throw MeshSeamEditError.ambiguousCounterpart }
            counterpart = components[counterpartID]
            let counterpartBoundary = Set(boundaryEdges.compactMap { edge, uses in
                componentOfFace[uses[0].face] == counterpartID ? edge : nil
            })
            for edge in seamEdges {
                guard let a = pairing[edge.low], let b = pairing[edge.high],
                      counterpartBoundary.contains(Edge(a, b)) else {
                    throw MeshSeamEditError.unmatchedSeamEdge
                }
                guard let selectedUse = edges[edge]?.first,
                      let counterpartUse = edges[Edge(a, b)]?.first else {
                    throw MeshSeamEditError.unmatchedSeamEdge
                }
                let mappedFrom = pairing[selectedUse.from], mappedTo = pairing[selectedUse.to]
                guard mappedFrom == counterpartUse.to, mappedTo == counterpartUse.from else {
                    throw MeshSeamEditError.windingConflict
                }
            }
        }

        let fingerprint = analysisFingerprint(
            mesh: mesh, operation: operation, selected: selected,
            seamEdges: seamEdges, pairing: pairing)
        return Analysis(selected: selected, selectedSet: selectedSet, components: components,
                        componentOfFace: componentOfFace, edges: edges,
                        sourceTopology: topology, seamEdges: seamEdges,
                        seamVertices: seamVertices.sorted(), hostComponent: host,
                        counterpartComponent: counterpart,
                        counterpartBySelectedVertex: pairing, fingerprint: fingerprint)
    }

    private static func split(mesh: EditableMesh, analysis: Analysis) throws -> MeshSeamEditResult {
        let resultVertexCount = try add(mesh.vertices.count, analysis.seamVertices.count)
        try validateLimits(vertices: resultVertexCount, triangles: mesh.indices.count / 3,
                           seamVertices: analysis.seamVertices.count, seamEdges: analysis.seamEdges.count)
        guard resultVertexCount <= Int(UInt32.max) else { throw MeshSeamEditError.indexOverflow }
        var vertices = mesh.vertices
        var duplicate: [UInt32: UInt32] = [:]
        for sourceID in analysis.seamVertices.sorted() {
            duplicate[sourceID] = UInt32(vertices.count)
            vertices.append(mesh.vertices[Int(sourceID)])
        }
        var indices = mesh.indices
        for face in analysis.selected {
            for indexOffset in (face * 3)..<(face * 3 + 3) {
                if let mapped = duplicate[indices[indexOffset]] { indices[indexOffset] = mapped }
            }
        }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals(recordChange: false)
        _ = result.adjacency()
        let estimate = try validateResult(mesh: mesh, result: result, analysis: analysis,
                                          operation: .splitRegion)
        return MeshSeamEditResult(mesh: result, estimate: estimate,
                                  analysisFingerprint: analysis.fingerprint)
    }

    private static func merge(mesh: EditableMesh, analysis: Analysis) throws -> MeshSeamEditResult {
        guard analysis.counterpartComponent != nil else { throw MeshSeamEditError.ambiguousCounterpart }
        let resultVertexCount = mesh.vertices.count - analysis.seamVertices.count
        try validateLimits(vertices: resultVertexCount, triangles: mesh.indices.count / 3,
                           seamVertices: analysis.seamVertices.count, seamEdges: analysis.seamEdges.count)
        let removed = Set(analysis.seamVertices)
        var oldToNew = Array(repeating: UInt32.max, count: mesh.vertices.count)
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(resultVertexCount)
        for oldID in mesh.vertices.indices where !removed.contains(UInt32(oldID)) {
            guard vertices.count <= Int(UInt32.max) else { throw MeshSeamEditError.indexOverflow }
            oldToNew[oldID] = UInt32(vertices.count)
            vertices.append(mesh.vertices[oldID])
        }
        for selectedVertex in analysis.seamVertices {
            guard let survivor = analysis.counterpartBySelectedVertex[selectedVertex],
                  oldToNew[Int(survivor)] != .max else { throw MeshSeamEditError.unmatchedSeamVertex }
            oldToNew[Int(selectedVertex)] = oldToNew[Int(survivor)]
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        for old in mesh.indices {
            let mapped = oldToNew[Int(old)]
            guard mapped != .max else { throw MeshSeamEditError.validationFailed }
            indices.append(mapped)
        }
        var result = EditableMesh(vertices: vertices, indices: indices)
        result.recalculateNormals(recordChange: false)
        _ = result.adjacency()
        let estimate = try validateResult(mesh: mesh, result: result, analysis: analysis,
                                          operation: .mergeExactSeam)
        return MeshSeamEditResult(mesh: result, estimate: estimate,
                                  analysisFingerprint: analysis.fingerprint)
    }

    private static func validateSource(_ mesh: EditableMesh) throws -> MeshTopologyReport {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3) else { throw MeshSeamEditError.invalidMesh }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw MeshSeamEditError.nonFiniteValue
        }
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        guard !topology.hasInvalidStructure, topology.invalidIndexTriangleCount == 0 else {
            throw MeshSeamEditError.invalidMesh
        }
        guard topology.degenerateTriangleCount == 0 else { throw MeshSeamEditError.degenerateTriangle }
        guard topology.duplicateTriangleCount == 0,
              MeshTopologyDiagnostics.hasGeometricDuplicateTriangles(mesh) == false else {
            throw MeshSeamEditError.duplicateTriangle
        }
        guard topology.nonManifoldEdgeCount == 0 else { throw MeshSeamEditError.nonManifoldEdge }
        guard topology.inconsistentWindingEdgeCount == 0 else { throw MeshSeamEditError.windingConflict }
        guard topology.isolatedVertexCount == 0 else { throw MeshSeamEditError.isolatedVertex }
        guard mesh.bounds.isFinite else { throw MeshSeamEditError.boundsFailure }
        return topology
    }

    private static func validateResult(
        mesh: EditableMesh, result: EditableMesh, analysis: Analysis,
        operation: MeshSeamOperation
    ) throws -> MeshSeamEditEstimate {
        let topology = try validateSource(result)
        let delta = operation == .splitRegion ? 1 : -1
        let expectedComponents = try add(analysis.sourceTopology.connectedComponentCount, delta)
        let boundaryDelta = try multiply(analysis.seamEdges.count, 2)
        let expectedBoundary = operation == .splitRegion
            ? try add(analysis.sourceTopology.boundaryEdgeCount, boundaryDelta)
            : analysis.sourceTopology.boundaryEdgeCount - boundaryDelta
        guard topology.connectedComponentCount == expectedComponents else {
            throw MeshSeamEditError.componentCountFailure
        }
        guard expectedBoundary >= 0, topology.boundaryEdgeCount == expectedBoundary else {
            throw MeshSeamEditError.boundaryCountFailure
        }
        guard result.indices.count == mesh.indices.count else { throw MeshSeamEditError.validationFailed }
        guard result.bounds == mesh.bounds, result.bounds.isFinite else { throw MeshSeamEditError.boundsFailure }
        for face in 0..<(mesh.indices.count / 3) {
            let source = try trianglePositions(mesh, face)
            let target = try trianglePositions(result, face)
            guard source == target else { throw MeshSeamEditError.validationFailed }
        }
        let bytes = try estimateWorkingBytes(source: mesh, resultVertices: result.vertices.count,
                                             seamVertices: analysis.seamVertices.count,
                                             seamEdges: analysis.seamEdges.count)
        return MeshSeamEditEstimate(
            operation: operation, selectedFaceCount: analysis.selected.count,
            hostComponentFaceCount: analysis.hostComponent.count,
            counterpartComponentFaceCount: analysis.counterpartComponent?.count,
            seamVertexCount: analysis.seamVertices.count,
            seamEdgeCount: analysis.seamEdges.count,
            originalVertexCount: mesh.vertices.count,
            resultingVertexCount: result.vertices.count,
            originalTriangleCount: mesh.indices.count / 3,
            resultingTriangleCount: result.indices.count / 3,
            sourceComponentCount: analysis.sourceTopology.connectedComponentCount,
            resultingComponentCount: topology.connectedComponentCount,
            sourceBoundaryEdgeCount: analysis.sourceTopology.boundaryEdgeCount,
            resultingBoundaryEdgeCount: topology.boundaryEdgeCount,
            sourceBounds: mesh.bounds, resultBounds: result.bounds,
            estimatedWorkingByteCount: bytes)
    }

    private static func validateSimpleLoop(_ edges: [Edge]) throws -> [UInt32] {
        guard edges.count >= 3 else { throw MeshSeamEditError.invalidBoundary }
        var neighbors: [UInt32: [UInt32]] = [:]
        for edge in edges {
            neighbors[edge.low, default: []].append(edge.high)
            neighbors[edge.high, default: []].append(edge.low)
        }
        guard neighbors.values.allSatisfy({ $0.count == 2 }) else {
            throw MeshSeamEditError.invalidBoundary
        }
        let start = neighbors.keys.min()!
        var visited = Set<UInt32>()
        var previous: UInt32?
        var current = start
        repeat {
            guard visited.insert(current).inserted else { throw MeshSeamEditError.invalidBoundary }
            let next = neighbors[current]!.sorted().first { $0 != previous }
            guard let next else { throw MeshSeamEditError.invalidBoundary }
            previous = current; current = next
        } while current != start
        guard visited.count == neighbors.count else { throw MeshSeamEditError.multipleBoundaryLoops }
        return visited.sorted()
    }

    private static func components(neighbors: [Set<Int>]) -> ([[Int]], [Int]) {
        var labels = Array(repeating: -1, count: neighbors.count)
        var values: [[Int]] = []
        for seed in neighbors.indices where labels[seed] == -1 {
            let label = values.count
            var queue = [seed], cursor = 0, component: [Int] = []
            labels[seed] = label
            while cursor < queue.count {
                let face = queue[cursor]; cursor += 1; component.append(face)
                for neighbor in neighbors[face].sorted() where labels[neighbor] == -1 {
                    labels[neighbor] = label; queue.append(neighbor)
                }
            }
            values.append(component.sorted())
        }
        return (values, labels)
    }

    private static func connectedSubsets(_ faces: Set<Int>, neighbors: [Set<Int>]) -> [[Int]] {
        var remaining = faces, result: [[Int]] = []
        while let seed = remaining.min() {
            var queue = [seed], cursor = 0, component: [Int] = []
            remaining.remove(seed)
            while cursor < queue.count {
                let face = queue[cursor]; cursor += 1; component.append(face)
                for next in neighbors[face].sorted() where remaining.remove(next) != nil {
                    queue.append(next)
                }
            }
            result.append(component.sorted())
        }
        return result
    }

    private static func triangle(_ mesh: EditableMesh, _ face: Int) throws -> (UInt32, UInt32, UInt32) {
        let offset = face * 3
        guard face >= 0, offset + 2 < mesh.indices.count else { throw MeshSeamEditError.invalidMesh }
        let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
        guard Int(a) < mesh.vertices.count, Int(b) < mesh.vertices.count,
              Int(c) < mesh.vertices.count else { throw MeshSeamEditError.invalidMesh }
        return (a, b, c)
    }

    private static func trianglePositions(
        _ mesh: EditableMesh, _ face: Int
    ) throws -> [SIMD3<Float>] {
        let ids = try triangle(mesh, face)
        return [mesh.vertices[Int(ids.0)].position, mesh.vertices[Int(ids.1)].position,
                mesh.vertices[Int(ids.2)].position]
    }

    private static func validateLimits(
        vertices: Int, triangles: Int, seamVertices: Int, seamEdges: Int
    ) throws {
        guard vertices <= maximumVertices else { throw MeshSeamEditError.vertexLimitExceeded }
        guard triangles <= maximumTriangles else { throw MeshSeamEditError.triangleLimitExceeded }
        guard vertices <= Int(UInt32.max) else { throw MeshSeamEditError.indexOverflow }
        let meshBytes = try multiply(try add(vertices, triangles * 3), 96)
        let seamBytes = try multiply(try add(seamVertices, seamEdges), 128)
        let approximate = try add(meshBytes, seamBytes)
        guard approximate <= maximumWorkingBytes else {
            throw MeshSeamEditError.workingMemoryLimitExceeded
        }
    }

    private static func estimateWorkingBytes(
        source: EditableMesh, resultVertices: Int, seamVertices: Int, seamEdges: Int
    ) throws -> Int {
        let sourceUnits = try add(source.vertices.count, source.indices.count)
        let resultUnits = try add(resultVertices, source.indices.count)
        let meshBytes = try multiply(try add(sourceUnits, resultUnits), 64)
        let analysisBytes = try multiply(try add(seamVertices, seamEdges), 128)
        return try add(meshBytes, analysisBytes)
    }

    private static func analysisFingerprint(
        mesh: EditableMesh, operation: MeshSeamOperation, selected: [Int],
        seamEdges: [Edge], pairing: [UInt32: UInt32]
    ) -> UInt64 {
        var value: UInt64 = operation == .splitRegion ? 0x51a17 : 0xa11ce
        func mix(_ item: UInt64) { value = (value ^ item) &* 0x100000001b3 }
        for vertex in mesh.vertices {
            mix(UInt64(vertex.position.x.bitPattern)); mix(UInt64(vertex.position.y.bitPattern))
            mix(UInt64(vertex.position.z.bitPattern))
        }
        mesh.indices.forEach { mix(UInt64($0)) }
        selected.forEach { mix(UInt64($0)) }
        for edge in seamEdges { mix(UInt64(edge.low)); mix(UInt64(edge.high)) }
        for key in pairing.keys.sorted() { mix(UInt64(key)); mix(UInt64(pairing[key]!)) }
        return value
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MeshSeamEditError.arithmeticOverflow }
        return value
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw MeshSeamEditError.arithmeticOverflow }
        return value
    }
}
