import Foundation
import SwiftUI

struct FaceExtrudeView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var distanceText = "1.0"
    @State private var preview: FaceExtrudePreview?
    @State private var errorMessage: String?
    @State private var isCalculating = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Distance") {
                    HStack {
                        TextField("Distance", text: $distanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { recalculatePreview() }
                            .accessibilityLabel("Extrusion distance in millimeters")
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Stepper("Adjust distance by 0.1 millimeters", onIncrement: {
                        adjustDistance(by: 0.1)
                    }, onDecrement: {
                        adjustDistance(by: -0.1)
                    })
                    .labelsHidden()
                    Text("Positive distance follows each component's winding normal. Negative distance moves in the opposite direction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Selection") {
                    countRow("Selected faces", estimate?.selectedFaceCount ?? model.selectedFaceCount)
                    countRow("Components", estimate?.componentCount)
                    countRow("Boundary edges", estimate?.boundaryEdgeCount)
                    countRow("Selected unique vertices", estimate?.selectedUniqueVertexCount)
                }

                Section("Result") {
                    transitionRow("Vertices", from: estimate?.originalVertexCount,
                                  to: estimate?.resultingVertexCount)
                    transitionRow("Triangles", from: estimate?.originalTriangleCount,
                                  to: estimate?.resultingTriangleCount)
                    countRow("Removed original vertices", estimate?.removedOriginalVertexCount)
                    countRow("Added extruded vertices", estimate?.addedExtrudedVertexCount)
                    countRow("Added side triangles", estimate?.addedSideTriangleCount)
                    if let estimate {
                        LabeledContent("Result bounds", value: dimensions(estimate.resultBounds))
                            .accessibilityHint("World space dimensions in millimeters")
                        LabeledContent("Estimated working memory", value: ByteCountFormatter.string(
                            fromByteCount: Int64(estimate.estimatedWorkingByteCount), countStyle: .memory))
                    }
                }

                Section("Safety") {
                    Label("Apply creates one Undo command.", systemImage: "arrow.uturn.backward.circle")
                    Label("This operation changes mesh topology and clears face selection.",
                          systemImage: "exclamationmark.triangle")
                    Text("Face Extrude validates the entire mesh for invalid indices, non-finite values, degenerate triangles, and duplicate triangles. A problem outside the selection also blocks extrusion; use Mesh Diagnostics and Mesh Cleanup before retrying.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Self-intersections and collisions are not detected. Open boundaries, non-manifold selected edges, inconsistent winding, and whole-shell selections are rejected.")
                        .fixedSize(horizontal: false, vertical: true)
                    if parsedDistance.map({ $0 < 0 }) == true {
                        Text("Negative extrusion can create self-intersections inside the object.")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Warning: negative extrusion can create self-intersections")
                    }
                }

                if previewIsStale {
                    Section("Preview Changed") {
                        Label("The source mesh, Transform, selection, or distance changed. Recalculate before applying.",
                              systemImage: "arrow.clockwise.circle")
                    }
                }

                if let errorMessage = errorMessage ?? model.faceExtrudeError {
                    Section("Cannot Apply") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Extrude error: \(errorMessage)")
                    }
                }
            }
            .navigationTitle("Extrude Faces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate Preview") { recalculatePreview() }
                        .disabled(isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isBusy {
                        ProgressView(isApplying ? "Applying extrusion" : "Calculating preview")
                            .accessibilityLabel(isApplying ? "Applying face extrusion" : "Calculating extrusion preview")
                    }
                    Spacer()
                    Button("Apply Extrude") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .task { if preview == nil { recalculatePreview() } }
        .onDisappear { model.discardFaceExtrudePreview() }
    }

    private var estimate: FaceExtrudeEstimate? { preview?.estimate }
    private var isBusy: Bool { isCalculating || isApplying || model.isFaceExtrudeRunning }

    private var parsedDistance: Double? {
        let normalized = distanceText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    private var parsedOptions: FaceExtrudeOptions? {
        guard let distance = parsedDistance else { return nil }
        return FaceExtrudeOptions(distanceMillimeters: distance)
    }

    private var previewIsStale: Bool {
        guard let preview else { return false }
        return !model.isFaceExtrudePreviewCurrent(preview) || parsedOptions != preview.options
    }

    private func recalculatePreview() {
        guard !isBusy else { return }
        preview = nil
        errorMessage = nil
        guard let options = parsedOptions else {
            errorMessage = FaceExtrudeError.invalidDistance.localizedDescription
            return
        }
        isCalculating = true
        Task { @MainActor in
            await Task.yield()
            defer { isCalculating = false }
            do { preview = try model.previewFaceExtrude(options: options) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply() {
        guard let preview, !previewIsStale, !isBusy else { return }
        isApplying = true
        Task { @MainActor in
            await Task.yield()
            defer { isApplying = false }
            do {
                _ = try model.applyFaceExtrude(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func cancel() {
        model.discardFaceExtrudePreview()
        dismiss()
    }

    private func adjustDistance(by delta: Double) {
        let current = parsedDistance ?? FaceExtrudeOptions.defaultDistanceMillimeters
        let adjusted = min(max(current + delta, -FaceExtrudeOptions.maximumAbsoluteDistanceMillimeters),
                           FaceExtrudeOptions.maximumAbsoluteDistanceMillimeters)
        distanceText = adjusted.formatted(.number.precision(.fractionLength(1...3)))
    }

    private func countRow(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label, value: value.map(localizedCount) ?? "—")
    }

    private func transitionRow(_ label: String, from: Int?, to: Int?) -> some View {
        LabeledContent(label, value: from.flatMap { source in
            to.map { "\(localizedCount(source)) → \(localizedCount($0))" }
        } ?? "—")
    }

    private func localizedCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × \(LengthFormatter.string(extent.y, fractionDigits: 3)) × \(LengthFormatter.string(extent.z, fractionDigits: 3))"
    }
}
