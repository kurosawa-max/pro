import Foundation
import SwiftUI

struct FaceBevelView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var widthText = "1.0"
    @State private var heightText = "0.5"
    @State private var preview: FaceBevelPreview?
    @State private var errorMessage: String?
    @State private var isCalculating = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bevel Dimensions") {
                    numericField(
                        title: "Width", text: $widthText,
                        accessibilityLabel: "Bevel width in millimeters")
                    Stepper("Adjust width by 0.1 millimeters", onIncrement: {
                        adjustWidth(by: 0.1)
                    }, onDecrement: {
                        adjustWidth(by: -0.1)
                    })
                    .labelsHidden()

                    numericField(
                        title: "Height", text: $heightText,
                        accessibilityLabel: "Signed bevel height in millimeters")
                    Stepper("Adjust height by 0.1 millimeters", onIncrement: {
                        adjustHeight(by: 0.1)
                    }, onDecrement: {
                        adjustHeight(by: -0.1)
                    })
                    .labelsHidden()

                    Text("Width moves the boundary inward. Positive height follows each component's winding normal; negative height moves opposite it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let options = parsedOptions {
                        LabeledContent("Bevel angle", value: degrees(options.bevelAngleDegrees))
                        LabeledContent("Slope length", value: millimeters(options.slopeLengthMillimeters))
                    }
                }

                Section("Selection") {
                    countRow("Selected faces", estimate?.selectedFaceCount ?? model.selectedFaceCount)
                    countRow("Components", estimate?.componentCount)
                    countRow("Boundary loops", estimate?.boundaryLoopCount)
                    countRow("Boundary edges", estimate?.boundaryEdgeCount)
                    countRow("Selected unique vertices", estimate?.selectedUniqueVertexCount)
                    countRow("Interior vertices", estimate?.interiorVertexCount)
                }

                Section("Result") {
                    transitionRow(
                        "Vertices", from: estimate?.originalVertexCount,
                        to: estimate?.resultingVertexCount)
                    transitionRow(
                        "Triangles", from: estimate?.originalTriangleCount,
                        to: estimate?.resultingTriangleCount)
                    countRow("Removed original vertices", estimate?.removedOriginalVertexCount)
                    countRow("Added bevel vertices", estimate?.addedBevelVertexCount)
                    countRow("Added chamfer triangles", estimate?.addedChamferTriangleCount)
                    if let estimate {
                        LabeledContent(
                            "Original selected area",
                            value: area(estimate.originalAreaSquareMillimeters))
                        LabeledContent(
                            "Inner cap area",
                            value: area(estimate.innerAreaSquareMillimeters))
                        LabeledContent(
                            "Maximum plane deviation",
                            value: millimeters(estimate.maximumPlanarityDeviationMillimeters))
                        LabeledContent("Result bounds", value: dimensions(estimate.resultBounds))
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
                    Label(
                        "This operation changes mesh topology and clears face selection.",
                        systemImage: "exclamationmark.triangle")
                    Text("This is a Face Region Bevel, not a general edge bevel. It accepts only planar, strictly convex selected components with one simple boundary loop.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The complete result is validated before installation. Full-scene 3D collision detection is not performed.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This one-segment chamfer shares area-weighted vertex normals, so sharp edges can appear smooth in the viewport. Exported STL geometry remains faceted.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if previewIsStale {
                    Section("Preview Changed") {
                        Label(
                            "The source mesh, Transform, selection, width, or height changed. Recalculate before applying.",
                            systemImage: "arrow.clockwise.circle")
                    }
                }
                if let message = errorMessage ?? model.faceBevelError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Bevel error: \(message)")
                    }
                }
            }
            .navigationTitle("Bevel Faces")
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
                        ProgressView(isApplying ? "Applying bevel" : "Calculating preview")
                            .accessibilityLabel(
                                isApplying ? "Applying face bevel" : "Calculating bevel preview")
                    }
                    Spacer()
                    Button("Apply Bevel") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .task { if preview == nil { recalculatePreview() } }
        .onDisappear { model.discardFaceBevelPreview() }
    }

    private var estimate: FaceBevelEstimate? { preview?.estimate }
    private var isBusy: Bool { isCalculating || isApplying || model.isFaceBevelRunning }
    private var parsedWidth: Double? { parsedNumber(widthText) }
    private var parsedHeight: Double? { parsedNumber(heightText) }
    private var parsedOptions: FaceBevelOptions? {
        guard let width = parsedWidth, let height = parsedHeight else { return nil }
        return FaceBevelOptions(widthMillimeters: width, heightMillimeters: height)
    }
    private var previewIsStale: Bool {
        guard let preview else { return false }
        return !model.isFaceBevelPreviewCurrent(preview) || parsedOptions != preview.options
    }

    private func numericField(
        title: String,
        text: Binding<String>,
        accessibilityLabel: String
    ) -> some View {
        HStack {
            TextField(title, text: text)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .onSubmit { recalculatePreview() }
                .accessibilityLabel(accessibilityLabel)
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func recalculatePreview() {
        guard !isBusy else { return }
        preview = nil
        errorMessage = nil
        guard let options = parsedOptions else {
            errorMessage = "Enter finite numeric width and height values."
            return
        }
        isCalculating = true
        Task { @MainActor in
            await Task.yield()
            defer { isCalculating = false }
            do { preview = try model.previewFaceBevel(options: options) }
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
                _ = try model.applyFaceBevel(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func cancel() {
        model.discardFaceBevelPreview()
        dismiss()
    }

    private func adjustWidth(by delta: Double) {
        let current = parsedWidth ?? FaceBevelOptions.defaultWidthMillimeters
        let value = min(
            max(current + delta, FaceBevelOptions.minimumWidthMillimeters),
            FaceBevelOptions.maximumWidthMillimeters)
        widthText = value.formatted(.number.precision(.fractionLength(1...3)))
    }

    private func adjustHeight(by delta: Double) {
        let current = parsedHeight ?? FaceBevelOptions.defaultHeightMillimeters
        var value = min(
            max(current + delta, -FaceBevelOptions.maximumAbsoluteHeightMillimeters),
            FaceBevelOptions.maximumAbsoluteHeightMillimeters)
        if abs(value) < FaceBevelOptions.minimumAbsoluteHeightMillimeters {
            value = delta < 0
                ? -FaceBevelOptions.minimumAbsoluteHeightMillimeters
                : FaceBevelOptions.minimumAbsoluteHeightMillimeters
        }
        heightText = value.formatted(.number.precision(.fractionLength(1...3)))
    }

    private func parsedNumber(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
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

    private func area(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...3)))) mm²"
    }

    private func millimeters(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...6)))) mm"
    }

    private func degrees(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2))))°"
    }

    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × "
            + "\(LengthFormatter.string(extent.y, fractionDigits: 3)) × "
            + LengthFormatter.string(extent.z, fractionDigits: 3)
    }
}
