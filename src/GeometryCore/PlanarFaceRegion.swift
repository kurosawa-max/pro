import Foundation
import simd

struct PlanarFaceRegionPoint2D: Equatable {
    var x: Double
    var y: Double

    static func +(lhs: Self, rhs: Self) -> Self { Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func -(lhs: Self, rhs: Self) -> Self { Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func *(lhs: Self, rhs: Double) -> Self { Self(x: lhs.x * rhs, y: lhs.y * rhs) }
}

struct PlanarFaceRegionBasis: Equatable {
    let u: SIMD3<Double>
    let v: SIMD3<Double>
    let normal: SIMD3<Double>
}

typealias FaceInsetPoint2D = PlanarFaceRegionPoint2D
typealias FaceInsetBasis = PlanarFaceRegionBasis

enum PlanarFaceRegionGeometry {
    static let maximumMiterRatio = 100.0
    static let maximumIntersectionPairChecks = 8_000_000

    static func deterministicBasis(normal: SIMD3<Double>) throws -> PlanarFaceRegionBasis {
        let length = simd_length(normal)
        guard length.isFinite, length > 1.0e-15 else { throw FaceInsetError.nonPlanarComponent }
        let n = normal / length
        let axes = [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)]
        let reference = axes.enumerated().min {
            let lhs = abs(simd_dot(n, $0.element))
            let rhs = abs(simd_dot(n, $1.element))
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }!.element
        let uValue = simd_cross(reference, n)
        let uLength = simd_length(uValue)
        guard uLength.isFinite, uLength > 1.0e-15 else { throw FaceInsetError.nonPlanarComponent }
        let u = uValue / uLength
        return PlanarFaceRegionBasis(u: u, v: simd_cross(n, u), normal: n)
    }

    static func insetPolygon(
        _ polygon: [PlanarFaceRegionPoint2D], distance: Double
    ) throws -> [PlanarFaceRegionPoint2D] {
        guard distance.isFinite, distance > 0, polygon.count >= 3 else { throw FaceInsetError.invalidDistance }
        let scale = polygonScale(polygon)
        let lengthEpsilon = max(scale * 1.0e-12, 1.0e-12)
        let areaEpsilon = max(scale * scale * 1.0e-12, 1.0e-18)
        try validateStrictlyConvexSimplePolygon(
            polygon, areaEpsilon: areaEpsilon, lengthEpsilon: lengthEpsilon)
        var directions: [PlanarFaceRegionPoint2D] = []
        var linePoints: [PlanarFaceRegionPoint2D] = []
        directions.reserveCapacity(polygon.count)
        linePoints.reserveCapacity(polygon.count)
        for index in polygon.indices {
            let edge = polygon[(index + 1) % polygon.count] - polygon[index]
            let length = hypot(edge.x, edge.y)
            guard length.isFinite, length > lengthEpsilon else { throw FaceInsetError.invalidBoundary }
            let direction = edge * (1 / length)
            directions.append(direction)
            linePoints.append(polygon[index] + PlanarFaceRegionPoint2D(
                x: -direction.y, y: direction.x) * distance)
        }
        var result: [PlanarFaceRegionPoint2D] = []
        result.reserveCapacity(polygon.count)
        for index in polygon.indices {
            let previous = (index + polygon.count - 1) % polygon.count
            let denominator = cross(directions[previous], directions[index])
            guard denominator.isFinite, abs(denominator) > 1.0e-12 else {
                throw FaceInsetError.collapsedInset
            }
            let t = cross(linePoints[index] - linePoints[previous], directions[index]) / denominator
            let point = linePoints[previous] + directions[previous] * t
            let miter = hypot(point.x - polygon[index].x, point.y - polygon[index].y) / distance
            guard point.x.isFinite, point.y.isFinite, miter.isFinite else {
                throw FaceInsetError.collapsedInset
            }
            guard miter <= maximumMiterRatio else { throw FaceInsetError.excessiveMiter }
            result.append(point)
        }
        try validateStrictlyConvexSimplePolygon(
            result, areaEpsilon: areaEpsilon, lengthEpsilon: lengthEpsilon)
        let sourceArea = signedArea(polygon)
        let resultArea = signedArea(result)
        guard resultArea > areaEpsilon, resultArea < sourceArea - areaEpsilon else {
            throw FaceInsetError.collapsedInset
        }
        for point in result where !isInsideConvexPolygon(
            point, polygon: polygon, epsilon: lengthEpsilon) {
            throw FaceInsetError.collapsedInset
        }
        return result
    }

    static func signedArea(_ polygon: [PlanarFaceRegionPoint2D]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        return polygon.indices.reduce(0) { partial, index in
            partial + cross(polygon[index], polygon[(index + 1) % polygon.count])
        } * 0.5
    }

    static func validateStrictlyConvexSimplePolygon(
        _ polygon: [PlanarFaceRegionPoint2D],
        areaEpsilon: Double? = nil,
        lengthEpsilon: Double? = nil
    ) throws {
        guard polygon.count >= 3,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw FaceInsetError.invalidBoundary
        }
        let scale = polygonScale(polygon)
        let lengthTolerance = lengthEpsilon ?? max(scale * 1.0e-12, 1.0e-12)
        let areaTolerance = areaEpsilon ?? max(scale * scale * 1.0e-12, 1.0e-18)
        guard signedArea(polygon) > areaTolerance else { throw FaceInsetError.nonConvexBoundary }
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let c = polygon[(index + 2) % polygon.count]
            guard hypot(b.x - a.x, b.y - a.y) > lengthTolerance,
                  cross(b - a, c - b) > areaTolerance else {
                throw FaceInsetError.nonConvexBoundary
            }
        }
        for first in polygon.indices {
            let firstNext = (first + 1) % polygon.count
            for second in polygon.indices where second > first {
                let secondNext = (second + 1) % polygon.count
                if first == second || firstNext == second || secondNext == first { continue }
                if segmentsIntersect(
                    polygon[first], polygon[firstNext], polygon[second], polygon[secondNext],
                    epsilon: areaTolerance) {
                    throw FaceInsetError.selfIntersectingBoundary
                }
            }
        }
    }

    static func validateInsetEdgeDistances(
        source: [PlanarFaceRegionPoint2D],
        inset: [PlanarFaceRegionPoint2D],
        distance: Double,
        tolerance: Double
    ) throws {
        guard source.count == inset.count, source.count >= 3,
              distance.isFinite, distance > 0, tolerance.isFinite, tolerance >= 0 else {
            throw FaceInsetError.validationFailed
        }
        for index in source.indices {
            let sourceEdge = source[(index + 1) % source.count] - source[index]
            let insetEdge = inset[(index + 1) % inset.count] - inset[index]
            let sourceLength = hypot(sourceEdge.x, sourceEdge.y)
            let insetLength = hypot(insetEdge.x, insetEdge.y)
            guard sourceLength.isFinite, insetLength.isFinite,
                  sourceLength > tolerance, insetLength > tolerance else {
                throw FaceInsetError.collapsedInset
            }
            let sourceDirection = sourceEdge * (1 / sourceLength)
            let insetDirection = insetEdge * (1 / insetLength)
            let parallelError = abs(cross(sourceDirection, insetDirection))
            let perpendicularDistance = cross(sourceDirection, inset[index] - source[index])
            let angularTolerance = min(
                0.01, tolerance / max(max(sourceLength, insetLength), 1.0e-12))
            guard parallelError <= angularTolerance,
                  abs(perpendicularDistance - distance) <= tolerance else {
                throw FaceInsetError.collapsedInset
            }
        }
    }

    static func validateInnerTriangulation(
        triangles: [[UInt32]],
        pointsByVertex: [UInt32: PlanarFaceRegionPoint2D],
        areaEpsilon: Double
    ) throws {
        guard areaEpsilon.isFinite, areaEpsilon >= 0 else { throw FaceInsetError.validationFailed }
        try validatePairBudget(triangles.count)
        var uniqueEdges: Set<DiagnosticEdgeKey> = []
        uniqueEdges.reserveCapacity(try checkedMultiply(triangles.count, 2))
        for triangle in triangles {
            guard triangle.count == 3, Set(triangle).count == 3,
                  let a = pointsByVertex[triangle[0]],
                  let b = pointsByVertex[triangle[1]],
                  let c = pointsByVertex[triangle[2]],
                  cross(b - a, c - a) > areaEpsilon else {
                throw FaceInsetError.collapsedInset
            }
            uniqueEdges.insert(DiagnosticEdgeKey(triangle[0], triangle[1]))
            uniqueEdges.insert(DiagnosticEdgeKey(triangle[1], triangle[2]))
            uniqueEdges.insert(DiagnosticEdgeKey(triangle[2], triangle[0]))
        }
        let edges = uniqueEdges.sorted {
            $0.low == $1.low ? $0.high < $1.high : $0.low < $1.low
        }
        try validatePairBudget(edges.count)
        for firstIndex in edges.indices {
            let first = edges[firstIndex]
            guard let a = pointsByVertex[first.low], let b = pointsByVertex[first.high] else {
                throw FaceInsetError.validationFailed
            }
            for secondIndex in edges.indices where secondIndex > firstIndex {
                let second = edges[secondIndex]
                guard let c = pointsByVertex[second.low], let d = pointsByVertex[second.high] else {
                    throw FaceInsetError.validationFailed
                }
                let shared: UInt32? = first.low == second.low || first.low == second.high
                    ? first.low
                    : (first.high == second.low || first.high == second.high ? first.high : nil)
                if segmentsHaveInvalidIntersection(
                    a: a, aID: first.low, b: b, bID: first.high,
                    c: c, cID: second.low, d: d, dID: second.high,
                    sharedVertexID: shared, epsilon: areaEpsilon) {
                    throw FaceInsetError.innerTriangulationIntersection
                }
            }
        }
        for firstIndex in triangles.indices {
            let first = triangles[firstIndex]
            for secondIndex in triangles.indices where secondIndex > firstIndex {
                let second = triangles[secondIndex]
                let shared = Set(first).intersection(Set(second))
                if shared.count == 3 { throw FaceInsetError.innerTriangulationIntersection }
                if shared.count == 2 {
                    let edge = shared.sorted()
                    guard let a = pointsByVertex[edge[0]], let b = pointsByVertex[edge[1]],
                          let firstThird = first.first(where: { !shared.contains($0) })
                            .flatMap({ pointsByVertex[$0] }),
                          let secondThird = second.first(where: { !shared.contains($0) })
                            .flatMap({ pointsByVertex[$0] }) else {
                        throw FaceInsetError.validationFailed
                    }
                    let firstSide = cross(b - a, firstThird - a)
                    let secondSide = cross(b - a, secondThird - a)
                    guard abs(firstSide) > areaEpsilon, abs(secondSide) > areaEpsilon,
                          (firstSide > 0) != (secondSide > 0) else {
                        throw FaceInsetError.innerTriangulationIntersection
                    }
                    continue
                }
                for vertexID in first where !shared.contains(vertexID) {
                    guard let point = pointsByVertex[vertexID] else {
                        throw FaceInsetError.validationFailed
                    }
                    if isStrictlyInside(
                        point, triangle: second, pointsByVertex: pointsByVertex,
                        epsilon: areaEpsilon) {
                        throw FaceInsetError.innerTriangulationIntersection
                    }
                }
                for vertexID in second where !shared.contains(vertexID) {
                    guard let point = pointsByVertex[vertexID] else {
                        throw FaceInsetError.validationFailed
                    }
                    if isStrictlyInside(
                        point, triangle: first, pointsByVertex: pointsByVertex,
                        epsilon: areaEpsilon) {
                        throw FaceInsetError.innerTriangulationIntersection
                    }
                }
            }
        }
    }

    static func isInsideConvexPolygon(
        _ point: PlanarFaceRegionPoint2D,
        polygon: [PlanarFaceRegionPoint2D],
        epsilon: Double
    ) -> Bool {
        polygon.indices.allSatisfy { index in
            cross(polygon[(index + 1) % polygon.count] - polygon[index], point - polygon[index]) >= -epsilon
        }
    }

    static func cross(
        _ lhs: PlanarFaceRegionPoint2D, _ rhs: PlanarFaceRegionPoint2D
    ) -> Double {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    static func worldPosition(
        _ local: SIMD3<Float>, matrix: simd_float4x4
    ) throws -> SIMD3<Double> {
        let value = matrix * SIMD4<Float>(local, 1)
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite,
              abs(value.w) > 0.000_001 else { throw FaceInsetError.invalidTransform }
        let point = SIMD3<Double>(
            Double(value.x / value.w), Double(value.y / value.w), Double(value.z / value.w))
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
            throw FaceInsetError.nonFiniteValue
        }
        return point
    }

    static func localPosition(
        _ world: SIMD3<Double>, matrix: simd_float4x4
    ) throws -> SIMD3<Float> {
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
              abs(world.x) <= Double(Float.greatestFiniteMagnitude),
              abs(world.y) <= Double(Float.greatestFiniteMagnitude),
              abs(world.z) <= Double(Float.greatestFiniteMagnitude) else {
            throw FaceInsetError.inverseTransformFailure
        }
        let value = matrix * SIMD4<Float>(Float(world.x), Float(world.y), Float(world.z), 1)
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite,
              abs(value.w) > 0.000_001 else { throw FaceInsetError.inverseTransformFailure }
        let result = SIMD3<Float>(value.x, value.y, value.z) / value.w
        guard result.allFinite else { throw FaceInsetError.inverseTransformFailure }
        return result
    }

    static func finiteFloatPosition(_ value: SIMD3<Double>) throws -> SIMD3<Float> {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              abs(value.x) <= Double(Float.greatestFiniteMagnitude),
              abs(value.y) <= Double(Float.greatestFiniteMagnitude),
              abs(value.z) <= Double(Float.greatestFiniteMagnitude) else {
            throw FaceInsetError.nonFiniteValue
        }
        return SIMD3<Float>(Float(value.x), Float(value.y), Float(value.z))
    }

    static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
        }
    }

    private static func validatePairBudget(_ count: Int) throws {
        guard count >= 0 else { throw FaceInsetError.arithmeticOverflow }
        let pairs = try checkedMultiply(count, max(0, count - 1)) / 2
        guard pairs <= maximumIntersectionPairChecks else {
            throw FaceInsetError.innerTriangulationLimitExceeded
        }
    }

    private static func segmentsHaveInvalidIntersection(
        a: PlanarFaceRegionPoint2D, aID: UInt32,
        b: PlanarFaceRegionPoint2D, bID: UInt32,
        c: PlanarFaceRegionPoint2D, cID: UInt32,
        d: PlanarFaceRegionPoint2D, dID: UInt32,
        sharedVertexID: UInt32?, epsilon: Double
    ) -> Bool {
        guard segmentsIntersect(a, b, c, d, epsilon: epsilon) else { return false }
        guard let sharedVertexID else { return true }
        let firstOther = aID == sharedVertexID ? b : a
        let secondOther = cID == sharedVertexID ? d : c
        return pointOnSegment(firstOther, c, d, epsilon: epsilon)
            || pointOnSegment(secondOther, a, b, epsilon: epsilon)
    }

    private static func segmentsIntersect(
        _ a: PlanarFaceRegionPoint2D, _ b: PlanarFaceRegionPoint2D,
        _ c: PlanarFaceRegionPoint2D, _ d: PlanarFaceRegionPoint2D,
        epsilon: Double
    ) -> Bool {
        let ab = b - a, cd = d - c
        let first = cross(ab, c - a), second = cross(ab, d - a)
        let third = cross(cd, a - c), fourth = cross(cd, b - c)
        if ((first > epsilon && second < -epsilon) || (first < -epsilon && second > epsilon)),
           ((third > epsilon && fourth < -epsilon) || (third < -epsilon && fourth > epsilon)) {
            return true
        }
        return (abs(first) <= epsilon && pointOnSegment(c, a, b, epsilon: epsilon))
            || (abs(second) <= epsilon && pointOnSegment(d, a, b, epsilon: epsilon))
            || (abs(third) <= epsilon && pointOnSegment(a, c, d, epsilon: epsilon))
            || (abs(fourth) <= epsilon && pointOnSegment(b, c, d, epsilon: epsilon))
    }

    private static func pointOnSegment(
        _ point: PlanarFaceRegionPoint2D,
        _ a: PlanarFaceRegionPoint2D,
        _ b: PlanarFaceRegionPoint2D,
        epsilon: Double
    ) -> Bool {
        let coordinateTolerance = sqrt(max(epsilon, 0))
        return abs(cross(b - a, point - a)) <= epsilon
            && point.x >= min(a.x, b.x) - coordinateTolerance
            && point.x <= max(a.x, b.x) + coordinateTolerance
            && point.y >= min(a.y, b.y) - coordinateTolerance
            && point.y <= max(a.y, b.y) + coordinateTolerance
    }

    private static func isStrictlyInside(
        _ point: PlanarFaceRegionPoint2D,
        triangle: [UInt32],
        pointsByVertex: [UInt32: PlanarFaceRegionPoint2D],
        epsilon: Double
    ) -> Bool {
        guard triangle.count == 3,
              let a = pointsByVertex[triangle[0]],
              let b = pointsByVertex[triangle[1]],
              let c = pointsByVertex[triangle[2]] else { return false }
        return cross(b - a, point - a) > epsilon
            && cross(c - b, point - b) > epsilon
            && cross(a - c, point - c) > epsilon
    }

    private static func polygonScale(_ polygon: [PlanarFaceRegionPoint2D]) -> Double {
        guard let first = polygon.first else { return 0 }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in polygon.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return max(hypot(maxX - minX, maxY - minY), 1.0e-12)
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw FaceInsetError.arithmeticOverflow }
        return result
    }
}

enum PlanarFaceRegionAnalyzer {
    static func analyze(
        mesh: EditableMesh,
        selection: FaceSelection,
        transform: ObjectTransform,
        widthMillimeters: Double
    ) throws -> FaceInset.Plan {
        try FaceInset.makePlan(
            mesh: mesh,
            selection: selection,
            transform: transform,
            options: FaceInsetOptions(distanceMillimeters: widthMillimeters))
    }
}

private struct PlanarFaceRegionVertexKey: Hashable {
    let componentID: Int
    let originalVertexID: UInt32
}

enum PlanarFaceRegionMeshBuilder {
    static func build(
        source mesh: EditableMesh,
        analysis: FaceInset.Plan,
        innerLocalPositions: [[SIMD3<Float>]]
    ) throws -> EditableMesh {
        guard innerLocalPositions.count == analysis.components.count else {
            throw FaceInsetError.validationFailed
        }
        var originalRemap = Array<UInt32?>(repeating: nil, count: mesh.vertices.count)
        var resultVertices: [MeshVertex] = []
        resultVertices.reserveCapacity(analysis.estimate.resultingVertexCount)
        for vertexID in mesh.vertices.indices where analysis.referencedOriginalVertices[vertexID] {
            guard resultVertices.count < Int(UInt32.max) else { throw FaceInsetError.indexOverflow }
            originalRemap[vertexID] = UInt32(resultVertices.count)
            resultVertices.append(mesh.vertices[vertexID])
        }

        var innerRemap: [PlanarFaceRegionVertexKey: UInt32] = [:]
        innerRemap.reserveCapacity(analysis.estimate.addedInsetVertexCount)
        for component in analysis.components {
            let positions = innerLocalPositions[component.id]
            guard positions.count == component.originalVertexIDs.count else {
                throw FaceInsetError.validationFailed
            }
            for (offset, vertexID) in component.originalVertexIDs.enumerated() {
                guard resultVertices.count < Int(UInt32.max) else { throw FaceInsetError.indexOverflow }
                innerRemap[PlanarFaceRegionVertexKey(
                    componentID: component.id,
                    originalVertexID: vertexID)] = UInt32(resultVertices.count)
                resultVertices.append(MeshVertex(position: positions[offset], normal: .zero))
            }
        }

        var resultIndices: [UInt32] = []
        resultIndices.reserveCapacity(try checkedMultiply(analysis.estimate.resultingTriangleCount, 3))
        for faceID in 0..<analysis.originalTriangleCount where !analysis.selectedFaces[faceID] {
            for vertexID in try triangleIndices(faceID: faceID, mesh: mesh) {
                guard let mapped = originalRemap[Int(vertexID)] else {
                    throw FaceInsetError.validationFailed
                }
                resultIndices.append(mapped)
            }
        }
        for component in analysis.components {
            let loop = component.boundaryVertexIDs
            for index in loop.indices {
                let a = loop[index]
                let b = loop[(index + 1) % loop.count]
                guard let outerA = originalRemap[Int(a)],
                      let outerB = originalRemap[Int(b)],
                      let innerA = innerRemap[PlanarFaceRegionVertexKey(
                        componentID: component.id, originalVertexID: a)],
                      let innerB = innerRemap[PlanarFaceRegionVertexKey(
                        componentID: component.id, originalVertexID: b)] else {
                    throw FaceInsetError.validationFailed
                }
                resultIndices.append(contentsOf: [
                    outerA, outerB, innerB,
                    outerA, innerB, innerA
                ])
            }
        }
        for faceID in analysis.selectedFaceIDs {
            guard let componentID = analysis.componentByFace[faceID] else {
                throw FaceInsetError.validationFailed
            }
            for vertexID in try triangleIndices(faceID: faceID, mesh: mesh) {
                guard let mapped = innerRemap[PlanarFaceRegionVertexKey(
                    componentID: componentID, originalVertexID: vertexID)] else {
                    throw FaceInsetError.validationFailed
                }
                resultIndices.append(mapped)
            }
        }
        let expectedIndexCount = try checkedMultiply(analysis.estimate.resultingTriangleCount, 3)
        guard resultVertices.count == analysis.estimate.resultingVertexCount,
              resultIndices.count == expectedIndexCount else {
            throw FaceInsetError.validationFailed
        }
        var result = EditableMesh(vertices: resultVertices, indices: resultIndices)
        result.recalculateNormals(recordChange: false)
        _ = result.adjacency()
        _ = try result.validated(
            maxVertices: FaceInset.maximumVertices,
            maxIndices: FaceInset.maximumTriangles * 3)
        return result
    }

    private static func triangleIndices(faceID: Int, mesh: EditableMesh) throws -> [UInt32] {
        let (offset, overflow) = faceID.multipliedReportingOverflow(by: 3)
        let (last, lastOverflow) = offset.addingReportingOverflow(2)
        guard faceID >= 0, !overflow, !lastOverflow, last < mesh.indices.count else {
            throw FaceInsetError.invalidMesh
        }
        let triangle = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
        guard triangle.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw FaceInsetError.invalidMesh
        }
        return triangle
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw FaceInsetError.arithmeticOverflow }
        return result
    }
}

enum PlanarFaceRegionMeshValidator {
    static func validate(
        mesh: EditableMesh,
        expectedVertexCount: Int,
        expectedTriangleCount: Int,
        expectedLocalBounds: AxisAlignedBoundingBox,
        sourceBoundaryEdgeCount: Int,
        sourceNonManifoldEdgeCount: Int,
        sourceWindingConflictCount: Int
    ) throws {
        guard mesh.vertices.count == expectedVertexCount,
              mesh.indices.count / 3 == expectedTriangleCount,
              mesh.bounds == expectedLocalBounds else {
            throw FaceInsetError.validationFailed
        }
        let topology = MeshTopologyDiagnostics.analyze(mesh)
        guard !topology.hasInvalidStructure,
              topology.invalidIndexTriangleCount == 0,
              topology.nonFiniteVertexCount == 0,
              topology.degenerateTriangleCount == 0,
              topology.duplicateTriangleCount == 0,
              topology.boundaryEdgeCount == sourceBoundaryEdgeCount,
              topology.nonManifoldEdgeCount == sourceNonManifoldEdgeCount,
              topology.inconsistentWindingEdgeCount == sourceWindingConflictCount,
              mesh.vertices.allSatisfy({ vertex in
                  let length = simd_length(vertex.normal)
                  return vertex.position.allFinite && vertex.normal.allFinite
                      && length.isFinite && abs(length - 1) <= 0.000_1
              }) else {
            throw FaceInsetError.validationFailed
        }
    }
}
