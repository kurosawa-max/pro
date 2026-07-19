import Foundation
import SwiftUI

struct MeshLinearArrayView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var axis = LinearArrayAxis.x
    @State private var countText = "2"
    @State private var spacingText = "10.0"
    @State private var preview: MeshLinearArrayPreview?
    @State private var errorMessage: String?
    @State private var isCalculating = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Array Parameters") {
                    Picker("Local axis", selection: $axis) {
                        ForEach(LinearArrayAxis.allCases) { value in
                            Text("Local \(value.rawValue)").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Chooses the object-local direction of the Array")

                    HStack {
                        TextField("Count", text: $countText)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Array copy count")
                        Stepper("", value: countBinding, in: MeshLinearArray.minimumCount...MeshLinearArray.maximumCount)
                            .labelsHidden()
                            .accessibilityLabel("Adjust Array copy count")
                    }
                    Text("Count includes the unchanged source mesh as copy 0.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Spacing", text: $spacingText)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel("Array spacing in millimeters")
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Text("Positive and negative values choose opposite directions. Spacing is measured in world-space millimeters along the selected local axis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Preview") {
                    if let estimate {
                        LabeledContent("Axis", value: "Local \(estimate.axis.rawValue)")
                        LabeledContent("Count", value: localizedCount(estimate.count))
                        LabeledContent("Spacing", value: millimeters(estimate.spacingMillimeters))
                        LabeledContent("Signed total span", value: millimeters(estimate.totalSpanMillimeters))
                        LabeledContent("Total span length", value: millimeters(abs(estimate.totalSpanMillimeters)))
                        transitionRow("Vertices", from: estimate.originalVertexCount, to: estimate.resultingVertexCount)
                        transitionRow("Triangles", from: estimate.originalTriangleCount, to: estimate.resultingTriangleCount)
                        transitionRow("Components", from: estimate.sourceComponentCount, to: estimate.resultingComponentCount)
                        transitionRow("Boundary edges", from: estimate.sourceBoundaryEdgeCount, to: estimate.resultingBoundaryEdgeCount)
                        LabeledContent("Source local bounds", value: dimensions(estimate.sourceLocalBounds))
                        LabeledContent("Result local bounds", value: dimensions(estimate.resultLocalBounds))
                        LabeledContent("Source world bounds", value: dimensions(estimate.sourceWorldBounds))
                        LabeledContent("Result world bounds", value: dimensions(estimate.resultWorldBounds))
                        LabeledContent(
                            "Estimated working memory",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(estimate.estimatedWorkingByteCount),
                                countStyle: .memory))
                        LabeledContent(
                            "Spacing validation tolerance",
                            value: millimeters(estimate.actualSpacingToleranceMillimeters))
                    } else {
                        Text("Enter valid parameters, then calculate a mandatory Preview.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Safety") {
                    Label("This destructive operation replaces the mesh and creates one Undo command.", systemImage: "arrow.uturn.backward.circle")
                    Label("Copy 0 preserves the source vertex and triangle ordering.", systemImage: "list.number")
                    Text("Copies remain detached. No proximity weld, collision detection, overlap repair, or Boolean union is performed.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Very small spacing can be rejected when the stored Float positions cannot preserve the requested world-space distance.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if previewIsStale {
                    Section("Preview Changed") {
                        Label("The mesh, Transform, axis, Count, or Spacing changed. Recalculate before applying.", systemImage: "arrow.clockwise.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let message = parameterError ?? errorMessage ?? model.meshLinearArrayError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Linear Array error: \(message)")
                    }
                }
            }
            .navigationTitle("Linear Array")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate Preview") { recalculatePreview() }
                        .disabled(isBusy || requestedOptions == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isBusy {
                        ProgressView(isApplying ? "Applying Linear Array" : "Analyzing mesh")
                            .accessibilityLabel(isApplying ? "Applying Linear Array" : "Calculating Linear Array preview")
                    }
                    Spacer()
                    Button("Apply Linear Array") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .task { if preview == nil { recalculatePreview() } }
        .onChange(of: axis) { _, _ in invalidateLocalPreview() }
        .onChange(of: countText) { _, _ in invalidateLocalPreview() }
        .onChange(of: spacingText) { _, _ in invalidateLocalPreview() }
        .onDisappear { model.discardMeshLinearArrayPreview() }
    }

    private var estimate: MeshLinearArrayEstimate? { preview?.estimate }
    private var isBusy: Bool { isCalculating || isApplying || model.isMeshLinearArrayRunning }
    private var requestedOptions: MeshLinearArrayOptions? {
        guard let count = Int(countText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let spacing = Double(
                spacingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ",", with: ".")) else { return nil }
        return MeshLinearArrayOptions(axis: axis, count: count, spacingMillimeters: spacing)
    }
    private var parameterError: String? {
        guard let options = requestedOptions else { return "Enter numeric Count and Spacing values." }
        guard (MeshLinearArray.minimumCount...MeshLinearArray.maximumCount).contains(options.count) else {
            return "Count must include the source and be between 2 and 256."
        }
        let magnitude = abs(options.spacingMillimeters)
        guard options.spacingMillimeters.isFinite,
              magnitude >= MeshLinearArray.minimumSpacingMillimeters,
              magnitude <= MeshLinearArray.maximumSpacingMillimeters else {
            return "Spacing must be from -1000 to -0.001 mm or from 0.001 to 1000 mm."
        }
        return nil
    }
    private var previewIsStale: Bool {
        guard let preview, let requestedOptions else { return preview != nil }
        return preview.options != requestedOptions || !model.isMeshLinearArrayPreviewCurrent(preview)
    }
    private var countBinding: Binding<Int> {
        Binding(
            get: { min(max(Int(countText) ?? 2, MeshLinearArray.minimumCount), MeshLinearArray.maximumCount) },
            set: { countText = String($0) })
    }

    private func invalidateLocalPreview() {
        preview = nil
        errorMessage = nil
        model.discardMeshLinearArrayPreview()
    }

    private func recalculatePreview() {
        guard !isBusy, let requestedOptions, parameterError == nil else { return }
        preview = nil
        errorMessage = nil
        isCalculating = true
        Task { @MainActor in
            await Task.yield()
            defer { if self.requestedOptions == requestedOptions { isCalculating = false } }
            do {
                let candidate = try model.previewMeshLinearArray(options: requestedOptions)
                if self.requestedOptions == requestedOptions { preview = candidate }
            } catch {
                if self.requestedOptions == requestedOptions { errorMessage = error.localizedDescription }
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
                _ = try model.applyMeshLinearArray(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func cancel() {
        model.discardMeshLinearArrayPreview()
        dismiss()
    }

    private func transitionRow(_ label: String, from: Int, to: Int) -> some View {
        LabeledContent(label, value: "\(localizedCount(from)) → \(localizedCount(to))")
    }

    private func localizedCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func millimeters(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...6)))) mm"
    }

    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × "
            + "\(LengthFormatter.string(extent.y, fractionDigits: 3)) × "
            + LengthFormatter.string(extent.z, fractionDigits: 3)
    }
}
