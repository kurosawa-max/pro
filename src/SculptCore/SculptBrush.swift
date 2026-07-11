import simd

enum BrushKind: String, Codable, CaseIterable { case draw = "Draw", smooth = "Smooth", grab = "Grab" }
struct BrushSettings { var radius: Float = 0.28; var strength: Float = 0.12 }

enum SculptBrush {
    static func apply(kind: BrushKind, center: SIMD3<Float>, normal: SIMD3<Float>, drag: SIMD3<Float>, pressure: Float,
                      settings: BrushSettings, mesh: inout EditableMesh) -> StrokeCommand {
        let before = mesh.vertices.map(\.position)
        let neighbors = adjacency(mesh: mesh)
        let safePressure = min(max(pressure, 0), 1)
        for index in mesh.vertices.indices {
            let distance = simd_distance(mesh.vertices[index].position, center)
            guard distance < settings.radius else { continue }
            let t = 1 - distance / settings.radius
            let falloff = t * t * (3 - 2 * t)
            let amount = settings.strength * safePressure * falloff
            switch kind {
            case .draw: mesh.vertices[index].position += normal * amount
            case .grab: mesh.vertices[index].position += drag * falloff * safePressure
            case .smooth:
                let linked = neighbors[index]
                guard !linked.isEmpty else { continue }
                let average = linked.reduce(SIMD3<Float>.zero) { $0 + before[$1] } / Float(linked.count)
                mesh.vertices[index].position += (average - before[index]) * amount
            }
        }
        mesh.recalculateNormals()
        let changes = mesh.vertices.indices.compactMap { i in
            before[i] == mesh.vertices[i].position ? nil : VertexChange(index: i, before: before[i], after: mesh.vertices[i].position)
        }
        return StrokeCommand(changes: changes)
    }

    private static func adjacency(mesh: EditableMesh) -> [[Int]] {
        var result = Array(repeating: Set<Int>(), count: mesh.vertices.count)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            result[a].formUnion([b, c]); result[b].formUnion([a, c]); result[c].formUnion([a, b])
        }
        return result.map(Array.init)
    }
}

