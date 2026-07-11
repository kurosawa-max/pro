#if DEBUG
import SwiftUI

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
