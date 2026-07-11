enum BenchmarkFeature {
    static var isCompiled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

#if DEBUG
enum BenchmarkPreset: String, CaseIterable, Hashable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var subdivisions: Int {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 5
        }
    }

    func makeMesh() -> EditableMesh {
        EditableMesh.icosphere(subdivisions: subdivisions)
    }

    var expectedVertexCount: Int {
        10 * integerPower(4, subdivisions) + 2
    }

    var expectedTriangleCount: Int {
        20 * integerPower(4, subdivisions)
    }

    private func integerPower(_ base: Int, _ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * base }
    }
}
#endif
