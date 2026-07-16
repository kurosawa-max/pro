import Foundation
import simd

enum MeshDiagnosticSeverity: Int, Comparable, CaseIterable {
    case healthy
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

enum MeshDiagnosticIssueKind: String, CaseIterable, Hashable {
    case invalidStructure
    case invalidIndex
    case nonFiniteValue
    case boundaryEdge
    case nonManifoldEdge
    case inconsistentWinding
    case degenerateTriangle
    case duplicateTriangle
    case isolatedVertex
    case disconnectedComponent
    case inwardOrientation
    case nearZeroVolume
}

struct MeshDiagnosticIssue: Identifiable, Equatable {
    var id: MeshDiagnosticIssueKind { kind }
    let kind: MeshDiagnosticIssueKind
    let severity: MeshDiagnosticSeverity
    let count: Int
    let message: String
}

struct DiagnosticEdgeKey: Hashable, Comparable {
    let low: UInt32
    let high: UInt32

    init(_ first: UInt32, _ second: UInt32) {
        low = min(first, second)
        high = max(first, second)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.low == rhs.low ? lhs.high < rhs.high : lhs.low < rhs.low
    }
}

struct MeshDiagnosticSegment: Equatable {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
}

struct MeshDiagnosticsOverlayOptions: Equatable {
    var isVisible = true
    var boundaryEdges = true
    var nonManifoldEdges = true
    var windingConflicts = true
    var degenerateTriangles = true
    var isolatedVertices = true
}

struct MeshDiagnosticsOverlayData: Equatable {
    var boundaryEdges: [MeshDiagnosticSegment] = []
    var nonManifoldEdges: [MeshDiagnosticSegment] = []
    var windingConflicts: [MeshDiagnosticSegment] = []
    var degenerateTrianglePoints: [SIMD3<Float>] = []
    var isolatedVertexPoints: [SIMD3<Float>] = []

    var isEmpty: Bool {
        boundaryEdges.isEmpty && nonManifoldEdges.isEmpty && windingConflicts.isEmpty
            && degenerateTrianglePoints.isEmpty && isolatedVertexPoints.isEmpty
    }

    func filtered(by options: MeshDiagnosticsOverlayOptions) -> MeshDiagnosticsOverlayData {
        guard options.isVisible else { return MeshDiagnosticsOverlayData() }
        return MeshDiagnosticsOverlayData(
            boundaryEdges: options.boundaryEdges ? boundaryEdges : [],
            nonManifoldEdges: options.nonManifoldEdges ? nonManifoldEdges : [],
            windingConflicts: options.windingConflicts ? windingConflicts : [],
            degenerateTrianglePoints: options.degenerateTriangles ? degenerateTrianglePoints : [],
            isolatedVertexPoints: options.isolatedVertices ? isolatedVertexPoints : []
        )
    }
}

struct MeshTopologyReport: Equatable {
    let vertexCount: Int
    let triangleCount: Int
    let uniqueEdgeCount: Int
    let boundaryEdgeCount: Int
    let manifoldEdgeCount: Int
    let nonManifoldEdgeCount: Int
    let degenerateTriangleCount: Int
    let duplicateTriangleCount: Int
    let isolatedVertexCount: Int
    let connectedComponentCount: Int
    let componentTriangleCounts: [Int]
    let largestComponentTriangleCount: Int
    let inconsistentWindingEdgeCount: Int
    let invalidIndexTriangleCount: Int
    let nonFiniteVertexCount: Int
    let hasInvalidStructure: Bool
    let representativeBoundaryEdges: [MeshDiagnosticSegment]
    let representativeNonManifoldEdges: [MeshDiagnosticSegment]
    let representativeWindingConflicts: [MeshDiagnosticSegment]
    let representativeDegenerateTriangleIDs: [Int]
    let representativeDuplicateTriangleIDs: [Int]
    let representativeIsolatedVertexIDs: [Int]
    let representativeSmallComponentPoints: [SIMD3<Float>]
    let representativeDegeneratePoints: [SIMD3<Float>]
    let representativeIsolatedPoints: [SIMD3<Float>]

    var isManifold: Bool {
        !hasInvalidStructure && invalidIndexTriangleCount == 0 && nonFiniteVertexCount == 0
            && nonManifoldEdgeCount == 0 && duplicateTriangleCount == 0 && degenerateTriangleCount == 0
    }

    var isClosed: Bool { triangleCount > 0 && isManifold && boundaryEdgeCount == 0 }

    var hasConsistentOrientation: Bool {
        !hasInvalidStructure && invalidIndexTriangleCount == 0 && nonManifoldEdgeCount == 0
            && inconsistentWindingEdgeCount == 0
    }
}

struct MeshLocalMetrics: Equatable {
    let bounds: AxisAlignedBoundingBox
    let surfaceAreaMM2: Double
    let signedVolumeMM3: Double
    var absoluteVolumeMM3: Double { abs(signedVolumeMM3) }
}

struct MeshWorldMetrics: Equatable {
    let bounds: AxisAlignedBoundingBox
    let dimensionsMM: SIMD3<Float>
    let surfaceAreaMM2: Double
    let signedVolumeMM3: Double?
    var absoluteVolumeMM3: Double? { signedVolumeMM3.map { abs($0) } }
}

struct MeshSubdivisionDiagnostic: Equatable {
    let canSubdivide: Bool
    let estimate: SubdivisionEstimate?
    let failureReason: String?
}

struct MeshSTLExportDiagnostic: Equatable {
    let canExport: Bool
    let estimate: STLExportEstimate?
    let hasPrintabilityWarning: Bool
    let failureReason: String?
}

struct MeshDiagnosticsReport: Equatable {
    let topology: MeshTopologyReport
    let localMetrics: MeshLocalMetrics
    let worldMetrics: MeshWorldMetrics
    let volumeIsReliable: Bool
    let subdivision: MeshSubdivisionDiagnostic
    let stlExport: MeshSTLExportDiagnostic
    let severity: MeshDiagnosticSeverity
    let issues: [MeshDiagnosticIssue]
    let overlay: MeshDiagnosticsOverlayData
    let sourceTopologyID: UUID
    let sourceTopologyRevision: UInt64
    let sourceRevision: UInt64
    let sourceTransform: ObjectTransform

    var vertexCount: Int { topology.vertexCount }
    var triangleCount: Int { topology.triangleCount }
    var uniqueEdgeCount: Int { topology.uniqueEdgeCount }
    var canSubdivide: Bool { subdivision.canSubdivide }
    var canExportSTL: Bool { stlExport.canExport }
}

struct MeshDiagnosticsCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let revision: UInt64
    let transform: ObjectTransform

    init(mesh: EditableMesh, transform: ObjectTransform) {
        topologyID = mesh.runtime.topologyID
        topologyRevision = mesh.runtime.topologyRevision
        revision = mesh.runtime.revision
        self.transform = transform.sanitized()
    }
}

final class MeshDiagnosticsCache {
    private var key: MeshDiagnosticsCacheKey?
    private var cachedReport: MeshDiagnosticsReport?
    private(set) var analysisCount = 0
    private(set) var reuseCount = 0

    func report(mesh: EditableMesh, transform: ObjectTransform) -> MeshDiagnosticsReport {
        let requestedKey = MeshDiagnosticsCacheKey(mesh: mesh, transform: transform)
        if key == requestedKey, let cachedReport {
            reuseCount += 1
            return cachedReport
        }
        let report = MeshDiagnostics.analyze(mesh: mesh, transform: transform)
        key = requestedKey
        cachedReport = report
        analysisCount += 1
        return report
    }

    func isCurrent(mesh: EditableMesh, transform: ObjectTransform) -> Bool {
        key == MeshDiagnosticsCacheKey(mesh: mesh, transform: transform) && cachedReport != nil
    }

    func invalidate() {
        key = nil
        cachedReport = nil
    }
}

enum MeshTopologyDiagnostics {
    static let representativeLimit = 1_000

    static func analyze(_ mesh: EditableMesh) -> MeshTopologyReport {
        let vertexCount = mesh.vertices.count
        let triangleCount = mesh.indices.count / 3
        let hasInvalidStructure = mesh.indices.isEmpty || !mesh.indices.count.isMultiple(of: 3)
        let nonFiniteVertexCount = mesh.vertices.reduce(into: 0) { count, vertex in
            if !vertex.position.allFinite || !vertex.normal.allFinite { count += 1 }
        }
        var referenced = Array(repeating: false, count: vertexCount)
        var activeTriangles = Array(repeating: false, count: triangleCount)
        var unionFind = DiagnosticUnionFind(count: triangleCount)
        var edges: [DiagnosticEdgeKey: DiagnosticEdgeUse] = [:]
        edges.reserveCapacity(min(mesh.indices.count, triangleCount * 2))
        var edgeOrder: [DiagnosticEdgeKey] = []
        edgeOrder.reserveCapacity(min(mesh.indices.count, triangleCount * 2))
        var seenTriangles: [MeshDiagnosticTriangleKey: Int] = [:]
        seenTriangles.reserveCapacity(triangleCount)
        var duplicateTriangleCount = 0
        var degenerateTriangleCount = 0
        var invalidIndexTriangleCount = 0
        var duplicateTriangleIDs: [Int] = []
        var degenerateTriangleIDs: [Int] = []
        var degeneratePoints: [SIMD3<Float>] = []
        degeneratePoints.reserveCapacity(min(triangleCount, representativeLimit))

        let twiceAreaEpsilon = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: mesh)

        for triangle in 0..<triangleCount {
            let offset = triangle * 3
            let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
            let raw = [a, b, c]
            for index in raw where Int(index) < vertexCount { referenced[Int(index)] = true }
            guard raw.allSatisfy({ Int($0) < vertexCount }) else {
                invalidIndexTriangleCount += 1
                continue
            }

            let pa = mesh.vertices[Int(a)].position
            let pb = mesh.vertices[Int(b)].position
            let pc = mesh.vertices[Int(c)].position
            guard pa.allFinite, pb.allFinite, pc.allFinite else { continue }
            let centroid = (pa + pb + pc) / 3
            let repeated = a == b || b == c || c == a
            let degenerate = MeshDiagnosticTriangleRules.isDegenerate(
                a, b, c, vertices: mesh.vertices, twiceAreaEpsilon: twiceAreaEpsilon
            )
            if degenerate {
                degenerateTriangleCount += 1
                if degeneratePoints.count < representativeLimit {
                    degenerateTriangleIDs.append(triangle)
                    degeneratePoints.append(centroid)
                }
            }

            if seenTriangles.updateValue(triangle, forKey: MeshDiagnosticTriangleKey(a, b, c)) != nil {
                duplicateTriangleCount += 1
                if duplicateTriangleIDs.count < representativeLimit { duplicateTriangleIDs.append(triangle) }
            }
            guard !repeated else { continue }
            activeTriangles[triangle] = true
            for (from, to) in [(a, b), (b, c), (c, a)] {
                let key = DiagnosticEdgeKey(from, to)
                if var use = edges[key] {
                    unionFind.union(triangle, use.firstTriangle)
                    use.append(isForward: from == key.low)
                    edges[key] = use
                } else {
                    edges[key] = DiagnosticEdgeUse(firstTriangle: triangle, isForward: from == key.low)
                    edgeOrder.append(key)
                }
            }
        }

        var boundaryCount = 0, manifoldCount = 0, nonManifoldCount = 0, windingCount = 0
        var boundary: [MeshDiagnosticSegment] = []
        var nonManifold: [MeshDiagnosticSegment] = []
        var winding: [MeshDiagnosticSegment] = []
        for key in edgeOrder {
            guard let use = edges[key], Int(key.low) < vertexCount, Int(key.high) < vertexCount else { continue }
            let segment = MeshDiagnosticSegment(start: mesh.vertices[Int(key.low)].position,
                                                end: mesh.vertices[Int(key.high)].position)
            switch use.count {
            case 1:
                boundaryCount += 1
                if boundary.count < representativeLimit { boundary.append(segment) }
            case 2:
                manifoldCount += 1
                if use.firstIsForward == use.secondIsForward {
                    windingCount += 1
                    if winding.count < representativeLimit { winding.append(segment) }
                }
            default:
                nonManifoldCount += 1
                if nonManifold.count < representativeLimit { nonManifold.append(segment) }
            }
        }

        var componentCounts: [Int: Int] = [:]
        var componentPoints: [Int: SIMD3<Float>] = [:]
        var componentOrder: [Int] = []
        for triangle in 0..<triangleCount where activeTriangles[triangle] {
            let root = unionFind.find(triangle)
            if componentCounts[root] == nil { componentOrder.append(root) }
            componentCounts[root, default: 0] += 1
            if componentPoints[root] == nil {
                let offset = triangle * 3
                let a = mesh.vertices[Int(mesh.indices[offset])].position
                let b = mesh.vertices[Int(mesh.indices[offset + 1])].position
                let c = mesh.vertices[Int(mesh.indices[offset + 2])].position
                componentPoints[root] = (a + b + c) / 3
            }
        }
        var largestComponentRoot: Int?
        var largestComponentTriangleCount = 0
        for root in componentOrder {
            let count = componentCounts[root] ?? 0
            if count > largestComponentTriangleCount {
                largestComponentRoot = root
                largestComponentTriangleCount = count
            }
        }
        var orderedComponentCounts: [Int] = []
        orderedComponentCounts.reserveCapacity(componentOrder.count)
        if let largestComponentRoot {
            orderedComponentCounts.append(largestComponentTriangleCount)
            for root in componentOrder where root != largestComponentRoot {
                orderedComponentCounts.append(componentCounts[root] ?? 0)
            }
        }
        let smallComponentPoints = componentOrder.lazy
            .filter { $0 != largestComponentRoot }
            .prefix(representativeLimit)
            .compactMap { componentPoints[$0] }
        var isolatedVertexCount = 0
        var isolatedIDs: [Int] = []
        var isolatedPoints: [SIMD3<Float>] = []
        isolatedIDs.reserveCapacity(min(vertexCount, representativeLimit))
        isolatedPoints.reserveCapacity(min(vertexCount, representativeLimit))
        for index in referenced.indices where !referenced[index] {
            isolatedVertexCount += 1
            guard isolatedIDs.count < representativeLimit else { continue }
            isolatedIDs.append(index)
            let position = mesh.vertices[index].position
            if position.allFinite { isolatedPoints.append(position) }
        }
        return MeshTopologyReport(
            vertexCount: vertexCount,
            triangleCount: triangleCount,
            uniqueEdgeCount: edges.count,
            boundaryEdgeCount: boundaryCount,
            manifoldEdgeCount: manifoldCount,
            nonManifoldEdgeCount: nonManifoldCount,
            degenerateTriangleCount: degenerateTriangleCount,
            duplicateTriangleCount: duplicateTriangleCount,
            isolatedVertexCount: isolatedVertexCount,
            connectedComponentCount: orderedComponentCounts.count,
            componentTriangleCounts: orderedComponentCounts,
            largestComponentTriangleCount: largestComponentTriangleCount,
            inconsistentWindingEdgeCount: windingCount,
            invalidIndexTriangleCount: invalidIndexTriangleCount,
            nonFiniteVertexCount: nonFiniteVertexCount,
            hasInvalidStructure: hasInvalidStructure,
            representativeBoundaryEdges: boundary,
            representativeNonManifoldEdges: nonManifold,
            representativeWindingConflicts: winding,
            representativeDegenerateTriangleIDs: degenerateTriangleIDs,
            representativeDuplicateTriangleIDs: duplicateTriangleIDs,
            representativeIsolatedVertexIDs: isolatedIDs,
            representativeSmallComponentPoints: Array(smallComponentPoints),
            representativeDegeneratePoints: Array(degeneratePoints.prefix(representativeLimit)),
            representativeIsolatedPoints: Array(isolatedPoints)
        )
    }
}

enum MeshMetricDiagnostics {
    static func localMetrics(mesh: EditableMesh) -> MeshLocalMetrics {
        var surfaceArea = 0.0
        var signedVolume = 0.0
        let twiceAreaEpsilon = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: mesh)
        forEachFiniteTriangle(mesh: mesh) { a, b, c in
            let cross = simd_cross(b - a, c - a)
            let twiceArea = simd_length(cross)
            guard twiceArea.isFinite, twiceArea > twiceAreaEpsilon else { return }
            surfaceArea += twiceArea * 0.5
            let contribution = simd_dot(a, simd_cross(b, c)) / 6.0
            if contribution.isFinite { signedVolume += contribution }
        }
        return MeshLocalMetrics(bounds: mesh.bounds,
                                surfaceAreaMM2: surfaceArea.isFinite ? surfaceArea : 0,
                                signedVolumeMM3: signedVolume.isFinite ? signedVolume : 0)
    }

    static func worldMetrics(mesh: EditableMesh, transform: ObjectTransform,
                             trustedLocalSignedVolume: Double?) -> MeshWorldMetrics {
        guard transform.isFinite, let dimensions = ObjectDimensions.make(mesh: mesh, transform: transform) else {
            return MeshWorldMetrics(bounds: AxisAlignedBoundingBox(), dimensionsMM: .zero,
                                    surfaceAreaMM2: 0, signedVolumeMM3: nil)
        }
        let safe = transform.sanitized()
        var surfaceArea = 0.0
        let localTwiceAreaEpsilon = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: mesh)
        let worldScale = max(Double(simd_length(dimensions.worldSize)), 1.0e-12)
        let twiceAreaEpsilon = max(worldScale * worldScale * 1.0e-15, Double.leastNonzeroMagnitude)
        forEachFiniteTriangle(mesh: mesh) { a, b, c in
            let localTwiceArea = simd_length(simd_cross(b - a, c - a))
            guard localTwiceArea.isFinite, localTwiceArea > localTwiceAreaEpsilon else { return }
            let wa = DiagnosticMath.double(safe.worldPosition(fromLocal: DiagnosticMath.float(a)))
            let wb = DiagnosticMath.double(safe.worldPosition(fromLocal: DiagnosticMath.float(b)))
            let wc = DiagnosticMath.double(safe.worldPosition(fromLocal: DiagnosticMath.float(c)))
            let twiceArea = simd_length(simd_cross(wb - wa, wc - wa))
            if twiceArea.isFinite, twiceArea > twiceAreaEpsilon { surfaceArea += twiceArea * 0.5 }
        }
        let determinant = Double(abs(safe.scale.x * safe.scale.y * safe.scale.z))
        let worldSignedVolume = trustedLocalSignedVolume.flatMap { value -> Double? in
            let transformed = value * determinant
            return transformed.isFinite ? transformed : nil
        }
        return MeshWorldMetrics(bounds: dimensions.worldBounds, dimensionsMM: dimensions.worldSize,
                                surfaceAreaMM2: surfaceArea.isFinite ? surfaceArea : 0,
                                signedVolumeMM3: worldSignedVolume)
    }

    private static func forEachFiniteTriangle(
        mesh: EditableMesh,
        _ body: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) -> Void
    ) {
        guard mesh.indices.count >= 3 else { return }
        for offset in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let a = Int(mesh.indices[offset]), b = Int(mesh.indices[offset + 1]), c = Int(mesh.indices[offset + 2])
            guard mesh.vertices.indices.contains(a), mesh.vertices.indices.contains(b), mesh.vertices.indices.contains(c) else { continue }
            let pa = mesh.vertices[a].position, pb = mesh.vertices[b].position, pc = mesh.vertices[c].position
            guard pa.allFinite, pb.allFinite, pc.allFinite else { continue }
            body(DiagnosticMath.double(pa), DiagnosticMath.double(pb), DiagnosticMath.double(pc))
        }
    }
}

enum MeshDiagnosticsOverlayBuilder {
    static func make(from topology: MeshTopologyReport) -> MeshDiagnosticsOverlayData {
        MeshDiagnosticsOverlayData(
            boundaryEdges: topology.representativeBoundaryEdges,
            nonManifoldEdges: topology.representativeNonManifoldEdges,
            windingConflicts: topology.representativeWindingConflicts,
            degenerateTrianglePoints: topology.representativeDegeneratePoints,
            isolatedVertexPoints: topology.representativeIsolatedPoints
        )
    }
}

enum MeshDiagnostics {
    static func analyze(mesh: EditableMesh, transform: ObjectTransform) -> MeshDiagnosticsReport {
        let safeTransform = transform.sanitized()
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        let local = MeshMetricDiagnostics.localMetrics(mesh: mesh)
        let volumeReliable = topology.isClosed && topology.hasConsistentOrientation
        let world = MeshMetricDiagnostics.worldMetrics(
            mesh: mesh,
            transform: transform,
            trustedLocalSignedVolume: volumeReliable ? local.signedVolumeMM3 : nil
        )
        let subdivision = subdivisionDiagnostic(mesh)
        let export = exportDiagnostic(mesh: mesh, transform: transform, topology: topology, local: local)
        let issues = makeIssues(topology: topology, local: local, volumeReliable: volumeReliable,
                                transformIsFinite: transform.isFinite)
        return MeshDiagnosticsReport(
            topology: topology,
            localMetrics: local,
            worldMetrics: world,
            volumeIsReliable: volumeReliable,
            subdivision: subdivision,
            stlExport: export,
            severity: issues.map(\.severity).max() ?? .healthy,
            issues: issues,
            overlay: MeshDiagnosticsOverlayBuilder.make(from: topology),
            sourceTopologyID: mesh.runtime.topologyID,
            sourceTopologyRevision: mesh.runtime.topologyRevision,
            sourceRevision: mesh.runtime.revision,
            sourceTransform: safeTransform
        )
    }

    private static func subdivisionDiagnostic(_ mesh: EditableMesh) -> MeshSubdivisionDiagnostic {
        do {
            let estimate = try MeshSubdivision.estimate(mesh)
            try MeshSubdivision.validateLimits(estimate)
            return MeshSubdivisionDiagnostic(canSubdivide: true, estimate: estimate, failureReason: nil)
        } catch {
            return MeshSubdivisionDiagnostic(canSubdivide: false, estimate: nil,
                                             failureReason: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private static func exportDiagnostic(mesh: EditableMesh, transform: ObjectTransform,
                                         topology: MeshTopologyReport,
                                         local: MeshLocalMetrics) -> MeshSTLExportDiagnostic {
        do {
            let estimate = try STLExportPipeline.estimate(mesh: mesh, transform: transform)
            let volumeScale = max(pow(max(local.surfaceAreaMM2, 0), 1.5), 1.0)
            let volumeEpsilon = volumeScale * 1.0e-12
            let warning = !topology.isClosed || !topology.hasConsistentOrientation
                || topology.connectedComponentCount != 1 || topology.isolatedVertexCount > 0
                || local.signedVolumeMM3 <= volumeEpsilon
            return MeshSTLExportDiagnostic(canExport: true, estimate: estimate,
                                           hasPrintabilityWarning: warning, failureReason: nil)
        } catch {
            return MeshSTLExportDiagnostic(canExport: false, estimate: nil, hasPrintabilityWarning: false,
                                           failureReason: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private static func makeIssues(topology: MeshTopologyReport, local: MeshLocalMetrics,
                                   volumeReliable: Bool, transformIsFinite: Bool) -> [MeshDiagnosticIssue] {
        var issues: [MeshDiagnosticIssue] = []
        func add(_ kind: MeshDiagnosticIssueKind, _ severity: MeshDiagnosticSeverity,
                 _ count: Int, _ message: String) {
            guard count > 0 else { return }
            issues.append(MeshDiagnosticIssue(kind: kind, severity: severity, count: count, message: message))
        }
        add(.invalidStructure, .error, topology.hasInvalidStructure ? 1 : 0,
            "The index list is not a complete triangle list.")
        add(.invalidIndex, .error, topology.invalidIndexTriangleCount,
            "\(topology.invalidIndexTriangleCount) triangles contain out-of-range indices.")
        let nonFiniteCount = topology.nonFiniteVertexCount + (transformIsFinite ? 0 : 1)
        add(.nonFiniteValue, .error, nonFiniteCount,
            transformIsFinite
                ? "\(topology.nonFiniteVertexCount) vertices contain NaN or Infinity."
                : "The mesh or object Transform contains NaN or Infinity.")
        add(.degenerateTriangle, .error, topology.degenerateTriangleCount,
            "\(topology.degenerateTriangleCount) degenerate triangles detected.")
        add(.duplicateTriangle, .error, topology.duplicateTriangleCount,
            "\(topology.duplicateTriangleCount) duplicate triangles detected.")
        add(.nonManifoldEdge, .error, topology.nonManifoldEdgeCount,
            "\(topology.nonManifoldEdgeCount) non-manifold edges prevent safe subdivision.")
        add(.inconsistentWinding, .error, topology.inconsistentWindingEdgeCount,
            "\(topology.inconsistentWindingEdgeCount) shared edges have inconsistent winding.")
        add(.boundaryEdge, .warning, topology.boundaryEdgeCount,
            "\(topology.boundaryEdgeCount) boundary edges detected. The mesh is open.")
        add(.isolatedVertex, .warning, topology.isolatedVertexCount,
            "\(topology.isolatedVertexCount) isolated vertices are not used by triangles.")
        add(.disconnectedComponent, .warning, max(topology.connectedComponentCount - 1, 0),
            "The mesh contains \(topology.connectedComponentCount) edge-connected components.")
        if volumeReliable {
            let scale = max(pow(max(local.surfaceAreaMM2, 0), 1.5), 1.0)
            let epsilon = scale * 1.0e-12
            add(.nearZeroVolume, .warning, abs(local.signedVolumeMM3) <= epsilon ? 1 : 0,
                "The signed volume is near zero.")
            add(.inwardOrientation, .warning, local.signedVolumeMM3 < -epsilon ? 1 : 0,
                "The closed mesh appears to be inward-facing.")
        }
        return issues
    }
}

private struct DiagnosticEdgeUse {
    let firstTriangle: Int
    let firstIsForward: Bool
    private(set) var count = 1
    private(set) var secondIsForward = false

    init(firstTriangle: Int, isForward: Bool) {
        self.firstTriangle = firstTriangle
        firstIsForward = isForward
    }

    mutating func append(isForward: Bool) {
        if count == 1 { secondIsForward = isForward }
        count += 1
    }
}

struct MeshDiagnosticTriangleKey: Hashable {
    let first: UInt32
    let second: UInt32
    let third: UInt32

    init(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let sorted = [a, b, c].sorted()
        first = sorted[0]
        second = sorted[1]
        third = sorted[2]
    }
}

enum MeshDiagnosticTriangleRules {
    static func twiceAreaEpsilon(for mesh: EditableMesh) -> Double {
        let scale = max(Double(simd_length(mesh.bounds.extent)), 1.0e-12)
        return max(scale * scale * 1.0e-12, Double.leastNonzeroMagnitude)
    }

    static func isDegenerate(
        _ a: UInt32,
        _ b: UInt32,
        _ c: UInt32,
        vertices: [MeshVertex],
        twiceAreaEpsilon: Double
    ) -> Bool {
        guard a != b, b != c, c != a,
              Int(a) < vertices.count, Int(b) < vertices.count, Int(c) < vertices.count else { return true }
        let pa = vertices[Int(a)].position
        let pb = vertices[Int(b)].position
        let pc = vertices[Int(c)].position
        guard pa.allFinite, pb.allFinite, pc.allFinite else { return true }
        let twiceArea = DiagnosticMath.twiceArea(pa, pb, pc)
        return !twiceArea.isFinite || twiceArea <= twiceAreaEpsilon
    }
}

private struct DiagnosticUnionFind {
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

    mutating func union(_ first: Int, _ second: Int) {
        let a = find(first), b = find(second)
        guard a != b else { return }
        if ranks[a] < ranks[b] { parents[a] = b }
        else if ranks[a] > ranks[b] { parents[b] = a }
        else { parents[b] = a; ranks[a] &+= 1 }
    }
}

enum DiagnosticMath {
    static func double(_ value: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(value.x), Double(value.y), Double(value.z))
    }

    static func float(_ value: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(value.x), Float(value.y), Float(value.z))
    }

    static func twiceArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Double {
        let da = double(a), db = double(b), dc = double(c)
        return simd_length(simd_cross(db - da, dc - da))
    }
}
