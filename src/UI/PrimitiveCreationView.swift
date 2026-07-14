import SwiftUI

struct PrimitiveCreationView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var parameters = PrimitiveParameters()
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Primitive") {
                    Picker("Type", selection: $parameters.kind) {
                        ForEach(PrimitiveKind.allCases) { kind in Text(kind.displayName).tag(kind) }
                    }
                }
                parameterFields
                Section {
                    Text("Creating replaces the current object. Undo restores the previous mesh, Transform, and camera.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Primitive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!parameters.isValid || isCreating)
                }
            }
        }
    }

    @ViewBuilder private var parameterFields: some View {
        switch parameters.kind {
        case .sphere:
            Section("UV Sphere") {
                floatField("Radius", value: $parameters.sphereRadius)
                Stepper("Longitude segments: \(parameters.sphereSegments)",
                        value: $parameters.sphereSegments, in: PrimitiveMeshBuilder.sphereSegmentRange)
                Stepper("Latitude rings: \(parameters.sphereRings)",
                        value: $parameters.sphereRings, in: PrimitiveMeshBuilder.sphereRingRange)
            }
        case .cube:
            Section("Cube") { floatField("Size", value: $parameters.size) }
        case .cylinder:
            Section("Cylinder") {
                floatField("Radius", value: $parameters.cylinderRadius)
                floatField("Height", value: $parameters.cylinderHeight)
                Stepper("Radial segments: \(parameters.cylinderRadialSegments)",
                        value: $parameters.cylinderRadialSegments,
                        in: PrimitiveMeshBuilder.cylinderRadialSegmentRange)
                Stepper("Height segments: \(parameters.cylinderHeightSegments)",
                        value: $parameters.cylinderHeightSegments,
                        in: PrimitiveMeshBuilder.cylinderHeightSegmentRange)
            }
        }
    }

    private func floatField(_ title: String, value: Binding<Float>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
            .keyboardType(.numbersAndPunctuation)
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        do { try model.createPrimitive(parameters: parameters); dismiss() }
        catch { model.status = "Primitive failed: \(error.localizedDescription)"; isCreating = false }
    }
}
