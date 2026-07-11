import simd

enum BrushKind: String, Codable, CaseIterable { case draw = "Draw", smooth = "Smooth", grab = "Grab" }

struct BrushSettings {
    var radius: Float = 0.28
    var strength: Float = 0.12
}

enum SculptBrush {
    static func apply(
        kind: BrushKind,
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        drag: SIMD3<Float>,
        pressure: Float,
        settings: BrushSettings,
        mesh: inout EditableMesh
    ) -> [VertexMutation] {
        guard center.allFinite, normal.allFinite, drag.allFinite else { return [] }
        let radius = max(settings.radius, 0.000_1)
        let safePressure = min(max(pressure, 0), 1)
        let safeStrength = min(max(settings.strength, 0), 1)
        guard safePressure > 0, safeStrength > 0 else { return [] }

        let neighbors = kind == .smooth ? mesh.adjacency() : []
        var updates: [Int: SIMD3<Float>] = [:]
        for index in mesh.vertices.indices {
            let current = mesh.vertices[index].position
            let distance = simd_distance(current, center)
            guard distance.isFinite, distance < radius else { continue }
            let normalizedDistance = 1 - distance / radius
            let falloff = normalizedDistance * normalizedDistance * (3 - 2 * normalizedDistance)
            let amount = safeStrength * safePressure * falloff
            let candidate: SIMD3<Float>

            switch kind {
            case .draw:
                candidate = current + normal * amount * radius * 0.25
            case .grab:
                candidate = current + limited(drag * falloff * safePressure, maximum: radius * 0.25)
            case .smooth:
                let linked = neighbors[index]
                guard !linked.isEmpty else { continue }
                let average = linked.reduce(SIMD3<Float>.zero) { $0 + mesh.vertices[$1].position } / Float(linked.count)
                let displacement = limited((average - current) * amount, maximum: radius * 0.05)
                candidate = current + displacement
            }

            if candidate.allFinite { updates[index] = candidate }
        }
        return mesh.updatePositions(updates)
    }

    private static func limited(_ value: SIMD3<Float>, maximum: Float) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length.isFinite, length > maximum, length > 0 else { return value }
        return value * (maximum / length)
    }
}
