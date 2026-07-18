import SwiftUI

struct FaceSelectionPanel: View {
    @ObservedObject var model: WorkspaceModel
    var onExtrude: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Face Selection", systemImage: "triangle.fill")
                .font(.headline)
            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 6) {
                Text("Selected Faces: \(model.selectedFaceCount)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel("Selected faces")
                    .accessibilityValue("\(model.selectedFaceCount)")
                Text("Total Faces: \(model.totalFaceCount)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel("Total faces")
                    .accessibilityValue("\(model.totalFaceCount)")
                if model.isFaceSelectionProcessing {
                    ProgressView("Selecting connected faces")
                        .controlSize(.small)
                        .accessibilityLabel("Face selection processing")
                }
            }

            operationPicker
            commandButtons

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
        .frame(maxWidth: FaceSelectionPanelLayout.maximumWidth)
        .accessibilityElement(children: .contain)
    }

    private var summaryColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: FaceSelectionPanelLayout.summaryMinimumWidth(
                accessibilityText: dynamicTypeSize.isAccessibilitySize)),
            spacing: 8,
            alignment: .leading
        )]
    }

    private var operationPicker: some View {
        Group {
            if horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
                operationPickerContent.pickerStyle(.menu)
            } else {
                operationPickerContent
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 440)
            }
        }
        .disabled(!model.isFaceSelectionInteractionEnabled)
        .accessibilityHint("Choose how a Pencil tap changes the face selection")
    }

    private var operationPickerContent: some View {
        Picker("Selection Operation", selection: Binding(
            get: { model.faceSelectionOperation },
            set: { model.setFaceSelectionOperation($0) }
        )) {
            ForEach(FaceSelectionOperation.allCases, id: \.self) { operation in
                Text(operation.rawValue).tag(operation)
            }
        }
    }

    private var commandButtons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(
            minimum: FaceSelectionPanelLayout.commandMinimumWidth(
                accessibilityText: dynamicTypeSize.isAccessibilitySize)),
            spacing: 8)], alignment: .leading, spacing: 8) {
            Button("Clear", systemImage: "xmark.circle") { model.clearFaceSelection() }
                .disabled(!model.isFaceSelectionInteractionEnabled || model.selectedFaceCount == 0)
                .accessibilityHint("Deselect all faces")
                .frame(maxWidth: .infinity)
            Button("Select All", systemImage: "checkmark.circle") { model.selectAllFaces() }
                .disabled(!model.isFaceSelectionInteractionEnabled
                          || model.totalFaceCount == 0
                          || model.selectedFaceCount == model.totalFaceCount)
                .accessibilityHint("Select every triangle face")
                .frame(maxWidth: .infinity)
            Button("Invert", systemImage: "circle.lefthalf.filled") { model.invertFaceSelection() }
                .disabled(!model.isFaceSelectionInteractionEnabled || model.totalFaceCount == 0)
                .accessibilityHint("Swap selected and unselected faces")
                .frame(maxWidth: .infinity)
            Button("Select Connected", systemImage: "link") { model.selectConnectedFaces() }
                .disabled(!model.isFaceSelectionInteractionEnabled || model.selectedFaceCount == 0)
                .accessibilityHint("Add every face connected to the current selection by shared edges")
                .frame(maxWidth: .infinity)
            Button("Extrude…", systemImage: "square.3.layers.3d") { onExtrude() }
                .disabled(!model.canBeginFaceExtrude)
                .accessibilityHint("Preview a world-space millimeter extrusion of the selected face region")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
    }
}

enum FaceSelectionPanelLayout {
    static let maximumWidth: CGFloat = 680

    static func commandMinimumWidth(accessibilityText: Bool) -> CGFloat {
        accessibilityText ? 240 : 148
    }

    static func summaryMinimumWidth(accessibilityText: Bool) -> CGFloat {
        accessibilityText ? 240 : 160
    }
}
