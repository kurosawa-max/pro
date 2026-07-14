import simd

enum BrushKind: String, Codable, CaseIterable { case draw = "Draw", smooth = "Smooth", grab = "Grab", flatten = "Flatten", crease = "Crease" }

struct BrushSettings { var radius: Float = 0.28; var strength: Float = 0.12 }

struct SculptSymmetry: Codable, Equatable {
    var x = false, y = false, z = false
    static let none = SculptSymmetry()
}

struct FlattenPlane: Equatable {
    var origin: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct SymmetrySample: Equatable {
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
    let drag: SIMD3<Float>
    let mask: Int
}

enum SculptSymmetryGeometry {
    static let epsilon: Float = 0.000_01

    static func centers(_ point: SIMD3<Float>, symmetry: SculptSymmetry) -> [SIMD3<Float>] {
        guard point.allFinite else { return [] }
        return samples(center: point, normal: SIMD3<Float>(0, 1, 0), drag: .zero, symmetry: symmetry).map(\.center)
    }

    static func samples(center: SIMD3<Float>, normal: SIMD3<Float>, drag: SIMD3<Float>,
                        symmetry: SculptSymmetry) -> [SymmetrySample] {
        guard center.allFinite, normal.allFinite, drag.allFinite else { return [] }
        var masks = [0]
        if symmetry.x { let current = masks; masks += current.map { $0 | 1 } }
        if symmetry.y { let current = masks; masks += current.map { $0 | 2 } }
        if symmetry.z { let current = masks; masks += current.map { $0 | 4 } }
        var result: [SymmetrySample] = []
        for mask in masks {
            let mirroredCenter = mirrored(center, mask: mask)
            guard !result.contains(where: { simd_distance_squared($0.center, mirroredCenter) <= epsilon * epsilon }) else { continue }
            result.append(SymmetrySample(center: mirroredCenter,
                                         normal: normalized(mirrored(normal, mask: mask)),
                                         drag: mirrored(drag, mask: mask), mask: mask))
        }
        return result
    }

    static func mirrored(_ value: SIMD3<Float>, mask: Int) -> SIMD3<Float> {
        var result = value
        if mask & 1 != 0 { result.x = -result.x }
        if mask & 2 != 0 { result.y = -result.y }
        if mask & 4 != 0 { result.z = -result.z }
        return result
    }

    private static func normalized(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        return length.isFinite && length > 0.000_001 ? value / length : .zero
    }
}

enum SculptBrush {
    private static let creasePinchRatio: Float = 0.7
    private static let creaseIndentRatio: Float = 0.3

    static func apply(kind: BrushKind, center: SIMD3<Float>, normal: SIMD3<Float>, drag: SIMD3<Float>,
                      pressure: Float, settings: BrushSettings, mesh: inout EditableMesh,
                      profiler: PerformanceProfiler? = nil, symmetry: SculptSymmetry = .none,
                      flattenPlane: FlattenPlane? = nil, spatialIndex: VertexSpatialIndex? = nil) -> [VertexMutation] {
        PerformanceProfiler.measure(profiler, metric: .sculpt) {
            applyUnmeasured(kind: kind, center: center, normal: normal, drag: drag, pressure: pressure,
                            settings: settings, mesh: &mesh, profiler: profiler, symmetry: symmetry,
                            flattenPlane: flattenPlane, spatialIndex: spatialIndex)
        }
    }

    private static func applyUnmeasured(kind: BrushKind, center: SIMD3<Float>, normal: SIMD3<Float>,
                                        drag: SIMD3<Float>, pressure: Float, settings: BrushSettings,
                                        mesh: inout EditableMesh, profiler: PerformanceProfiler?,
                                        symmetry: SculptSymmetry, flattenPlane: FlattenPlane?,
                                        spatialIndex: VertexSpatialIndex?) -> [VertexMutation] {
        guard center.allFinite, normal.allFinite, drag.allFinite else { return [] }
        let normalLength = simd_length(normal)
        guard normalLength.isFinite, normalLength > 0.000_001 else { return [] }
        let radius = max(settings.radius, 0.000_1)
        let safePressure = min(max(pressure, 0), 1), safeStrength = min(max(settings.strength, 0), 1)
        guard safePressure > 0, safeStrength > 0 else { return [] }
        let samples = SculptSymmetryGeometry.samples(center: center, normal: normal / normalLength,
                                                       drag: drag, symmetry: symmetry)
        guard !samples.isEmpty else { return [] }
        let neighbors = kind == .smooth ? mesh.adjacency() : []
        var candidateIDs = Set<Int>()
        for sample in samples {
            if let spatialIndex { candidateIDs.formUnion(spatialIndex.candidates(center: sample.center, radius: radius, mesh: mesh)) }
            else { candidateIDs.formUnion(mesh.vertices.indices) }
        }
        var updates: [Int: SIMD3<Float>] = [:]
        updates.reserveCapacity(candidateIDs.count)
        for index in candidateIDs.sorted() {
            let current = mesh.vertices[index].position
            var best: SIMD3<Float>?, bestMagnitude: Float = -1
            for sample in samples {
                let distance = simd_distance(current, sample.center)
                guard distance.isFinite, distance < radius else { continue }
                let t = 1 - distance / radius
                let falloff = t * t * (3 - 2 * t), weight = safeStrength * safePressure * falloff
                let delta: SIMD3<Float>
                switch kind {
                case .draw:
                    delta = sample.normal * weight * radius * 0.25
                case .grab:
                    delta = limited(sample.drag * falloff * safePressure * safeStrength, maximum: radius * 0.25)
                case .smooth:
                    let linked = neighbors[index]
                    guard !linked.isEmpty else { continue }
                    let average = linked.reduce(SIMD3<Float>.zero) { $0 + mesh.vertices[$1].position } / Float(linked.count)
                    delta = limited((average - current) * weight, maximum: radius * 0.05)
                case .flatten:
                    guard let plane = mirroredPlane(flattenPlane, mask: sample.mask) else { continue }
                    let signedDistance = simd_dot(current - plane.origin, plane.normal)
                    delta = limited(-plane.normal * signedDistance * weight, maximum: radius * 0.1)
                case .crease:
                    let toCenter = sample.center - current
                    let tangent = toCenter - sample.normal * simd_dot(toCenter, sample.normal)
                    let combined = tangent * creasePinchRatio - sample.normal * radius * creaseIndentRatio
                    delta = limited(combined * weight, maximum: radius * 0.1)
                }
                let magnitude = simd_length_squared(delta)
                if delta.allFinite, magnitude > bestMagnitude { best = current + delta; bestMagnitude = magnitude }
            }
            if let best, best.allFinite, best != current { updates[index] = best }
        }
        let mutations = mesh.updatePositions(updates, profiler: profiler)
        spatialIndex?.didUpdate(mutations, mesh: mesh)
        return mutations
    }

    private static func mirroredPlane(_ plane: FlattenPlane?, mask: Int) -> FlattenPlane? {
        guard let plane, plane.origin.allFinite, plane.normal.allFinite else { return nil }
        let normal = SculptSymmetryGeometry.mirrored(plane.normal, mask: mask)
        let length = simd_length(normal)
        guard length.isFinite, length > 0.000_001 else { return nil }
        return FlattenPlane(origin: SculptSymmetryGeometry.mirrored(plane.origin, mask: mask), normal: normal / length)
    }

    private static func limited(_ value: SIMD3<Float>, maximum: Float) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length.isFinite, length > maximum, length > 0 else { return value }
        return value * (maximum / length)
    }
}
