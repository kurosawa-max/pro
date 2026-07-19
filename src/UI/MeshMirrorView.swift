import Foundation
import SwiftUI

struct MeshMirrorView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = MeshMirrorOptions()
    @State private var preview: MeshMirrorPreview?
    @State private var errorMessage: String?
    @State private var isCalculating = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Local Mirror Plane") {
                    Picker("Axis", selection: $options.axis) {
                        ForEach(MirrorAxis.allCases) { axis in
                            Text("\(axis.rawValue) = 0").tag(axis)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Chooses the object-local zero plane used for Mirror Copy")
                    Text("The plane passes through the object-local origin and follows the object's current rotation. Object Transform is preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Source Classification") {
                    countRow("Components", estimate?.sourceComponentCount)
                    countRow("Closed components", estimate?.closedComponentCount)
                    countRow("Open half components", estimate?.openComponentCount)
                    countRow("Seam loops", estimate?.seamLoopCount)
                    countRow("Boundary edges", estimate?.boundaryEdgeCount)
                    countRow("Seam vertices", estimate?.seamVertexCount)
                    if let estimate {
                        LabeledContent("Source side", value: estimate.sourceSide.rawValue)
                        LabeledContent(
                            "Seam tolerance",
                            value: "\(estimate.seamTolerance.formatted(.number.precision(.fractionLength(0...8)))) mm")
                        LabeledContent(
                            "Maximum seam snap",
                            value: "\(estimate.maximumSeamSnapDistance.formatted(.number.precision(.fractionLength(0...8)))) mm")
                    }
                }

                Section("Result") {
                    transitionRow(
                        "Vertices", from: estimate?.originalVertexCount,
                        to: estimate?.resultingVertexCount)
                    transitionRow(
                        "Triangles", from: estimate?.originalTriangleCount,
                        to: estimate?.resultingTriangleCount)
                    countRow("Result components", estimate?.resultingComponentCount)
                    countRow("Snapped seam vertices", estimate?.snappedVertexCount)
                    countRow("Added mirror vertices", estimate?.mirroredVertexCount)
                    if let estimate {
                        LabeledContent("Local bounds", value: dimensions(estimate.resultLocalBounds))
                        LabeledContent("World bounds", value: dimensions(estimate.resultWorldBounds))
                            .accessibilityHint("World-space dimensions in millimeters")
                        LabeledContent(
                            "Estimated working memory",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(estimate.estimatedWorkingByteCount),
                                countStyle: .memory))
                    }
                }

                Section("Safety") {
                    Label("Apply creates one Undo command.", systemImage: "arrow.uturn.backward.circle")
                    Label("Accepted seam vertices snap to the exact zero plane.", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    Text("Closed components are copied as detached mirrored shells. Open components are accepted only when every boundary edge forms an unbranched loop on the selected zero plane.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only vertices within the displayed tolerance are seam candidates. Vertices outside it are not welded, and no other proximity weld is performed. A snap that collapses geometry is rejected.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Mirror Copy does not cut crossing geometry, repair topology, or change Object Transform.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if previewIsStale {
                    Section("Preview Changed") {
                        Label(
                            "The mesh, Transform, or axis changed. Recalculate before applying.",
                            systemImage: "arrow.clockwise.circle")
                    }
                }
                if let message = errorMessage ?? model.meshMirrorError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Mirror Copy error: \(message)")
                    }
                }
            }
            .navigationTitle("Mirror Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate Preview") { recalculatePreview() }
                        .disabled(isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isBusy {
                        ProgressView(isApplying ? "Applying Mirror Copy" : "Analyzing mesh")
                            .accessibilityLabel(
                                isApplying ? "Applying Mirror Copy" : "Calculating Mirror Copy preview")
                    }
                    Spacer()
                    Button("Apply Mirror Copy") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .task { if preview == nil { recalculatePreview() } }
        .onChange(of: options) { _, _ in
            preview = nil
            errorMessage = nil
        }
        .onDisappear { model.discardMeshMirrorPreview() }
    }

    private var estimate: MeshMirrorEstimate? { preview?.estimate }
    private var isBusy: Bool { isCalculating || isApplying || model.isMeshMirrorRunning }
    private var previewIsStale: Bool {
        guard let preview else { return false }
        return preview.options != options || !model.isMeshMirrorPreviewCurrent(preview)
    }

    private func recalculatePreview() {
        guard !isBusy else { return }
        preview = nil
        errorMessage = nil
        isCalculating = true
        let requestedOptions = options
        Task { @MainActor in
            await Task.yield()
            defer { if options == requestedOptions { isCalculating = false } }
            do {
                let candidate = try model.previewMeshMirror(options: requestedOptions)
                if options == requestedOptions { preview = candidate }
            } catch {
                if options == requestedOptions { errorMessage = error.localizedDescription }
            }
        }
    }

    private func apply() {
        guard let preview, !previewIsStale, !isBusy else { return }
        isApplying = true
        Task { @MainActor in
            await Task.yield()
            defer { isApplying = false }
            do {
                _ = try model.applyMeshMirror(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func cancel() {
        model.discardMeshMirrorPreview()
        dismiss()
    }

    private func countRow(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label, value: value.map(localizedCount) ?? "—")
    }

    private func transitionRow(_ label: String, from: Int?, to: Int?) -> some View {
        LabeledContent(
            label,
            value: from.flatMap { source in
                to.map { "\(localizedCount(source)) → \(localizedCount($0))" }
            } ?? "—")
    }

    private func localizedCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × "
            + "\(LengthFormatter.string(extent.y, fractionDigits: 3)) × "
            + LengthFormatter.string(extent.z, fractionDigits: 3)
    }
}
