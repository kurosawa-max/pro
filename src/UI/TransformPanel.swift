import SwiftUI
import simd

struct TransformPanel: View {
    private enum Field: Hashable {
        case position(Int)
        case rotation(Int)
        case scale(Int)
    }

    @ObservedObject var model: WorkspaceModel
    @State private var isExpanded = false
    @State private var uniformScale = true
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded { focusedField = nil }
                isExpanded.toggle()
            } label: {
                Label("Transform", systemImage: "move.3d")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        vectorSection("Position (mm)", values: translationBindings,
                                      fields: (0..<3).map(Field.position), step: 0.1)
                        vectorSection("Rotation °", values: rotationBindings,
                                      fields: (0..<3).map(Field.rotation), step: 5)
                        Toggle("Uniform Scale", isOn: $uniformScale).font(.caption)
                        vectorSection("Scale", values: scaleBindings,
                                      fields: (0..<3).map(Field.scale), step: 0.1)
                        Button("Reset Transform", systemImage: "arrow.counterclockwise") { model.resetTransform() }
                            .buttonStyle(.bordered).controlSize(.small)
                        dimensionsSection
                    }
                    .padding(10)
                }
                .frame(width: 300)
                .frame(maxHeight: 340)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onChange(of: focusedField) { _, newValue in
            model.commitTransformPanelTransaction()
            if newValue != nil { model.beginTransformPanelTransaction() }
        }
        .onDisappear { model.commitTransformPanelTransaction() }
    }

    private var dimensionsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dimensions").font(.caption.bold())
            ForEach(0..<3, id: \.self) { axis in
                let label = ["X", "Y", "Z"][axis]
                let value = model.objectDimensions.map { LengthFormatter.string($0.worldSize[axis]) } ?? "—"
                LabeledContent(label, value: value)
                    .font(.caption)
                    .accessibilityLabel("Dimension \(label)")
                    .accessibilityValue(value)
            }
        }
    }

    private func vectorSection(_ title: String, values: [Binding<Float>],
                               fields: [Field], step: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            ForEach(values.indices, id: \.self) { index in
                HStack {
                    let label = ["X", "Y", "Z"][index]
                    Text(label).frame(width: 14)
                    TextField(label, value: values[index], format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: fields[index])
                        .onSubmit { focusedField = nil }
                    Stepper("", value: values[index], step: step).labelsHidden()
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
