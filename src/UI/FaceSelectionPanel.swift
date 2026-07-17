import SwiftUI

struct FaceSelectionPanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Face Selection", systemImage: "triangle.fill")
                    .font(.headline)
                Text("Selected Faces: \(model.selectedFaceCount)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel("Selected faces")
                    .accessibilityValue("\(model.selectedFaceCount)")
                Text("Total Faces: \(model.totalFaceCount)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel("Total faces")
                    .accessibilityValue("\(model.totalFaceCount)")
                Spacer(minLength: 8)
                if model.isFaceSelectionProcessing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Face selection processing")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { operationPicker; commandButtons }
                VStack(alignment: .leading, spacing: 8) { operationPicker; commandButtons }
            }

            Text("Pencil taps select the frontmost triangle. Finger gestures keep controlling the camera. Face selection is not saved or added to Undo history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.faceSelectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Face selection error: \(error)")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var operationPicker: some View {
        Picker("Selection Operation", selection: Binding(
            get: { model.faceSelectionOperation },
            set: { model.setFaceSelectionOperation($0) }
        )) {
            ForEach(FaceSelectionOperation.allCases, id: \.self) { operation in
                Text(operation.rawValue).tag(operation)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 440)
        .disabled(!model.isFaceSelectionInteractionEnabled)
        .accessibilityHint("Choose how a Pencil tap changes the face selection")
    }

    private var commandButtons: some View {
        HStack(spacing: 8) {
            Button("Clear", systemImage: "xmark.circle") { model.clearFaceSelection() }
                .disabled(!model.isFaceSelectionInteractionEnabled || model.selectedFaceCount == 0)
                .accessibilityHint("Deselect all faces")
            Button("Select All", systemImage: "checkmark.circle") { model.selectAllFaces() }
                .disabled(!model.isFaceSelectionInteractionEnabled
                          || model.totalFaceCount == 0
                          || model.selectedFaceCount == model.totalFaceCount)
                .accessibilityHint("Select every triangle face")
            Button("Invert", systemImage: "circle.lefthalf.filled") { model.invertFaceSelection() }
                .disabled(!model.isFaceSelectionInteractionEnabled || model.totalFaceCount == 0)
                .accessibilityHint("Swap selected and unselected faces")
            Button("Select Connected", systemImage: "link") { model.selectConnectedFaces() }
                .disabled(!model.isFaceSelectionInteractionEnabled || model.selectedFaceCount == 0)
                .accessibilityHint("Add every face connected to the current selection by shared edges")
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
    }
}
