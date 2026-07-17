import Foundation
import SwiftUI
import simd

struct AutosaveStatusView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if model.recoveryDescriptor != nil || model.recoveryInspectionError != nil {
                    model.presentRecovery()
                }
            } label: {
                Label(displayTitle, systemImage: iconName)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityHint(statusHint)

            if case .autosaved(let date) = model.saveState {
                Text(date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if case .failed = model.saveState {
                Button("Retry") { Task { await model.retryAutosave() } }
                    .font(.caption).buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }

    private var iconName: String {
        if model.recoveryInspectionError != nil { return "exclamationmark.triangle" }
        if model.hasRecoveryConflict { return "clock.arrow.circlepath" }
        switch model.saveState {
        case .saved: "checkmark.circle"
        case .unsavedChanges: "circle.dashed"
        case .autosaving: "arrow.triangle.2.circlepath"
        case .autosaved: "externaldrive.badge.checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var displayTitle: String {
        if model.recoveryInspectionError != nil { return "Recovery Error" }
        if model.hasRecoveryConflict { return "Recovery Available" }
        return model.saveState.title
    }

    private var statusHint: String {
        if model.recoveryInspectionError != nil {
            return "The Recovery snapshot could not be inspected. Open for details."
        }
        if model.hasRecoveryConflict {
            return "Unsaved work from another project session is available. Open Recovery to review it."
        }
        switch model.saveState {
        case .saved: "The current project matches the last explicit save."
        case .unsavedChanges: "A recovery snapshot will be written after editing pauses."
        case .autosaving: "A recovery snapshot is being written."
        case .autosaved: "Unsaved changes are protected by a local recovery snapshot."
        case .failed(let message): "Autosave failed. \(message)"
        }
    }
}

struct RecoveryView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Unsaved Work Found") {
                    Text("A local recovery snapshot may contain work that was not explicitly saved. Review it before replacing the current workspace.")
                    if let descriptor = model.recoveryDescriptor { descriptorRows(descriptor) }
                    if let error = model.recoveryInspectionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Recovery error: \(error)")
                    }
                }
                Section {
                    Button("Recover", systemImage: "arrow.clockwise.icloud") {
                        Task { await model.recoverAutosave() }
                    }
                    .disabled(model.recoveryDescriptor == nil || model.isRecoveryOperationInProgress)
                    .accessibilityHint("Replace the current workspace with this recovery snapshot and start a new edit history")

                    Button("Discard", systemImage: "trash", role: .destructive) {
                        confirmsDiscard = true
                    }
                    .disabled(model.isRecoveryOperationInProgress)
                    .accessibilityHint("Permanently delete the recovery snapshot without changing the current workspace")

                    Button("Later", systemImage: "clock") { model.postponeRecovery() }
                        .disabled(model.isRecoveryOperationInProgress)
                        .accessibilityHint("Keep the recovery snapshot and leave the current workspace unchanged")
                }
            }
            .navigationTitle("Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if model.isRecoveryOperationInProgress {
                    ProgressView("Processing Recovery…")
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .confirmationDialog("Discard this recovery snapshot?", isPresented: $confirmsDiscard,
                                titleVisibility: .visible) {
                Button("Discard Recovery", role: .destructive) { Task { await model.discardRecovery() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current workspace will not change, but this recovery snapshot cannot be restored after deletion.")
            }
        }
    }

    @ViewBuilder
    private func descriptorRows(_ descriptor: RecoveryDescriptor) -> some View {
        LabeledContent("Project", value: descriptor.projectName)
        LabeledContent("Saved") { Text(descriptor.capturedAt, format: .dateTime.year().month().day().hour().minute()) }
        LabeledContent("Vertices", value: descriptor.vertexCount.formatted())
        LabeledContent("Triangles", value: descriptor.triangleCount.formatted())
        LabeledContent("Dimensions", value: dimensionsString(descriptor.dimensions))
        LabeledContent("File Size", value: ByteCountFormatter.string(fromByteCount: Int64(descriptor.fileSize),
                                                                      countStyle: .file))
    }

    private func dimensionsString(_ value: SIMD3<Float>) -> String {
        "\(LengthFormatter.string(value.x)) × \(LengthFormatter.string(value.y)) × \(LengthFormatter.string(value.z))"
    }
}
