import Foundation
import SwiftUI

struct MeshCleanupView: View {
    @ObservedObject var model: WorkspaceModel
    let diagnostics: MeshDiagnosticsReport
    @Environment(\.dismiss) private var dismiss
    @State private var options = MeshCleanupOptions.none
    @State private var preview: MeshCleanupPreview?
    @State private var errorMessage: String?
    @State private var isEstimating = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Current") {
                    countRow("Vertices", model.mesh.vertices.count)
                    countRow("Triangles", model.mesh.indices.count / 3)
                }

                Section("Selected Cleanup") {
                    Toggle("Remove degenerate triangles", isOn: $options.removeDegenerateTriangles)
                        .disabled(diagnostics.topology.degenerateTriangleCount == 0)
                        .accessibilityHint("Removes repeated-index, collinear, and scale-relative tiny-area triangles")
                    Toggle("Remove duplicate triangles", isOn: $options.removeDuplicateTriangles)
                        .disabled(diagnostics.topology.duplicateTriangleCount == 0)
                        .accessibilityHint("Keeps the first triangle and removes later unordered duplicates")
                    Toggle("Remove isolated vertices", isOn: $options.removeIsolatedVertices)
                        .disabled(diagnostics.topology.isolatedVertexCount == 0)
                        .accessibilityHint("Removes vertices not referenced before triangle cleanup")

                    countRow("Degenerate triangles", scheduledDegenerate)
                    countRow("Duplicate triangles", scheduledDuplicate)
                    countRow("Isolated vertices", scheduledIsolated)
                    countRow("Newly unreferenced vertices", scheduledUnreferenced)
                }

                Section("Result") {
                    countRow("Vertices", preview?.estimate.resultingVertexCount ?? model.mesh.vertices.count)
                    countRow("Triangles", preview?.estimate.resultingTriangleCount ?? model.mesh.indices.count / 3)
                    if let estimate = preview?.estimate {
                        LabeledContent("Estimated working memory",
                                       value: ByteCountFormatter.string(
                                        fromByteCount: Int64(estimate.estimatedWorkingByteCount), countStyle: .memory))
                    }
                }

                Section("Safety") {
                    Label("Geometry positions will not be moved.", systemImage: "checkmark.shield")
                    Text("Boundary holes, non-manifold edges, winding conflicts, self-intersections, and nearby vertices will not be repaired.")
                    Text("Triangle removal may change boundary or component counts. Run Diagnostics again after Cleanup.")
                }

                if let errorMessage {
                    Section("Cannot Apply") {
                        Text(errorMessage).foregroundStyle(.red)
                            .accessibilityLabel("Cleanup error: \(errorMessage)")
                    }
                }
            }
            .navigationTitle("Mesh Cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isEstimating || isApplying || model.isMeshCleanupRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isEstimating || isApplying || model.isMeshCleanupRunning {
                        ProgressView().accessibilityLabel("Processing Mesh Cleanup")
                    }
                    Spacer()
                    Button("Cleanup", role: .destructive) { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || isEstimating || isApplying || model.isMeshCleanupRunning)
                        .accessibilityHint("Applies only the selected cleanup items as one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .onChange(of: options) { _, _ in updatePreview() }
    }

    private var scheduledDegenerate: Int {
        preview?.estimate.removableDegenerateTriangleCount
            ?? (options.removeDegenerateTriangles ? diagnostics.topology.degenerateTriangleCount : 0)
    }

    private var scheduledDuplicate: Int {
        preview?.estimate.removableDuplicateTriangleCount
            ?? (options.removeDuplicateTriangles ? diagnostics.topology.duplicateTriangleCount : 0)
    }

    private var scheduledIsolated: Int {
        preview?.estimate.removableIsolatedVertexCount
            ?? (options.removeIsolatedVertices ? diagnostics.topology.isolatedVertexCount : 0)
    }

    private var scheduledUnreferenced: Int {
        preview?.estimate.newlyUnreferencedVertexCount ?? 0
    }

    private func updatePreview() {
        preview = nil
        errorMessage = nil
        guard options.hasSelection else {
            isEstimating = false
            return
        }
        isEstimating = true
        let selectedOptions = options
        Task { @MainActor in
            await Task.yield()
            defer { if options == selectedOptions { isEstimating = false } }
            do {
                let candidate = try model.previewMeshCleanup(options: selectedOptions)
                if options == selectedOptions { preview = candidate }
            } catch {
                if options == selectedOptions { errorMessage = error.localizedDescription }
            }
        }
    }

    private func apply() {
        guard let preview else { return }
        isApplying = true
        Task { @MainActor in
            await Task.yield()
            defer { isApplying = false }
            do {
                _ = try model.applyMeshCleanup(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func countRow(_ label: String, _ value: Int) -> some View {
        LabeledContent(label, value: NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal))
    }
}
