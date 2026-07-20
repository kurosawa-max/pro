import Foundation
import SwiftUI

struct MeshRadialArrayView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var axis = LinearArrayAxis.z
    @State private var distribution = RadialArrayDistribution.fullCircle
    @State private var direction = RadialArrayDirection.positive
    @State private var countText = "6"
    @State private var sweepText = "180.0"
    @State private var preview: MeshRadialArrayPreview?
    @State private var errorMessage: String?
    @State private var previewRequestCoordinator = TopologyPreviewRequestCoordinator()
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
                    .disabled(isBusy)
                    .accessibilityHint("Chooses the object-local rotation axis through the local origin")

                    Picker("Distribution", selection: $distribution) {
                        ForEach(RadialArrayDistribution.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)

                    HStack {
                        TextField("Count", text: $countText)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Radial Array copy count")
                        Stepper("", value: countBinding, in: MeshRadialArray.minimumCount...MeshRadialArray.maximumCount)
                            .labelsHidden()
                            .accessibilityLabel("Adjust Radial Array copy count")
                    }
                    .disabled(isBusy)
                    Text("Count includes the unchanged source mesh as copy 0.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if distribution == .fullCircle {
                        Picker("Direction", selection: $direction) {
                            ForEach(RadialArrayDirection.allCases) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isBusy)
                        Text("Full Circle uses 360° ÷ Count and does not duplicate the endpoint.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("Signed sweep", text: $sweepText)
                                .keyboardType(.numbersAndPunctuation)
                                .accessibilityLabel("Open Arc signed sweep in degrees")
                            Text("°").foregroundStyle(.secondary)
                        }
                        .disabled(isBusy)
                        Text("Open Arc includes both endpoints. The sweep sign chooses the direction.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Preview") {
                    if let estimate {
                        LabeledContent("Axis", value: "Local \(estimate.axis.rawValue)")
                        LabeledContent("Distribution", value: estimate.distribution.rawValue)
                        LabeledContent("Count", value: localizedCount(estimate.count))
                        LabeledContent("Signed sweep", value: degrees(estimate.effectiveSweepDegrees))
                        LabeledContent("Angular step", value: degrees(estimate.stepDegrees))
                        transitionRow("Vertices", from: estimate.originalVertexCount, to: estimate.resultingVertexCount)
                        transitionRow("Triangles", from: estimate.originalTriangleCount, to: estimate.resultingTriangleCount)
                        transitionRow("Components", from: estimate.sourceComponentCount, to: estimate.resultingComponentCount)
                        transitionRow("Boundary edges", from: estimate.sourceBoundaryEdgeCount, to: estimate.resultingBoundaryEdgeCount)
                        LabeledContent("Source local bounds", value: dimensions(estimate.sourceLocalBounds))
                        LabeledContent("Result local bounds", value: dimensions(estimate.resultLocalBounds))
                        LabeledContent("Source world bounds", value: dimensions(estimate.sourceWorldBounds))
                        LabeledContent("Result world bounds", value: dimensions(estimate.resultWorldBounds))
                        LabeledContent("Maximum radius error", value: millimeters(estimate.maximumRadiusErrorMillimeters))
                        LabeledContent("Maximum axial error", value: millimeters(estimate.maximumAxialErrorMillimeters))
                        LabeledContent("Maximum angle error", value: degrees(estimate.maximumAngularErrorDegrees))
                        LabeledContent("Maximum chord error", value: millimeters(estimate.maximumChordErrorMillimeters))
                        LabeledContent("Validation tolerance", value: millimeters(estimate.validationToleranceMillimeters))
                        LabeledContent(
                            "Estimated working memory",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(estimate.estimatedWorkingByteCount),
                                countStyle: .memory))
                    } else {
                        Text("Enter valid parameters, then calculate the mandatory Preview.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Safety") {
                    Label("This destructive operation replaces the mesh and creates one Undo command.", systemImage: "arrow.uturn.backward.circle")
                    Label("Copy 0 preserves source vertices and triangles exactly.", systemImage: "list.number")
                    Text("Each copy is a world-space rigid rotation around the selected local axis. Copies remain detached; no weld, collision repair, or Boolean union is performed.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Rotational symmetry that creates exact duplicate triangles is rejected.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if previewIsStale {
                    Section("Preview Changed") {
                        Label("The source or parameters changed. Recalculate before applying.", systemImage: "arrow.clockwise.circle")
                    }
                }
                if let message = parameterError ?? errorMessage ?? model.meshRadialArrayError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Radial Array error: \(message)")
                    }
                }
            }
            .navigationTitle("Radial Array")
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
                        ProgressView(isApplying ? "Applying Radial Array" : "Analyzing mesh")
                            .accessibilityLabel(isApplying ? "Applying Radial Array" : "Calculating Radial Array preview")
                    }
                    Spacer()
                    Button("Apply Radial Array") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .task { if preview == nil { recalculatePreview() } }
        .onChange(of: axis) { _, _ in invalidatePreviewRequest() }
        .onChange(of: distribution) { _, _ in invalidatePreviewRequest() }
        .onChange(of: direction) { _, _ in invalidatePreviewRequest() }
        .onChange(of: countText) { _, _ in invalidatePreviewRequest() }
        .onChange(of: sweepText) { _, _ in invalidatePreviewRequest() }
        .onDisappear { invalidatePreviewRequest() }
    }

    private var estimate: MeshRadialArrayEstimate? { preview?.estimate }
    private var isBusy: Bool {
        previewRequestCoordinator.isCalculating || isApplying || model.isMeshRadialArrayRunning
    }
    private var requestedOptions: MeshRadialArrayOptions? {
        guard let count = Int(countText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sweep = Double(
                sweepText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ",", with: ".")) else { return nil }
        return MeshRadialArrayOptions(
            axis: axis,
            distribution: distribution,
            count: count,
            direction: direction,
            sweepDegrees: sweep)
    }
    private var parameterError: String? {
        guard let options = requestedOptions else { return "Enter numeric Count and Sweep values." }
        guard (MeshRadialArray.minimumCount...MeshRadialArray.maximumCount).contains(options.count) else {
            return "Count must include the source and be between 2 and 256."
        }
        if options.distribution == .openArc {
            let magnitude = abs(options.sweepDegrees)
            guard options.sweepDegrees.isFinite,
                  magnitude >= MeshRadialArray.minimumSweepDegrees,
                  magnitude <= MeshRadialArray.maximumSweepDegrees else {
                return "Sweep must be from -359.99° to -0.01° or from 0.01° to 359.99°."
            }
        }
        return nil
    }
    private var previewIsStale: Bool {
        guard let preview, let requestedOptions else { return preview != nil }
        return preview.options != requestedOptions || !model.isMeshRadialArrayPreviewCurrent(preview)
    }
    private var countBinding: Binding<Int> {
        Binding(
            get: { min(max(Int(countText) ?? 6, MeshRadialArray.minimumCount), MeshRadialArray.maximumCount) },
            set: { countText = String($0) })
    }

    private func invalidatePreviewRequest() {
        let requestID = previewRequestCoordinator.invalidate()
        preview = nil
        errorMessage = nil
        model.discardMeshRadialArrayPreview(requestID: requestID)
    }

    private func recalculatePreview() {
        guard !isBusy, let requestedOptions, parameterError == nil else { return }
        let requestID = previewRequestCoordinator.begin()
        preview = nil
        errorMessage = nil
        do {
            try model.beginMeshRadialArrayPreviewRequest(requestID)
        } catch {
            _ = previewRequestCoordinator.finish(requestID)
            errorMessage = error.localizedDescription
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard previewRequestCoordinator.isCurrent(requestID) else {
                model.discardMeshRadialArrayPreview(requestID: requestID)
                return
            }
            do {
                let candidate = try model.makeMeshRadialArrayPreviewCandidate(
                    options: requestedOptions,
                    requestID: requestID)
                guard previewRequestCoordinator.isCurrent(requestID) else {
                    model.discardMeshRadialArrayPreview(requestID: requestID)
                    return
                }
                let accepted = model.completeMeshRadialArrayPreviewRequest(
                    requestID: requestID,
                    candidate: candidate)
                guard previewRequestCoordinator.finish(requestID) else { return }
                preview = accepted ? candidate : nil
                if accepted { errorMessage = nil }
            } catch {
                let accepted = model.failMeshRadialArrayPreviewRequest(
                    requestID: requestID,
                    error: error)
                guard previewRequestCoordinator.finish(requestID) else { return }
                preview = nil
                if accepted { errorMessage = error.localizedDescription }
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
                _ = try model.applyMeshRadialArray(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func cancel() {
        invalidatePreviewRequest()
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

    private func degrees(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...6))))°"
    }

    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × "
            + "\(LengthFormatter.string(extent.y, fractionDigits: 3)) × "
            + LengthFormatter.string(extent.z, fractionDigits: 3)
    }
}
