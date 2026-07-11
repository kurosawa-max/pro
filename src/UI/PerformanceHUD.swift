#if DEBUG
import Foundation
import SwiftUI

struct PerformanceHUD: View {
    let profiler: PerformanceProfiler?
    @State private var isExpanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let snapshot = profiler?.snapshot() ?? PerformanceSnapshot()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label("Perf", systemImage: "gauge.with.dots.needle.67percent")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 3) {
                        countRow("Vertices", snapshot.vertexCount)
                        countRow("Triangles", snapshot.triangleCount)
                        metricRow("Picking ms", snapshot[.picking])
                        metricRow("Sculpt ms", snapshot[.sculpt])
                        metricRow("Normal ms", snapshot[.normalRebuild])
                        metricRow("Vertex upload ms", snapshot[.vertexUpload])
                        metricRow("Index upload ms", snapshot[.indexUpload])
                        metricRow("Frame ms", snapshot[.frameCPU])
                        valueRow("FPS", snapshot.framesPerSecond)
                        Text("latest / avg (60)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Performance metrics")
                }
            }
        }
    }

    private func metricRow(_ label: String, _ sample: PerformanceSample) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Text("\(formatted(sample.latestMilliseconds)) / \(formatted(sample.averageMilliseconds))")
        }
        .frame(width: 235)
    }

    private func countRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
        }
        .frame(width: 235)
    }

    private func valueRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(formatted(value))
        }
        .frame(width: 235)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value.isFinite ? value : 0)
    }
}
#endif
