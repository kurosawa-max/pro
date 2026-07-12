import SwiftUI
import simd

struct TransformPanel: View {
    @ObservedObject var model: WorkspaceModel
    @State private var isExpanded = false
    @State private var uniformScale = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                Label("Transform", systemImage: "move.3d")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        vectorSection("Position", values: translationBindings, step: 0.1)
                        vectorSection("Rotation °", values: rotationBindings, step: 5)
                        Toggle("Uniform Scale", isOn: $uniformScale).font(.caption)
                        vectorSection("Scale", values: scaleBindings, step: 0.1)
                        Button("Reset Transform", systemImage: "arrow.counterclockwise") { model.resetTransform() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(10)
                }
                .frame(width: 300)
                .frame(maxHeight: 340)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func vectorSection(_ title: String, values: [Binding<Float>], step: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            ForEach(Array(zip(["X", "Y", "Z"], values)), id: \.0) { item in
                HStack {
                    Text(item.0).frame(width: 14)
                    TextField(item.0, value: item.1, format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                    Stepper("", value: item.1, step: step).labelsHidden()
                }
            }
        }
    }

    private var translationBindings: [Binding<Float>] {
        (0..<3).map { axis in Binding(
            get: { model.objectTransform.translation[axis] },
            set: { value in var vector = model.objectTransform.translation; vector[axis] = value; model.updateTranslation(vector) }
        ) }
    }

    private var rotationBindings: [Binding<Float>] {
        (0..<3).map { axis in Binding(
            get: { model.objectTransform.rotationDegrees[axis] },
            set: { value in var vector = model.objectTransform.rotationDegrees; vector[axis] = value; model.updateRotationDegrees(vector) }
        ) }
    }

    private var scaleBindings: [Binding<Float>] {
        (0..<3).map { axis in Binding(
            get: { model.objectTransform.scale[axis] },
            set: { value in
                var vector = model.objectTransform.scale
                if uniformScale { vector = SIMD3<Float>(repeating: value) } else { vector[axis] = value }
                model.updateScale(vector)
            }
        ) }
    }
}
