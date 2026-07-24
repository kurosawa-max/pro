import Foundation
import SwiftUI

struct MeshExactSeamEditView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var operation = MeshSeamOperation.splitRegion
    @State private var preview: MeshSeamEditPreview?
    @State private var errorMessage: String?
    @State private var coordinator = TopologyPreviewRequestCoordinator()
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Operation") {
                    Picker("Merge or Split", selection: $operation) {
                        ForEach(MeshSeamOperation.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)
                    .accessibilityHint("Choose whether to detach the selected region or weld an exact detached seam")
                    Text(operation == .splitRegion
                         ? "Duplicates only the selected side of one simple internal boundary loop. No cap, wall, or gap is created."
                         : "Welds one complete selected component to one bit-exact coincident boundary loop. This is not a distance weld or Boolean union.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Preview") {
                    if let estimate = preview?.estimate {
                        LabeledContent("Selected faces", value: number(estimate.selectedFaceCount))
                        LabeledContent("Host component faces", value: number(estimate.hostComponentFaceCount))
                        if let count = estimate.counterpartComponentFaceCount {
                            LabeledContent("Counterpart faces", value: number(count))
                        }
                        LabeledContent("Seam vertices", value: number(estimate.seamVertexCount))
                        LabeledContent("Seam edges", value: number(estimate.seamEdgeCount))
                        transition("Vertices", estimate.originalVertexCount, estimate.resultingVertexCount)
                        transition("Triangles", estimate.originalTriangleCount, estimate.resultingTriangleCount)
                        transition("Components", estimate.sourceComponentCount, estimate.resultingComponentCount)
                        transition("Boundary edges", estimate.sourceBoundaryEdgeCount, estimate.resultingBoundaryEdgeCount)
                        LabeledContent("Source bounds", value: dimensions(estimate.sourceBounds))
                        LabeledContent("Result bounds", value: dimensions(estimate.resultBounds))
                        LabeledContent("Estimated working memory", value: ByteCountFormatter.string(
                            fromByteCount: Int64(estimate.estimatedWorkingByteCount), countStyle: .memory))
                    } else {
                        Text("Calculate the mandatory Preview before applying.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Safety") {
                    Label("This destructive topology edit creates one Undo command.", systemImage: "arrow.uturn.backward.circle")
                    if operation == .splitRegion {
                        Label("The result contains an open, coincident seam and may not be ready for 3D printing.", systemImage: "exclamationmark.triangle")
                        Text("The two seam boundaries remain at the same visible position. Use Merge Exact Seam or an external repair workflow before printing.")
                    } else {
                        Label("Only one-to-one bit-exact local Float positions are paired; +0 and -0 are equivalent.", systemImage: "equal.circle")
                        Text("Ambiguous candidates, unmatched edges, same-direction winding, and non-manifold results are rejected without repair.")
                    }
                }

                if isStale {
                    Section("Preview Changed") {
                        Label("The mesh, Transform, Face Selection, or operation changed. Recalculate before applying.", systemImage: "arrow.clockwise.circle")
                    }
                }
                if let message = errorMessage ?? model.meshSeamEditError {
                    Section("Cannot Apply") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Merge or Split error: \(message)")
                    }
                }
            }
            .navigationTitle("Merge / Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate Preview") { recalculate() }.disabled(isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isBusy {
                        ProgressView(isApplying ? "Applying topology edit" : "Analyzing seam")
                            .accessibilityLabel(isApplying ? "Applying Merge or Split" : "Calculating seam Preview")
                    }
                    Spacer()
                    Button(operation == .splitRegion ? "Apply Split Region" : "Apply Merge Exact Seam") {
                        apply()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview == nil || isStale || isBusy)
                    .accessibilityHint("Replaces the mesh and records one Undo command")
                }
                .padding()
                .background(.bar)
            }
        }
        .task { if preview == nil { recalculate() } }
        .onChange(of: operation) { _, _ in invalidate() }
        .onDisappear { invalidate() }
    }

    private var isBusy: Bool {
        coordinator.isCalculating || isApplying || model.isMeshSeamEditRunning
    }

    private var isStale: Bool {
        guard let preview else { return false }
        return preview.operation != operation || !model.isMeshSeamEditPreviewCurrent(preview)
    }

    private func invalidate() {
        let requestID = coordinator.invalidate()
        preview = nil
        errorMessage = nil
        model.discardMeshSeamEditPreview(requestID: requestID)
    }

    private func recalculate() {
        guard !isBusy else { return }
        let requestedOperation = operation
        let requestID = coordinator.begin()
        preview = nil
        errorMessage = nil
        do {
            try model.beginMeshSeamEditPreviewRequest(requestID)
        } catch {
            _ = coordinator.finish(requestID)
            errorMessage = error.localizedDescription
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard coordinator.isCurrent(requestID) else {
                model.discardMeshSeamEditPreview(requestID: requestID)
                return
            }
            do {
                let candidate = try model.makeMeshSeamEditPreviewCandidate(
                    operation: requestedOperation, requestID: requestID)
                guard coordinator.isCurrent(requestID), operation == requestedOperation else {
                    model.discardMeshSeamEditPreview(requestID: requestID)
                    return
                }
                let accepted = model.completeMeshSeamEditPreviewRequest(
                    requestID: requestID, candidate: candidate)
                guard coordinator.finish(requestID) else { return }
                preview = accepted ? candidate : nil
            } catch {
                let accepted = model.failMeshSeamEditPreviewRequest(
                    requestID: requestID, error: error)
                guard coordinator.finish(requestID) else { return }
                preview = nil
                if accepted { errorMessage = error.localizedDescription }
            }
        }
    }

    private func apply() {
        guard let preview, !isStale, !isBusy else { return }
        isApplying = true
        Task { @MainActor in
            await Task.yield()
            defer { isApplying = false }
            do {
                _ = try model.applyMeshSeamEdit(preview: preview)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                self.preview = nil
            }
        }
    }

    private func cancel() { invalidate(); dismiss() }

    private func transition(_ title: String, _ before: Int, _ after: Int) -> some View {
        LabeledContent(title, value: "\(number(before)) → \(number(after))")
    }

    private func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func dimensions(_ bounds: AxisAlignedBoundingBox) -> String {
        let extent = bounds.extent
        return "\(LengthFormatter.string(extent.x, fractionDigits: 3)) × "
            + "\(LengthFormatter.string(extent.y, fractionDigits: 3)) × "
            + LengthFormatter.string(extent.z, fractionDigits: 3)
    }
}
