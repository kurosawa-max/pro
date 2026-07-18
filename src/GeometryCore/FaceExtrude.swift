import Foundation
import simd

struct FaceExtrudeOptions: Equatable {
    static let defaultDistanceMillimeters = 1.0
    static let minimumAbsoluteDistanceMillimeters = 0.001
    static let maximumAbsoluteDistanceMillimeters = 1_000.0

    var distanceMillimeters = defaultDistanceMillimeters
}

struct FaceExtrudeChangeVersion: Equatable {
    private(set) var identity: UUID
    private(set) var value: UInt64

    init(identity: UUID = UUID(), value: UInt64 = 0) {
        self.identity = identity
        self.value = value
    }

    mutating func advance() {
        if value == .max {
            var nextIdentity = UUID()
            while nextIdentity == identity { nextIdentity = UUID() }
            identity = nextIdentity
            value = 0
        } else {
            value += 1
        }
    }
}

struct FaceExtrudeEstimate: Equatable {
    let originalVertexCount: Int
    let originalTriangleCount: Int
    let selectedFaceCount: Int
    let componentCount: Int
    let boundaryEdgeCount: Int
    let selectedUniqueVertexCount: Int
    let resultingVertexCount: Int
    let resultingTriangleCount: Int
    let removedOriginalVertexCount: Int
    let addedExtrudedVertexCount: Int
    let addedSideTriangleCount: Int
    let estimatedWorkingByteCount: Int
    let resultBounds: AxisAlignedBoundingBox
}

struct FaceExtrudeSourceKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let vertexRevision: UInt64
    let meshChangeVersion: FaceExtrudeChangeVersion
    let transformChangeVersion: FaceExtrudeChangeVersion
    let selectionTopologyID: UUID
    let selectionTopologyRevision: UInt64
    let selectionTriangleCount: Int
    let selectionVersion: FaceSelectionVersion
    let selectedFaceCount: Int
    let transform: ObjectTransform
    let options: FaceExtrudeOptions
    let analysisFingerprint: UInt64

    func matches(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        meshChangeVersion: FaceExtrudeChangeVersion,
        transformChangeVersion: FaceExtrudeChangeVersion,
        options: FaceExtrudeOptions
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

struct FaceExtrudePreview: Equatable {
    let options: FaceExtrudeOptions
    let estimate: FaceExtrudeEstimate
    let source: FaceExtrudeSourceKey
}

struct FaceExtrudeResult: Equatable {
    let mesh: EditableMesh
    let estimate: FaceExtrudeEstimate
    let analysisFingerprint: UInt64
}

enum FaceExtrudeError: Error, Equatable, LocalizedError {
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
    case boundarylessComponent
    case zeroComponentNormal
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
        case .noSelection: "Select at least one face before extruding."
        case .staleSelection: "The selected faces belong to an older mesh topology."
        case .invalidDistance: "Enter a finite extrusion distance in millimeters."
        case .distanceTooSmall: "Extrusion distance must be at least 0.001 mm in magnitude."
        case .distanceLimitExceeded: "Extrusion distance must be between -1000 and 1000 mm."
        case .invalidMesh: "The mesh structure or an index is invalid."
        case .nonFiniteValue: "The mesh contains NaN or Infinity."
        case .degenerateTriangle: "Extrude requires a mesh without degenerate triangles."
        case .duplicateTriangle: "Extrude requires a mesh without duplicate triangles."
        case .openSelectedEdge: "The selected region touches an open mesh boundary."
        case .nonManifoldSelectedEdge: "The selected region touches a non-manifold edge."
        case .windingConflict: "The selected region touches an edge with inconsistent winding."
        case .boundarylessComponent: "Each selected component must have a boundary. Whole-shell extrusion is unavailable."
        case .zeroComponentNormal: "A selected component does not have a stable area-weighted normal."
        case .invalidTransform: "The Object Transform is not finite or invertible."
        case .inverseTransformFailure: "The world-space extrusion could not be converted back to object-local coordinates."
        case .selectedFaceLimitExceeded: "Face Extrude supports up to 1,000,000 selected triangles."
        case .vertexLimitExceeded: "The result exceeds the 2,000,000 vertex limit."
        case .triangleLimitExceeded: "The result exceeds the 4,000,000 triangle limit."
        case .indexOverflow: "The result exceeds the supported UInt32 index range."
        case .arithmeticOverflow: "Extrusion size calculation overflowed."
        case .workingMemoryLimitExceeded: "Extrusion would exceed the 768 MiB working-memory limit."
        case .validationFailed: "The extruded mesh failed geometry validation."
        case .stalePreview: "The mesh, Transform, selection, or distance changed. Recalculate the preview."
        case .operationInProgress: "Face Extrude is already running."
        case .activeEdit: "Finish or prepare the active edit before extruding."
        case .unavailable: "Face Extrude is unavailable during the current operation."
        }
    }
}

enum FaceExtrude {
    static let maximumVertices = MeshCleanup.maximumVertices
    static let maximumTriangles = MeshCleanup.maximumTriangles
    static let maximumSelectedFaces = FaceSelectionConnectivity.maximumTriangleCount
    static let maximumWorkingBytes = MeshCleanup.maximumWorkingBytes

    static func makePreview(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceExtrudeOptions,
        meshChangeVersion: FaceExtrudeChangeVersion,
        transformChangeVersion: FaceExtrudeChangeVersion
    ) throws -> FaceExtrudePreview {
        let plan = try makePlan(mesh: mesh, selection: selection, transform: transform, options: options)
        let source = FaceExtrudeSourceKey(
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
            transform: transform.sanitized(),
            options: options,
            analysisFingerprint: plan.fingerprint
        )
        return FaceExtrudePreview(options: options, estimate: plan.estimate, source: source)
    }

    static func estimate(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceExtrudeOptions
    ) throws -> FaceExtrudeEstimate {
        try makePlan(mesh: mesh, selection: selection, transform: transform, options: options).estimate
    }

    static func extrude(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceExtrudeOptions
    ) throws -> FaceExtrudeResult {
        let plan = try makePlan(mesh: mesh, selection: selection, transform: transform, options: options)
        var originalRemap = Array<UInt32?>(repeating: nil, count: mesh.vertices.count)
        var resultVertices: [MeshVertex] = []
        resultVertices.reserveCapacity(plan.estimate.resultingVertexCount)

        for oldIndex in mesh.vertices.indices where plan.referencedOriginalVertices[oldIndex] {
            guard resultVertices.count < Int(UInt32.max) else { throw FaceExtrudeError.indexOverflow }
            originalRemap[oldIndex] = UInt32(resultVertices.count)
            resultVertices.append(mesh.vertices[oldIndex])
        }

        var extrudedRemap: [ExtrudedVertexKey: UInt32] = [:]
        extrudedRemap.reserveCapacity(plan.estimate.addedExtrudedVertexCount)
        for component in plan.components {
            for (offset, originalVertexID) in component.originalVertexIDs.enumerated() {
                guard resultVertices.count < Int(UInt32.max) else { throw FaceExtrudeError.indexOverflow }
                let key = ExtrudedVertexKey(componentID: component.id, originalVertexID: originalVertexID)
                extrudedRemap[key] = UInt32(resultVertices.count)
                resultVertices.append(MeshVertex(position: component.extrudedPositions[offset], normal: .zero))
            }
        }

        let resultIndexCount = try multiply(plan.estimate.resultingTriangleCount, 3)
        var resultIndices: [UInt32] = []
        resultIndices.reserveCapacity(resultIndexCount)

        for faceID in 0..<plan.originalTriangleCount where !plan.selectedFaces[faceID] {
            let indices = try triangleIndices(faceID: faceID, mesh: mesh)
            for oldIndex in indices {
                guard let newIndex = originalRemap[Int(oldIndex)] else { throw FaceExtrudeError.validationFailed }
                resultIndices.append(newIndex)
            }
        }

        for faceID in plan.selectedFaceIDs {
            guard let componentID = plan.componentByFace[faceID] else { throw FaceExtrudeError.validationFailed }
            let indices = try triangleIndices(faceID: faceID, mesh: mesh)
            for oldIndex in indices {
                guard let newIndex = extrudedRemap[
                    ExtrudedVertexKey(componentID: componentID, originalVertexID: oldIndex)
                ] else { throw FaceExtrudeError.validationFailed }
                resultIndices.append(newIndex)
            }
        }

        for edge in plan.boundaryEdges {
            guard let originalA = originalRemap[Int(edge.originalA)],
                  let originalB = originalRemap[Int(edge.originalB)],
                  let extrudedA = extrudedRemap[
                    ExtrudedVertexKey(componentID: edge.componentID, originalVertexID: edge.originalA)],
                  let extrudedB = extrudedRemap[
                    ExtrudedVertexKey(componentID: edge.componentID, originalVertexID: edge.originalB)] else {
                throw FaceExtrudeError.validationFailed
            }
            resultIndices.append(contentsOf: [originalA, originalB, extrudedB,
                                              originalA, extrudedB, extrudedA])
        }

        guard resultVertices.count == plan.estimate.resultingVertexCount,
              resultIndices.count == resultIndexCount else { throw FaceExtrudeError.validationFailed }

        var resultMesh = EditableMesh(vertices: resultVertices, indices: resultIndices)
        resultMesh.recalculateNormals(recordChange: false)
        _ = resultMesh.adjacency()
        _ = try resultMesh.validated(maxVertices: maximumVertices, maxIndices: maximumTriangles * 3)
        try validateResult(mesh: resultMesh, plan: plan)
        return FaceExtrudeResult(mesh: resultMesh, estimate: plan.estimate,
                                 analysisFingerprint: plan.fingerprint)
    }

    static func estimatedWorkingBytes(
        originalVertices: Int,
        originalTriangles: Int,
        selectedFaces: Int,
        boundaryEdges: Int,
        resultingVertices: Int,
        resultingTriangles: Int
    ) throws -> Int {
        guard [originalVertices, originalTriangles, selectedFaces, boundaryEdges,
               resultingVertices, resultingTriangles].allSatisfy({ $0 >= 0 }) else {
            throw FaceExtrudeError.arithmeticOverflow
        }
        let originalIndices = try multiply(originalTriangles, 3)
        let resultingIndices = try multiply(resultingTriangles, 3)
        let sourceVertices = try multiply(originalVertices, MemoryLayout<MeshVertex>.stride * 3)
        let sourceIndices = try multiply(originalIndices, MemoryLayout<UInt32>.stride * 3)
        let resultVertexStorage = try multiply(resultingVertices, MemoryLayout<MeshVertex>.stride * 5)
        let resultIndexStorage = try multiply(resultingIndices, MemoryLayout<UInt32>.stride * 4)
        let mappedVertexCount = try add([originalVertices, resultingVertices])
        let vertexMaps = try multiply(mappedVertexCount, 24)
        let triangleState = try multiply(originalTriangles, 56)
        let selectedState = try multiply(selectedFaces, 80)
        let edgeState = try multiply(originalTriangles, 3 * 64)
        let boundaryState = try multiply(boundaryEdges, 48)
        let runtimeRebuild = try add([
            try multiply(resultingVertices, 32),
            try multiply(resultingTriangles, 112),
            try multiply(resultingIndices, 8)
        ])
        return try add([sourceVertices, sourceIndices, resultVertexStorage, resultIndexStorage,
                        vertexMaps, triangleState, selectedState, edgeState, boundaryState,
                        runtimeRebuild])
    }

    static func validateWorkingByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0 else { throw FaceExtrudeError.arithmeticOverflow }
        guard byteCount <= maximumWorkingBytes else {
            throw FaceExtrudeError.workingMemoryLimitExceeded
        }
    }

    private struct ExtrudedVertexKey: Hashable {
        let componentID: Int
        let originalVertexID: UInt32
    }

    private struct OrientedEdgeUse {
        let faceID: Int
        let slot: Int
        let from: UInt32
        let to: UInt32
    }

    private struct EdgeRecord {
        private(set) var count = 0
        private(set) var first: OrientedEdgeUse?
        private(set) var second: OrientedEdgeUse?

        mutating func append(_ use: OrientedEdgeUse) {
            if count == 0 { first = use }
            else if count == 1 { second = use }
            count += 1
        }

        var uses: [OrientedEdgeUse] { [first, second].compactMap { $0 } }
    }

    private struct RawBoundaryEdge {
        let faceID: Int
        let edgeSlot: Int
        let originalA: UInt32
        let originalB: UInt32
    }

    private struct BoundaryEdge {
        let componentID: Int
        let faceID: Int
        let edgeSlot: Int
        let originalA: UInt32
        let originalB: UInt32
    }

    private struct ComponentPlan {
        let id: Int
        let faceIDs: [Int]
        let originalVertexIDs: [UInt32]
        let extrudedPositions: [SIMD3<Float>]
        let worldNormal: SIMD3<Double>
    }

    private struct Plan {
        let originalTriangleCount: Int
        let selectedFaceIDs: [Int]
        let selectedFaces: [Bool]
        let componentByFace: [Int: Int]
        let components: [ComponentPlan]
        let boundaryEdges: [BoundaryEdge]
        let referencedOriginalVertices: [Bool]
        let sourceBoundaryEdgeCount: Int
        let sourceNonManifoldEdgeCount: Int
        let sourceWindingConflictCount: Int
        let resultLocalBounds: AxisAlignedBoundingBox
        let estimate: FaceExtrudeEstimate
        let fingerprint: UInt64
    }

    private static func makePlan(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        options: FaceExtrudeOptions
    ) throws -> Plan {
        try validate(options: options)
        guard selection.matches(mesh) else { throw FaceExtrudeError.staleSelection }
        guard selection.selectedCount > 0 else { throw FaceExtrudeError.noSelection }
        guard selection.selectedCount <= maximumSelectedFaces else {
            throw FaceExtrudeError.selectedFaceLimitExceeded
        }
        guard mesh.vertices.count >= 3, !mesh.indices.isEmpty,
              mesh.indices.count.isMultiple(of: 3) else { throw FaceExtrudeError.invalidMesh }
        let triangleCount = mesh.indices.count / 3
        guard mesh.vertices.count <= maximumVertices else { throw FaceExtrudeError.vertexLimitExceeded }
        guard triangleCount <= maximumTriangles else { throw FaceExtrudeError.triangleLimitExceeded }
        guard mesh.vertices.count < Int(UInt32.max) else { throw FaceExtrudeError.indexOverflow }
        guard transform.isFinite, matrixIsFinite(transform.modelMatrix),
              matrixIsFinite(transform.inverseModelMatrix) else { throw FaceExtrudeError.invalidTransform }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw FaceExtrudeError.nonFiniteValue
        }

        let selectedFaceIDs = selection.selectedFaceIDs()
        guard selectedFaceIDs.count == selection.selectedCount else { throw FaceExtrudeError.validationFailed }
        let baselineWorkingBytes = try estimatedWorkingBytes(
            originalVertices: mesh.vertices.count,
            originalTriangles: triangleCount,
            selectedFaces: selectedFaceIDs.count,
            boundaryEdges: 0,
            resultingVertices: mesh.vertices.count,
            resultingTriangles: triangleCount
        )
        try validateWorkingByteCount(baselineWorkingBytes)
        var selectedFaces = Array(repeating: false, count: triangleCount)
        for faceID in selectedFaceIDs {
            guard selectedFaces.indices.contains(faceID) else { throw FaceExtrudeError.staleSelection }
            selectedFaces[faceID] = true
        }

        let twiceAreaEpsilon = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: mesh)
        var edgeRecords: [DiagnosticEdgeKey: EdgeRecord] = [:]
        let edgeCapacity = try multiply(triangleCount, 2)
        edgeRecords.reserveCapacity(edgeCapacity)
        var seenTriangles: Set<MeshDiagnosticTriangleKey> = []
        seenTriangles.reserveCapacity(triangleCount)

        for faceID in 0..<triangleCount {
            let triangle = try triangleIndices(faceID: faceID, mesh: mesh)
            let a = triangle[0], b = triangle[1], c = triangle[2]
            guard !MeshDiagnosticTriangleRules.isDegenerate(
                a, b, c, vertices: mesh.vertices, twiceAreaEpsilon: twiceAreaEpsilon
            ) else { throw FaceExtrudeError.degenerateTriangle }
            guard seenTriangles.insert(MeshDiagnosticTriangleKey(a, b, c)).inserted else {
                throw FaceExtrudeError.duplicateTriangle
            }
            for (slot, pair) in [(a, b), (b, c), (c, a)].enumerated() {
                let key = DiagnosticEdgeKey(pair.0, pair.1)
                var record = edgeRecords[key] ?? EdgeRecord()
                record.append(OrientedEdgeUse(faceID: faceID, slot: slot,
                                              from: pair.0, to: pair.1))
                edgeRecords[key] = record
            }
        }

        var sourceBoundaryEdgeCount = 0
        var sourceNonManifoldEdgeCount = 0
        var sourceWindingConflictCount = 0
        for (key, record) in edgeRecords {
            if record.count == 1 { sourceBoundaryEdgeCount += 1 }
            else if record.count > 2 { sourceNonManifoldEdgeCount += 1 }
            else if record.count == 2, let first = record.first, let second = record.second,
                    (first.from == key.low) == (second.from == key.low) {
                sourceWindingConflictCount += 1
            }
        }

        var selectedAdjacency: [Int: [Int]] = [:]
        var rawBoundaries: [RawBoundaryEdge] = []
        var processedEdges: Set<DiagnosticEdgeKey> = []
        processedEdges.reserveCapacity(try multiply(selectedFaceIDs.count, 2))
        for faceID in selectedFaceIDs {
            let triangle = try triangleIndices(faceID: faceID, mesh: mesh)
            for (slot, pair) in [(triangle[0], triangle[1]),
                                 (triangle[1], triangle[2]),
                                 (triangle[2], triangle[0])].enumerated() {
                let key = DiagnosticEdgeKey(pair.0, pair.1)
                guard processedEdges.insert(key).inserted else { continue }
                guard let record = edgeRecords[key] else { throw FaceExtrudeError.invalidMesh }
                if record.count == 1 { throw FaceExtrudeError.openSelectedEdge }
                if record.count != 2 { throw FaceExtrudeError.nonManifoldSelectedEdge }
                guard let first = record.first, let second = record.second else {
                    throw FaceExtrudeError.validationFailed
                }
                guard (first.from == key.low) != (second.from == key.low) else {
                    throw FaceExtrudeError.windingConflict
                }
                let selectedUses = record.uses.filter { selectedFaces[$0.faceID] }
                if selectedUses.count == 1 {
                    let selectedUse = selectedUses[0]
                    rawBoundaries.append(RawBoundaryEdge(
                        faceID: selectedUse.faceID,
                        edgeSlot: selectedUse.slot,
                        originalA: selectedUse.from,
                        originalB: selectedUse.to
                    ))
                } else if selectedUses.count == 2 {
                    selectedAdjacency[selectedUses[0].faceID, default: []].append(selectedUses[1].faceID)
                    selectedAdjacency[selectedUses[1].faceID, default: []].append(selectedUses[0].faceID)
                } else {
                    throw FaceExtrudeError.validationFailed
                }
            }
        }
        for faceID in Array(selectedAdjacency.keys) { selectedAdjacency[faceID]?.sort() }

        var componentByFace: [Int: Int] = [:]
        componentByFace.reserveCapacity(selectedFaceIDs.count)
        var componentFaces: [[Int]] = []
        for seed in selectedFaceIDs where componentByFace[seed] == nil {
            let componentID = componentFaces.count
            var pending = [seed]
            componentByFace[seed] = componentID
            var faces: [Int] = []
            while let faceID = pending.popLast() {
                faces.append(faceID)
                for neighbor in selectedAdjacency[faceID] ?? [] where componentByFace[neighbor] == nil {
                    componentByFace[neighbor] = componentID
                    pending.append(neighbor)
                }
            }
            faces.sort()
            componentFaces.append(faces)
        }

        let boundaryEdges = try rawBoundaries.map { edge -> BoundaryEdge in
            guard let componentID = componentByFace[edge.faceID] else {
                throw FaceExtrudeError.validationFailed
            }
            return BoundaryEdge(componentID: componentID, faceID: edge.faceID,
                                edgeSlot: edge.edgeSlot, originalA: edge.originalA,
                                originalB: edge.originalB)
        }.sorted {
            if $0.componentID != $1.componentID { return $0.componentID < $1.componentID }
            if $0.faceID != $1.faceID { return $0.faceID < $1.faceID }
            return $0.edgeSlot < $1.edgeSlot
        }
        var boundaryCountByComponent = Array(repeating: 0, count: componentFaces.count)
        for edge in boundaryEdges {
            guard boundaryCountByComponent.indices.contains(edge.componentID) else {
                throw FaceExtrudeError.validationFailed
            }
            boundaryCountByComponent[edge.componentID] += 1
        }

        var selectedUniqueVertices: Set<UInt32> = []
        var components: [ComponentPlan] = []
        components.reserveCapacity(componentFaces.count)
        var resultLocalBounds = AxisAlignedBoundingBox()
        var resultWorldBounds = AxisAlignedBoundingBox()
        var referencedOriginalVertices = Array(repeating: false, count: mesh.vertices.count)
        for faceID in 0..<triangleCount where !selectedFaces[faceID] {
            for index in try triangleIndices(faceID: faceID, mesh: mesh) {
                referencedOriginalVertices[Int(index)] = true
            }
        }
        for edge in boundaryEdges {
            referencedOriginalVertices[Int(edge.originalA)] = true
            referencedOriginalVertices[Int(edge.originalB)] = true
        }
        for index in mesh.vertices.indices where referencedOriginalVertices[index] {
            let local = mesh.vertices[index].position
            resultLocalBounds.include(local)
            resultWorldBounds.include(try finiteFloatPosition(
                worldPosition(local, matrix: transform.modelMatrix)))
        }

        let modelMatrix = transform.modelMatrix
        let inverseMatrix = transform.inverseModelMatrix
        let distance = options.distanceMillimeters
        for (componentID, faceIDs) in componentFaces.enumerated() {
            guard boundaryCountByComponent[componentID] > 0 else {
                throw FaceExtrudeError.boundarylessComponent
            }
            var componentVertices: Set<UInt32> = []
            var areaVector = SIMD3<Double>(repeating: 0)
            var componentWorldBounds = DoubleBounds()
            for faceID in faceIDs {
                let triangle = try triangleIndices(faceID: faceID, mesh: mesh)
                triangle.forEach { componentVertices.insert($0); selectedUniqueVertices.insert($0) }
                let worldA = try worldPosition(mesh.vertices[Int(triangle[0])].position, matrix: modelMatrix)
                let worldB = try worldPosition(mesh.vertices[Int(triangle[1])].position, matrix: modelMatrix)
                let worldC = try worldPosition(mesh.vertices[Int(triangle[2])].position, matrix: modelMatrix)
                componentWorldBounds.include(worldA)
                componentWorldBounds.include(worldB)
                componentWorldBounds.include(worldC)
                areaVector += simd_cross(worldB - worldA, worldC - worldA)
            }
            let areaLength = simd_length(areaVector)
            let componentScale = max(componentWorldBounds.diagonalLength, 1.0e-12)
            let normalEpsilon = max(componentScale * componentScale * 1.0e-12,
                                    Double.leastNonzeroMagnitude)
            guard areaLength.isFinite, areaLength > normalEpsilon else {
                throw FaceExtrudeError.zeroComponentNormal
            }
            let worldNormal = areaVector / areaLength
            let displacement = worldNormal * distance
            let originalVertexIDs = componentVertices.sorted()
            var extrudedPositions: [SIMD3<Float>] = []
            extrudedPositions.reserveCapacity(originalVertexIDs.count)
            for originalVertexID in originalVertexIDs {
                let sourceWorld = try worldPosition(
                    mesh.vertices[Int(originalVertexID)].position, matrix: modelMatrix)
                let destinationWorld = sourceWorld + displacement
                let local = try localPosition(destinationWorld, matrix: inverseMatrix)
                extrudedPositions.append(local)
                resultLocalBounds.include(local)
                resultWorldBounds.include(try finiteFloatPosition(destinationWorld))
            }
            components.append(ComponentPlan(id: componentID, faceIDs: faceIDs,
                                            originalVertexIDs: originalVertexIDs,
                                            extrudedPositions: extrudedPositions,
                                            worldNormal: worldNormal))
        }

        let retainedOriginalCount = referencedOriginalVertices.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        let removedOriginalCount = mesh.vertices.count - retainedOriginalCount
        let addedExtrudedCount = try add(components.map { $0.originalVertexIDs.count })
        let resultingVertexCount = try add([retainedOriginalCount, addedExtrudedCount])
        let addedSideTriangleCount = try multiply(boundaryEdges.count, 2)
        let resultingTriangleCount = try add([triangleCount, addedSideTriangleCount])
        guard resultingVertexCount <= maximumVertices else { throw FaceExtrudeError.vertexLimitExceeded }
        guard resultingTriangleCount <= maximumTriangles else { throw FaceExtrudeError.triangleLimitExceeded }
        guard resultingVertexCount < Int(UInt32.max) else { throw FaceExtrudeError.indexOverflow }
        guard resultLocalBounds.isFinite, resultWorldBounds.isFinite else {
            throw FaceExtrudeError.validationFailed
        }
        let workingBytes = try estimatedWorkingBytes(
            originalVertices: mesh.vertices.count,
            originalTriangles: triangleCount,
            selectedFaces: selectedFaceIDs.count,
            boundaryEdges: boundaryEdges.count,
            resultingVertices: resultingVertexCount,
            resultingTriangles: resultingTriangleCount
        )
        try validateWorkingByteCount(workingBytes)
        let estimate = FaceExtrudeEstimate(
            originalVertexCount: mesh.vertices.count,
            originalTriangleCount: triangleCount,
            selectedFaceCount: selectedFaceIDs.count,
            componentCount: components.count,
            boundaryEdgeCount: boundaryEdges.count,
            selectedUniqueVertexCount: selectedUniqueVertices.count,
            resultingVertexCount: resultingVertexCount,
            resultingTriangleCount: resultingTriangleCount,
            removedOriginalVertexCount: removedOriginalCount,
            addedExtrudedVertexCount: addedExtrudedCount,
            addedSideTriangleCount: addedSideTriangleCount,
            estimatedWorkingByteCount: workingBytes,
            resultBounds: resultWorldBounds
        )
        let fingerprint = fingerprint(
            selectedFaceIDs: selectedFaceIDs,
            components: components,
            boundaryEdges: boundaryEdges,
            estimate: estimate
        )
        return Plan(originalTriangleCount: triangleCount,
                    selectedFaceIDs: selectedFaceIDs,
                    selectedFaces: selectedFaces,
                    componentByFace: componentByFace,
                    components: components,
                    boundaryEdges: boundaryEdges,
                    referencedOriginalVertices: referencedOriginalVertices,
                    sourceBoundaryEdgeCount: sourceBoundaryEdgeCount,
                    sourceNonManifoldEdgeCount: sourceNonManifoldEdgeCount,
                    sourceWindingConflictCount: sourceWindingConflictCount,
                    resultLocalBounds: resultLocalBounds,
                    estimate: estimate,
                    fingerprint: fingerprint)
    }

    private static func validate(options: FaceExtrudeOptions) throws {
        let distance = options.distanceMillimeters
        guard distance.isFinite else { throw FaceExtrudeError.invalidDistance }
        guard abs(distance) >= FaceExtrudeOptions.minimumAbsoluteDistanceMillimeters else {
            throw FaceExtrudeError.distanceTooSmall
        }
        guard abs(distance) <= FaceExtrudeOptions.maximumAbsoluteDistanceMillimeters else {
            throw FaceExtrudeError.distanceLimitExceeded
        }
    }

    private static func validateResult(mesh: EditableMesh, plan: Plan) throws {
        guard mesh.vertices.count == plan.estimate.resultingVertexCount,
              mesh.indices.count / 3 == plan.estimate.resultingTriangleCount,
              mesh.bounds == plan.resultLocalBounds else { throw FaceExtrudeError.validationFailed }
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        guard !topology.hasInvalidStructure,
              topology.invalidIndexTriangleCount == 0,
              topology.nonFiniteVertexCount == 0,
              topology.degenerateTriangleCount == 0,
              topology.duplicateTriangleCount == 0,
              topology.boundaryEdgeCount == plan.sourceBoundaryEdgeCount,
              topology.nonManifoldEdgeCount == plan.sourceNonManifoldEdgeCount,
              topology.inconsistentWindingEdgeCount == plan.sourceWindingConflictCount else {
            throw FaceExtrudeError.validationFailed
        }
        guard mesh.vertices.allSatisfy({ vertex in
            let normalLength = simd_length(vertex.normal)
            return vertex.position.allFinite && vertex.normal.allFinite
                && normalLength.isFinite && abs(normalLength - 1) <= 0.000_1
        }) else { throw FaceExtrudeError.validationFailed }
    }

    private static func triangleIndices(faceID: Int, mesh: EditableMesh) throws -> [UInt32] {
        let (offset, offsetOverflow) = faceID.multipliedReportingOverflow(by: 3)
        let (lastOffset, lastOverflow) = offset.addingReportingOverflow(2)
        guard faceID >= 0, !offsetOverflow, !lastOverflow,
              lastOffset < mesh.indices.count else { throw FaceExtrudeError.invalidMesh }
        let result = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
        guard result.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw FaceExtrudeError.invalidMesh
        }
        return result
    }

    private static func worldPosition(_ local: SIMD3<Float>, matrix: simd_float4x4) throws -> SIMD3<Double> {
        let value = matrix * SIMD4<Float>(local, 1)
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              value.w.isFinite, abs(value.w) > 0.000_001 else {
            throw FaceExtrudeError.invalidTransform
        }
        let point = SIMD3<Double>(Double(value.x / value.w),
                                  Double(value.y / value.w),
                                  Double(value.z / value.w))
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
            throw FaceExtrudeError.nonFiniteValue
        }
        return point
    }

    private static func localPosition(_ world: SIMD3<Double>, matrix: simd_float4x4) throws -> SIMD3<Float> {
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
              abs(world.x) <= Double(Float.greatestFiniteMagnitude),
              abs(world.y) <= Double(Float.greatestFiniteMagnitude),
              abs(world.z) <= Double(Float.greatestFiniteMagnitude) else {
            throw FaceExtrudeError.inverseTransformFailure
        }
        let value = matrix * SIMD4<Float>(Float(world.x), Float(world.y), Float(world.z), 1)
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              value.w.isFinite, abs(value.w) > 0.000_001 else {
            throw FaceExtrudeError.inverseTransformFailure
        }
        let result = SIMD3<Float>(value.x, value.y, value.z) / value.w
        guard result.allFinite else { throw FaceExtrudeError.inverseTransformFailure }
        return result
    }

    private static func finiteFloatPosition(_ value: SIMD3<Double>) throws -> SIMD3<Float> {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              abs(value.x) <= Double(Float.greatestFiniteMagnitude),
              abs(value.y) <= Double(Float.greatestFiniteMagnitude),
              abs(value.z) <= Double(Float.greatestFiniteMagnitude) else {
            throw FaceExtrudeError.nonFiniteValue
        }
        let result = SIMD3<Float>(Float(value.x), Float(value.y), Float(value.z))
        guard result.allFinite else { throw FaceExtrudeError.nonFiniteValue }
        return result
    }

    private static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 where !matrix.columns[column][row].isFinite { return false }
        }
        return true
    }

    private struct DoubleBounds {
        var minimum = SIMD3<Double>(repeating: .infinity)
        var maximum = SIMD3<Double>(repeating: -.infinity)

        mutating func include(_ point: SIMD3<Double>) {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }

        var diagonalLength: Double {
            let value = simd_length(maximum - minimum)
            return value.isFinite ? value : 0
        }
    }

    private static func fingerprint(
        selectedFaceIDs: [Int],
        components: [ComponentPlan],
        boundaryEdges: [BoundaryEdge],
        estimate: FaceExtrudeEstimate
    ) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        func mix(_ item: UInt64) {
            value ^= item
            value &*= 1_099_511_628_211
        }
        mix(UInt64(selectedFaceIDs.count))
        selectedFaceIDs.forEach { mix(UInt64($0)) }
        for component in components {
            mix(UInt64(component.id))
            component.faceIDs.forEach { mix(UInt64($0)) }
            component.originalVertexIDs.forEach { mix(UInt64($0)) }
            for position in component.extrudedPositions {
                mix(UInt64(position.x.bitPattern))
                mix(UInt64(position.y.bitPattern))
                mix(UInt64(position.z.bitPattern))
            }
        }
        for edge in boundaryEdges {
            mix(UInt64(edge.componentID))
            mix(UInt64(edge.faceID))
            mix(UInt64(edge.edgeSlot))
            mix(UInt64(edge.originalA))
            mix(UInt64(edge.originalB))
        }
        mix(UInt64(estimate.resultingVertexCount))
        mix(UInt64(estimate.resultingTriangleCount))
        return value
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw FaceExtrudeError.arithmeticOverflow }
        return result.partialValue
    }

    private static func add(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { throw FaceExtrudeError.arithmeticOverflow }
            result = next.partialValue
        }
        return result
    }
}
