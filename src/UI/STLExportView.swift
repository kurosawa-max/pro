import Foundation
import SwiftUI

struct STLExportView: View {
    @ObservedObject var model: WorkspaceModel
    let onPrepared: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = STLExportOptions()
    @State private var isExporting = false
    @State private var errorMessage: String?

    private var estimate: Result<STLExportEstimate, Error> {
        Result { try model.stlEstimate(options: options) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Export") {
                    LabeledContent("Format", value: "Binary STL")
                    LabeledContent("Unit", value: "Millimeters")
                    Picker("Origin", selection: $options.origin) {
                        ForEach(STLExportOrigin.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("STL coordinates are exported in millimeters.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Estimate") {
                    if case .success(let value) = estimate {
                        LabeledContent("Dimensions", value: dimensions(value.dimensionsMM))
                        LabeledContent("Triangles", value: value.triangleCount.formatted())
                        LabeledContent("Estimated file size", value: ByteCountFormatter.string(fromByteCount: Int64(value.byteCount), countStyle: .file))
                    } else if case .failure(let error) = estimate {
                        Text(error.localizedDescription).foregroundStyle(.red)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Export STL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { export() } label: { isExporting ? AnyView(ProgressView()) : AnyView(Text("Export")) }
                        .disabled(!canExport || isExporting)
                        .accessibilityLabel("Export Binary STL in millimeters")
                }
            }
        }
    }

    private var canExport: Bool {
        if case .success = estimate { return true }
        return false
    }

    private func dimensions(_ value: SIMD3<Float>) -> String {
        [value.x, value.y, value.z].map { LengthFormatter.string($0) }.joined(separator: " × ")
    }

    private func export() {
        guard !isExporting else { return }
        isExporting = true
        do { onPrepared(try model.stlData(options: options)); dismiss() }
        catch { errorMessage = error.localizedDescription; isExporting = false }
    }
}
