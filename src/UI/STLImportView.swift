import Foundation
import SwiftUI

struct STLImportView: View {
    @ObservedObject var model: WorkspaceModel
    let result: STLImportResult
    let fileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Import Preview") {
                    value("File", fileName)
                    value("Format", result.format.rawValue)
                    value("Triangles", result.sourceTriangleCount.formatted())
                    value("Welded vertices", result.weldedVertexCount.formatted())
                    value("Dimensions", dimensions)
                    value("File size", ByteCountFormatter.string(
                        fromByteCount: Int64(result.sourceByteCount), countStyle: .file))
                }
                Section("Units") {
                    Label("STL has no reliable unit metadata. Forge3D interprets every coordinate as millimeters without scaling.",
                          systemImage: "ruler")
                        .font(.callout)
                        .accessibilityLabel("Unit warning")
                        .accessibilityValue("STL coordinates will be interpreted as millimeters without scaling")
                }
                if let errorMessage {
                    Section("Error") { Text(errorMessage).foregroundStyle(.red) }
                }
                if model.isSTLImporting {
                    Section { ProgressView("Importing…") }
                }
            }
            .navigationTitle("Import STL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { install() }
                        .disabled(model.isSTLImporting)
                        .accessibilityHint("Replace the current mesh and keep the import as one undo step")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var dimensions: String {
        let extent = result.bounds.extent
        return "\(LengthFormatter.string(extent.x)) × \(LengthFormatter.string(extent.y)) × \(LengthFormatter.string(extent.z))"
    }

    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
            .accessibilityElement(children: .combine)
    }

    private func install() {
        do {
            try model.installSTLImport(result, fileName: fileName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            model.status = "Import failed: \(error.localizedDescription)"
        }
    }
}
