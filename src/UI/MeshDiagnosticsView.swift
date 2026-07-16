import Foundation
import SwiftUI
import simd

struct MeshDiagnosticsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.isMeshDiagnosticsRunning {
                    ProgressView("Analyzing mesh…")
                        .accessibilityLabel("Analyzing mesh")
                } else if let report = model.currentMeshDiagnosticsReport {
                    reportView(report)
                } else {
                    ContentUnavailableView(
                        model.isMeshDiagnosticsStale ? "Diagnostics Are Stale" : "Mesh Not Analyzed",
                        systemImage: model.isMeshDiagnosticsStale ? "arrow.clockwise.circle" : "stethoscope",
                        description: Text(model.isMeshDiagnosticsStale
                            ? "The mesh or Transform changed after the last analysis. Refresh to avoid showing old results."
                            : "Analyze the current mesh without changing geometry or Undo history.")
                    )
                }
            }
            .navigationTitle("Mesh Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.meshDiagnosticsReport == nil ? "Analyze" : "Refresh",
                           systemImage: "arrow.clockwise") {
                        model.refreshMeshDiagnostics()
                    }
                    .disabled(model.isMeshDiagnosticsRunning || model.isStrokeActive || model.isGizmoDragging)
                    .accessibilityHint("Reanalyzes the current mesh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.meshDiagnosticsError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .accessibilityLabel("Diagnostics error: \(error)")
                }
            }
        }
    }

    private func reportView(_ report: MeshDiagnosticsReport) -> some View {
        List {
            Section("Mesh Health") {
                Label(report.severity.displayName, systemImage: severitySymbol(report.severity))
                    .foregroundStyle(severityColor(report.severity))
                    .font(.headline)
                    .accessibilityLabel("Mesh health: \(report.severity.displayName)")
                LabeledContent("Closed", value: yesNo(report.topology.isClosed))
                LabeledContent("Manifold", value: yesNo(report.topology.isManifold))
                LabeledContent("Orientation consistent", value: yesNo(report.topology.hasConsistentOrientation))
            }

            Section("Topology") {
                countRow("Vertices", report.vertexCount)
                countRow("Triangles", report.triangleCount)
                countRow("Unique edges", report.uniqueEdgeCount)
                countRow("Components", report.topology.connectedComponentCount)
                countRow("Largest component", report.topology.largestComponentTriangleCount, suffix: " triangles")
                countRow("Boundary edges", report.topology.boundaryEdgeCount)
                countRow("Manifold edges", report.topology.manifoldEdgeCount)
                countRow("Non-manifold edges", report.topology.nonManifoldEdgeCount)
                countRow("Winding conflicts", report.topology.inconsistentWindingEdgeCount)
                countRow("Degenerate triangles", report.topology.degenerateTriangleCount)
                countRow("Duplicate triangles", report.topology.duplicateTriangleCount)
                countRow("Isolated vertices", report.topology.isolatedVertexCount)
            }

            Section("World Dimensions") {
                dimensionRow("X", report.worldMetrics.dimensionsMM.x)
                dimensionRow("Y", report.worldMetrics.dimensionsMM.y)
                dimensionRow("Z", report.worldMetrics.dimensionsMM.z)
                LabeledContent("Bounds center", value: vector(report.worldMetrics.bounds.center, unit: "mm"))
            }

            Section("Geometry") {
                LabeledContent("Local surface area", value: area(report.localMetrics.surfaceAreaMM2))
                LabeledContent("World surface area", value: area(report.worldMetrics.surfaceAreaMM2))
                if let volume = report.worldMetrics.absoluteVolumeMM3 {
                    LabeledContent("World volume", value: volumeText(volume))
                } else {
                    LabeledContent("World volume", value: "Unavailable — mesh is not closed, manifold, and consistently oriented")
                }
                if report.volumeIsReliable {
                    LabeledContent("Local signed volume", value: signedVolume(report.localMetrics.signedVolumeMM3))
                }
            }

            Section("Operations") {
                Label(report.canSubdivide ? "Subdivision available" : "Subdivision unavailable",
                      systemImage: report.canSubdivide ? "checkmark.circle" : "xmark.circle")
                if let estimate = report.subdivision.estimate {
                    countRow("After subdivision", estimate.resultVertices, suffix: " vertices")
                    countRow("After subdivision", estimate.resultTriangles, suffix: " triangles")
                    LabeledContent("Estimated working memory",
                                   value: ByteCountFormatter.string(fromByteCount: Int64(estimate.estimatedWorkingBytes),
                                                                    countStyle: .memory))
                } else if let reason = report.subdivision.failureReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Label(stlCapabilityText(report.stlExport),
                      systemImage: report.canExportSTL ? "checkmark.circle" : "xmark.circle")
                if let estimate = report.stlExport.estimate {
                    LabeledContent("STL size", value: ByteCountFormatter.string(fromByteCount: Int64(estimate.byteCount),
                                                                                countStyle: .file))
                } else if let reason = report.stlExport.failureReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Viewport Overlay") {
                Toggle("Show diagnostics overlay", isOn: $model.meshDiagnosticsOverlayOptions.isVisible)
                Toggle("Boundary edges", isOn: $model.meshDiagnosticsOverlayOptions.boundaryEdges)
                Toggle("Non-manifold edges", isOn: $model.meshDiagnosticsOverlayOptions.nonManifoldEdges)
                Toggle("Winding conflicts", isOn: $model.meshDiagnosticsOverlayOptions.windingConflicts)
                Toggle("Degenerate triangles", isOn: $model.meshDiagnosticsOverlayOptions.degenerateTriangles)
                Toggle("Isolated vertices", isOn: $model.meshDiagnosticsOverlayOptions.isolatedVertices)
            }

            Section("Issues") {
                if report.issues.isEmpty {
                    Label("No detected issues", systemImage: "checkmark.seal")
                } else {
                    ForEach(report.issues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(issue.severity.displayName, systemImage: severitySymbol(issue.severity))
                                .font(.caption.bold())
                                .foregroundStyle(severityColor(issue.severity))
                            Text(issue.message)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                Text("Analyzed topology \(report.sourceTopologyID.uuidString.prefix(8)), mesh revision \(report.sourceRevision). Results are runtime-only and are not saved in the project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func countRow(_ label: String, _ value: Int, suffix: String = "") -> some View {
        LabeledContent(label, value: NumberFormatter.localizedString(from: NSNumber(value: value),
                                                                     number: .decimal) + suffix)
    }

    private func dimensionRow(_ axis: String, _ value: Float) -> some View {
        LabeledContent(axis, value: String(format: "%.2f mm", value))
    }

    private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    private func area(_ value: Double) -> String { String(format: "%.3f mm²", value) }

    private func signedVolume(_ value: Double) -> String { String(format: "%+.3f mm³", value) }

    private func volumeText(_ value: Double) -> String {
        String(format: "%.3f mm³ (%.3f cm³)", value, value / 1_000)
    }

    private func vector(_ value: SIMD3<Float>, unit: String) -> String {
        String(format: "%.2f, %.2f, %.2f %@", value.x, value.y, value.z, unit)
    }

    private func stlCapabilityText(_ value: MeshSTLExportDiagnostic) -> String {
        if !value.canExport { return "STL export unavailable" }
        return value.hasPrintabilityWarning ? "STL export available with printability warning" : "STL export available"
    }

    private func severitySymbol(_ severity: MeshDiagnosticSeverity) -> String {
        switch severity {
        case .healthy: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func severityColor(_ severity: MeshDiagnosticSeverity) -> Color {
        switch severity {
        case .healthy: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
