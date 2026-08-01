import Foundation
import SwiftUI

struct EdgeBevelView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var widthText = String(EdgeBevelOptions.defaultWidthMillimeters)
    @State private var preview: EdgeBevelPreview?
    @State private var errorMessage: String?
    @State private var coordinator = TopologyPreviewRequestCoordinator()
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Chamfer") {
                    HStack {
                        TextField("Width", text: $widthText)
                            .keyboardType(.decimalPad)
                            .accessibilityLabel("Edge Bevel width in millimeters")
                        Text("mm").foregroundStyle(.secondary)
                    }
                    .disabled(isBusy)
                    Text("One linear segment. Width is measured in displayed world space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mandatory Preview") {
                    if let estimate = preview?.estimate {
                        LabeledContent("Selected edges", value: count(estimate.selectedEdgeCount))
                        LabeledContent("Affected faces", value: count(estimate.selectedEdgeCount * 2))
                        LabeledContent("Selected endpoints", value: count(estimate.selectedEdgeCount * 2))
                        LabeledContent("Requested width", value: millimeters(preview?.options.widthMillimeters ?? 0))
                        LabeledContent("Maximum safe width", value: millimeters(estimate.maximumSafeWidthMillimeters))
                        LabeledContent("Limiting edge / face", value: "\(estimate.limitingEdgeID) / \(estimate.limitingFaceID)")
                        LabeledContent("Edge length range", value: "\(millimeters(estimate.minimumSelectedEdgeLengthMillimeters)) – \(millimeters(estimate.maximumSelectedEdgeLengthMillimeters))")
                        LabeledContent("Minimum altitude", value: millimeters(estimate.minimumIncidentAltitudeMillimeters))
                        LabeledContent("Maximum measured error", value: millimeters(estimate.maximumMeasuredWidthErrorMillimeters))
                        transition("Vertices", estimate.originalVertexCount, estimate.resultingVertexCount)
                        transition("Triangles", estimate.originalTriangleCount, estimate.resultingTriangleCount)
                        transition("Components", estimate.sourceComponentCount, estimate.resultComponentCount)
                        transition("Boundary edges", estimate.sourceBoundaryEdgeCount, estimate.resultBoundaryEdgeCount)
                        LabeledContent("Result world bounds", value: dimensions(estimate.resultWorldBounds))
                        LabeledContent("Estimated working memory", value: ByteCountFormatter.string(
                            fromByteCount: Int64(estimate.estimatedWorkingByteCount), countStyle: .memory))
                    } else {
                        Text("Enter a valid width, then calculate Preview.").foregroundStyle(.secondary)
                    }
                }
                Section("Safety") {
                    Label("Requires vertex-disjoint manifold interior edges with manifold interior endpoints.", systemImage: "checkmark.shield")
                    Label("The mesh is replaced by one Undoable command.", systemImage: "arrow.uturn.backward.circle")
                    Text("Boundary, adjacent, coplanar, and unsafe-width cases are rejected. Collision and general self-intersection are not detected.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No automatic width clamp is performed.")
                }
                if previewIsStale {
                    Section("Preview Changed") {
                        Label("The source, selection, Transform, or width changed. Recalculate Preview.", systemImage: "arrow.clockwise.circle")
                    }
                }
                if let message = parameterError ?? errorMessage ?? model.edgeBevelError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Edge Bevel error: \(message)")
                    }
                }
            }
            .navigationTitle("Edge Bevel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate Preview") { recalculate() }
                        .disabled(isBusy || requestedOptions == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isBusy {
                        ProgressView(isApplying ? "Applying Edge Bevel" : "Analyzing edges")
                            .accessibilityLabel(isApplying ? "Applying Edge Bevel" : "Calculating Edge Bevel preview")
                    }
                    Spacer()
                    Button("Apply Edge Bevel") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview == nil || previewIsStale || isBusy)
                        .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding().background(.bar)
            }
        }
        .task { if preview == nil { recalculate() } }
        .onChange(of: widthText) { _, _ in invalidate() }
        .onDisappear { invalidate() }
    }

    private var isBusy: Bool { coordinator.isCalculating || isApplying || model.isEdgeBevelRunning }
    private var requestedOptions: EdgeBevelOptions? {
        guard let width = Double(widthText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")) else { return nil }
        return EdgeBevelOptions(widthMillimeters: width)
    }
    private var parameterError: String? {
        guard let width = requestedOptions?.widthMillimeters, width.isFinite else { return "Enter a numeric finite width." }
        guard (EdgeBevelOptions.minimumWidthMillimeters...EdgeBevelOptions.maximumWidthMillimeters).contains(width) else {
            return "Width must be between 0.001 mm and 1000 mm."
        }
        return nil
    }
    private var previewIsStale: Bool {
        guard let preview, let requestedOptions else { return preview != nil }
        return preview.options != requestedOptions || !model.isEdgeBevelPreviewCurrent(preview)
    }

    private func invalidate() {
        let requestID = coordinator.invalidate()
        preview = nil; errorMessage = nil
        model.discardEdgeBevelPreview(requestID: requestID)
    }

    private func recalculate() {
        guard !isBusy, let options = requestedOptions, parameterError == nil else { return }
        let requestID = coordinator.begin()
        preview = nil; errorMessage = nil
        do { try model.beginEdgeBevelPreviewRequest(requestID) }
        catch { _ = coordinator.finish(requestID); errorMessage = error.localizedDescription; return }
        Task { @MainActor in
            await Task.yield()
            guard coordinator.isCurrent(requestID) else { model.discardEdgeBevelPreview(requestID: requestID); return }
            do {
                let candidate = try model.makeEdgeBevelPreviewCandidate(options: options, requestID: requestID)
                guard coordinator.isCurrent(requestID) else { model.discardEdgeBevelPreview(requestID: requestID); return }
                let accepted = model.completeEdgeBevelPreviewRequest(requestID: requestID, candidate: candidate)
                guard coordinator.finish(requestID) else { return }
                preview = accepted ? candidate : nil
                if accepted { errorMessage = nil }
            } catch {
                let accepted = model.failEdgeBevelPreviewRequest(requestID: requestID, error: error)
                guard coordinator.finish(requestID) else { return }
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
            do { _ = try model.applyEdgeBevel(preview: preview); dismiss() }
            catch { errorMessage = error.localizedDescription; self.preview = nil }
        }
    }

    private func cancel() { invalidate(); dismiss() }
    private func transition(_ label: String, _ from: Int, _ to: Int) -> some View {
        LabeledContent(label, value: "\(count(from)) → \(count(to))")
    }
    private func count(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }
    private func millimeters(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...6)))) mm" }
    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let value = bounds.extent
        return "\(LengthFormatter.string(value.x, fractionDigits: 3)) × \(LengthFormatter.string(value.y, fractionDigits: 3)) × \(LengthFormatter.string(value.z, fractionDigits: 3))"
    }
}
