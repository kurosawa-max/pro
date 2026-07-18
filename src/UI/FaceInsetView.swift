import Foundation
import SwiftUI

struct FaceInsetView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var distanceText = "1.0"
    @State private var preview: FaceInsetPreview?
    @State private var errorMessage: String?
    @State private var isCalculating = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Inset Width") {
                    HStack {
                        TextField("Width", text: $distanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { recalculatePreview() }
                            .accessibilityLabel("Inset width in millimeters")
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Stepper("Adjust width by 0.1 millimeters", onIncrement: {
                        adjustDistance(by: 0.1)
                    }, onDecrement: {
                        adjustDistance(by: -0.1)
                    })
                    .labelsHidden()
                    Text("Width is measured in world-space millimeters and must be positive.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Selection") {
                    countRow("Selected faces", estimate?.selectedFaceCount ?? model.selectedFaceCount)
                    countRow("Components", estimate?.componentCount)
                    countRow("Boundary loops", estimate?.boundaryLoopCount)
                    countRow("Boundary edges", estimate?.boundaryEdgeCount)
                    countRow("Interior vertices", estimate?.interiorVertexCount)
                }

                Section("Result") {
                    transitionRow("Vertices", from: estimate?.originalVertexCount, to: estimate?.resultingVertexCount)
                    transitionRow("Triangles", from: estimate?.originalTriangleCount, to: estimate?.resultingTriangleCount)
                    countRow("Added inset vertices", estimate?.addedInsetVertexCount)
                    countRow("Added ring triangles", estimate?.addedRingTriangleCount)
                    if let estimate {
                        LabeledContent("Original selected area", value: area(estimate.originalAreaSquareMillimeters))
                        LabeledContent("Inset selected area", value: area(estimate.insetAreaSquareMillimeters))
                        LabeledContent("Maximum plane deviation", value: millimeters(estimate.maximumPlanarityDeviationMillimeters))
                        LabeledContent("Result bounds", value: dimensions(estimate.resultBounds))
                            .accessibilityHint("World-space dimensions in millimeters")
                        LabeledContent("Estimated working memory", value: ByteCountFormatter.string(
                            fromByteCount: Int64(estimate.estimatedWorkingByteCount), countStyle: .memory))
                    }
                }

                Section("Safety") {
                    Label("Apply creates one Undo command.", systemImage: "arrow.uturn.backward.circle")
                    Label("This operation changes mesh topology and clears face selection.",
                          systemImage: "exclamationmark.triangle")
                    Text("This first version accepts only planar, strictly convex selected components with exactly one simple boundary loop. Holes, concave regions, non-planar regions, collapse, and unsafe miters are rejected.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The entire result is validated before it replaces the current mesh. Preview and validation failures leave the workspace unchanged.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if previewIsStale {
                    Section("Preview Changed") {
                        Label("The source mesh, Transform, selection, or width changed. Recalculate before applying.",
                              systemImage: "arrow.clockwise.circle")
                    }
                }
                if let message = errorMessage ?? model.faceInsetError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Inset error: \(message)")
                    }
                }
            }
            .navigationTitle("Inset Faces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate Preview") { recalculatePreview() }.disabled(isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isBusy {
                        ProgressView(isApplying ? "Applying inset" : "Calculating preview")
                            .accessibilityLabel(isApplying ? "Applying face inset" : "Calculating inset preview")
                    }
                    Spacer()
                    Button("Apply Inset") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding().background(.bar)
            }
        }
        .task { if preview == nil { recalculatePreview() } }
        .onDisappear { model.discardFaceInsetPreview() }
    }

    private var estimate: FaceInsetEstimate? { preview?.estimate }
    private var isBusy: Bool { isCalculating || isApplying || model.isFaceInsetRunning }
    private var parsedDistance: Double? {
        let normalized = distanceText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
    private var parsedOptions: FaceInsetOptions? {
        parsedDistance.map { FaceInsetOptions(distanceMillimeters: $0) }
    }
    private var previewIsStale: Bool {
        guard let preview else { return false }
        return !model.isFaceInsetPreviewCurrent(preview) || parsedOptions != preview.options
    }

    private func recalculatePreview() {
        guard !isBusy else { return }
        preview = nil
        errorMessage = nil
        guard let options = parsedOptions else {
            errorMessage = FaceInsetError.invalidDistance.localizedDescription
            return
        }
        isCalculating = true
        Task { @MainActor in
            await Task.yield()
            defer { isCalculating = false }
            do { preview = try model.previewFaceInset(options: options) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply() {
        guard let preview, !previewIsStale, !isBusy else { return }
        isApplying = true
        Task { @MainActor in
            await Task.yield()
            defer { isApplying = false }
            do { _ = try model.applyFaceInset(preview: preview); dismiss() }
            catch { errorMessage = error.localizedDescription; self.preview = nil }
        }
    }

    private func cancel() { model.discardFaceInsetPreview(); dismiss() }
    private func adjustDistance(by delta: Double) {
        let current = parsedDistance ?? FaceInsetOptions.defaultDistanceMillimeters
        let value = min(max(current + delta, FaceInsetOptions.minimumDistanceMillimeters),
                        FaceInsetOptions.maximumDistanceMillimeters)
        distanceText = value.formatted(.number.precision(.fractionLength(1...3)))
    }
    private func countRow(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label, value: value.map(localizedCount) ?? "—")
    }
    private func transitionRow(_ label: String, from: Int?, to: Int?) -> some View {
        LabeledContent(label, value: from.flatMap { source in to.map { "\(localizedCount(source)) → \(localizedCount($0))" } } ?? "—")
    }
    private func localizedCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
    private func area(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...3)))) mm²" }
    private func millimeters(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...6)))) mm" }
    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × \(LengthFormatter.string(extent.y, fractionDigits: 3)) × \(LengthFormatter.string(extent.z, fractionDigits: 3))"
    }
}
