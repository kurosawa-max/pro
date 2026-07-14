import Foundation

enum AutomatedBenchmarkFeature {
    static var isCompiled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

#if DEBUG
import simd

struct BenchmarkRunConfiguration: Codable, Equatable {
    static let standard = BenchmarkRunConfiguration(warmUpIterations: 10, measuredIterations: 60)
    let warmUpIterations: Int
    let measuredIterations: Int
}

enum BenchmarkCase: String, CaseIterable, Codable {
    case picking = "Picking"
    case draw = "Draw brush"
    case smooth = "Smooth brush"
    case grab = "Grab brush"
    case flatten = "Flatten brush"
    case crease = "Crease brush"
    case drawSymmetryX = "Draw brush X symmetry"
    case drawSymmetryXYZ = "Draw brush XYZ symmetry"
    case creaseSymmetryXYZ = "Crease brush XYZ symmetry"
    case normalRebuild = "Normal rebuild"
    case vertexUpload = "Vertex buffer upload"
    case indexUpload = "Index buffer upload"

    var metric: PerformanceMetric {
        switch self {
        case .picking: .picking
        case .draw, .smooth, .grab, .flatten, .crease, .drawSymmetryX, .drawSymmetryXYZ, .creaseSymmetryXYZ: .sculpt
        case .normalRebuild: .normalRebuild
        case .vertexUpload: .vertexUpload
        case .indexUpload: .indexUpload
        }
    }
}

struct BenchmarkCaseResult: Codable, Equatable {
    let caseName: String
    let sampleCount: Int
    let latestMilliseconds: Double
    let averageMilliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double
}

struct BenchmarkPresetResult: Codable, Equatable {
    let presetName: String
    let vertexCount: Int
    let triangleCount: Int
    let cases: [BenchmarkCaseResult]
}

struct BenchmarkReport: Codable, Equatable {
    let executedAt: Date
    let environment: String
    let buildConfiguration: String
    let configuration: BenchmarkRunConfiguration
    let presets: [BenchmarkPresetResult]

    var plainText: String {
        var lines = [
            "Forge3D Automated Performance Benchmark",
            "Executed: \(ISO8601DateFormatter().string(from: executedAt))",
            "Environment: \(environment)", "Build: \(buildConfiguration)",
            "Warm-up: \(configuration.warmUpIterations)", "Samples: \(configuration.measuredIterations)"
        ]
        for preset in presets {
            lines.append("\n\(preset.presetName): \(preset.vertexCount) vertices, \(preset.triangleCount) triangles")
            for item in preset.cases {
                lines.append(String(format: "%@: n=%d latest=%.4f ms avg=%.4f ms min=%.4f ms max=%.4f ms", item.caseName, item.sampleCount, item.latestMilliseconds, item.averageMilliseconds, item.minimumMilliseconds, item.maximumMilliseconds))
            }
        }
        return lines.joined(separator: "\n")
    }

    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}

@MainActor
final class BenchmarkRunner {
    static let uploadAcknowledgementPoll = Duration.milliseconds(5)
    static let uploadAcknowledgementTimeout = Duration.milliseconds(500)
    static let fixedRay = Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1))
    static let center = SIMD3<Float>(0, 0, 1)
    static let normal = SIMD3<Float>(0, 0, 1)
    static let drag = SIMD3<Float>(0.015, 0, 0)
    static let pressure: Float = 0.75
    static let settings = BrushSettings(radius: 0.28, strength: 0.12)

    private(set) var isCancelled = false
    func cancel() { isCancelled = true }

    func run(
        profiler: PerformanceProfiler,
        configuration: BenchmarkRunConfiguration = .standard,
        progress: @escaping (Int, Int) -> Void,
        installMesh: @escaping (EditableMesh) -> Void
    ) async -> BenchmarkReport? {
        let total = BenchmarkPreset.allCases.count * BenchmarkCase.allCases.count
        var completed = 0, presetResults: [BenchmarkPresetResult] = []
        for preset in BenchmarkPreset.allCases {
            let base = preset.makeMesh()
            var results: [BenchmarkCaseResult] = []
            for benchmarkCase in BenchmarkCase.allCases {
                let pickingCache = MeshBVHCache()
                let spatialIndex = VertexSpatialIndex()
                if isCancelled || Task.isCancelled { return nil }
                profiler.reset(benchmarkCase.metric)
                var mesh = base
                for iteration in 0..<(configuration.warmUpIterations + configuration.measuredIterations) {
                    if isCancelled || Task.isCancelled { return nil }
                    if iteration == configuration.warmUpIterations { profiler.reset(benchmarkCase.metric) }
                    guard await execute(benchmarkCase, preset: preset, mesh: &mesh, pickingCache: pickingCache,
                                        spatialIndex: spatialIndex,
                                        profiler: profiler, installMesh: installMesh) else { return nil }
                    await Task.yield()
                }
                let sample = profiler.snapshot()[benchmarkCase.metric]
                results.append(BenchmarkCaseResult(caseName: benchmarkCase.rawValue, sampleCount: sample.sampleCount,
                    latestMilliseconds: sample.latestMilliseconds, averageMilliseconds: sample.averageMilliseconds,
                    minimumMilliseconds: sample.minimumMilliseconds, maximumMilliseconds: sample.maximumMilliseconds))
                completed += 1; progress(completed, total); await Task.yield()
            }
            presetResults.append(BenchmarkPresetResult(presetName: preset.rawValue, vertexCount: base.vertices.count,
                triangleCount: base.indices.count / 3, cases: results))
        }
        return BenchmarkReport(executedAt: Date(), environment: Self.environment,
            buildConfiguration: "Debug", configuration: configuration, presets: presetResults)
    }

    private func execute(_ item: BenchmarkCase, preset: BenchmarkPreset, mesh: inout EditableMesh, pickingCache: MeshBVHCache,
                         spatialIndex: VertexSpatialIndex,
                         profiler: PerformanceProfiler, installMesh: (EditableMesh) -> Void) async -> Bool {
        switch item {
        case .picking: _ = MeshPicker.hit(ray: Self.fixedRay, mesh: mesh, profiler: profiler, cache: pickingCache)
        case .draw: _ = SculptBrush.apply(kind: .draw, center: Self.center, normal: Self.normal, drag: Self.drag, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, spatialIndex: spatialIndex)
        case .smooth: _ = SculptBrush.apply(kind: .smooth, center: Self.center, normal: Self.normal, drag: Self.drag, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, spatialIndex: spatialIndex)
        case .grab: _ = SculptBrush.apply(kind: .grab, center: Self.center, normal: Self.normal, drag: Self.drag, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, spatialIndex: spatialIndex)
        case .flatten: _ = SculptBrush.apply(kind: .flatten, center: Self.center, normal: Self.normal, drag: .zero, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, flattenPlane: FlattenPlane(origin: Self.center, normal: Self.normal), spatialIndex: spatialIndex)
        case .crease: _ = SculptBrush.apply(kind: .crease, center: Self.center, normal: Self.normal, drag: .zero, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, spatialIndex: spatialIndex)
        case .drawSymmetryX: _ = SculptBrush.apply(kind: .draw, center: Self.center, normal: Self.normal, drag: .zero, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, symmetry: SculptSymmetry(x: true), spatialIndex: spatialIndex)
        case .drawSymmetryXYZ: _ = SculptBrush.apply(kind: .draw, center: Self.center, normal: Self.normal, drag: .zero, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, symmetry: SculptSymmetry(x: true, y: true, z: true), spatialIndex: spatialIndex)
        case .creaseSymmetryXYZ: _ = SculptBrush.apply(kind: .crease, center: Self.center, normal: Self.normal, drag: .zero, pressure: Self.pressure, settings: Self.settings, mesh: &mesh, profiler: profiler, symmetry: SculptSymmetry(x: true, y: true, z: true), spatialIndex: spatialIndex)
        case .normalRebuild: mesh.recalculateNormals(profiler: profiler)
        case .vertexUpload:
            let before = profiler.sampleCount(for: .vertexUpload)
            _ = mesh.updatePositions([0: mesh.vertices[0].position + SIMD3<Float>(0.000_001, 0, 0)], profiler: nil)
            installMesh(mesh)
            return await waitForSample(.vertexUpload, after: before, profiler: profiler)
        case .indexUpload:
            let before = profiler.sampleCount(for: .indexUpload)
            mesh = Self.makeIndexUploadMesh(for: preset)
            installMesh(mesh)
            return await waitForSample(.indexUpload, after: before, profiler: profiler)
        }
        return true
    }

    static func makeIndexUploadMesh(for preset: BenchmarkPreset) -> EditableMesh {
        preset.makeMesh()
    }

    private func waitForSample(_ metric: PerformanceMetric, after previousCount: Int,
                               profiler: PerformanceProfiler) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.uploadAcknowledgementTimeout)
        while clock.now < deadline {
            if isCancelled || Task.isCancelled { return false }
            if profiler.sampleCount(for: metric) == previousCount + 1 { return true }
            do { try await Task.sleep(for: Self.uploadAcknowledgementPoll) }
            catch { return false }
        }
        return false
    }

    private static var environment: String {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil ? "Device" : "Simulator"
    }
}
#endif
