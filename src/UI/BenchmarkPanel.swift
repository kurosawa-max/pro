#if DEBUG
import SwiftUI
import UIKit

struct BenchmarkPanel: View {
    @ObservedObject var model: WorkspaceModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                Label("Bench", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preset: \(model.benchmarkDisplayName)")
                    Text("Vertices: \(model.mesh.vertices.count)")
                    Text("Triangles: \(model.mesh.indices.count / 3)")

                    HStack(spacing: 4) {
                        ForEach(BenchmarkPreset.allCases, id: \.self) { preset in
                            Button(preset.rawValue) { model.loadBenchmarkPreset(preset) }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }

                    Button("Reset Metrics", systemImage: "arrow.counterclockwise") {
                        model.resetPerformanceMetrics()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    if model.isBenchmarkRunning {
                        ProgressView(value: model.benchmarkProgress)
                        Button("Cancel", role: .cancel) { model.cancelBenchmarks() }
                            .buttonStyle(.bordered).controlSize(.mini)
                    } else {
                        Button("Run All Benchmarks", systemImage: "play.fill") { model.runAllBenchmarks() }
                            .buttonStyle(.borderedProminent).controlSize(.mini)
                    }

                    if let report = model.lastBenchmarkReport {
                        Text("Last: \(report.presets.count) presets / \(report.presets.flatMap(\.cases).count) cases")
                        HStack {
                            Button("Copy Text") { UIPasteboard.general.string = report.plainText }
                            Button("Copy JSON") { UIPasteboard.general.string = report.json }
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Performance benchmark controls")
            }
        }
    }
}
#endif
