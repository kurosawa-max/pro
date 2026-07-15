import Foundation
import SwiftUI

struct MeshSubdivisionView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private var estimate: Result<SubdivisionEstimate, Error> {
        Result { try model.subdivisionEstimate() }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Linear Triangle Subdivision") {
                    Text("Each triangle becomes four. Existing vertices stay in place and shared edges reuse one midpoint.")
                    if case .success(let value) = estimate {
                        LabeledContent("Current", value: "\(value.sourceVertices) vertices / \(value.sourceTriangles) triangles")
                        LabeledContent("After", value: "\(value.resultVertices) vertices / \(value.resultTriangles) triangles")
                        LabeledContent("Estimated working memory", value: ByteCountFormatter.string(fromByteCount: Int64(value.estimatedWorkingBytes), countStyle: .memory))
                        if !isAllowed(value) { Text("This operation exceeds the safe mesh limit.").foregroundStyle(.red) }
                    } else if case .failure(let error) = estimate {
                        Text(error.localizedDescription).foregroundStyle(.red)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Subdivide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { subdivide() } label: {
                        if isProcessing { ProgressView() } else { Text("Subdivide") }
                    }
                    .disabled(!canRun || isProcessing)
                    .accessibilityLabel("Subdivide mesh once")
                    .accessibilityHint("Each triangle becomes four")
                }
            }
        }
    }

    private var canRun: Bool {
        guard case .success(let value) = estimate else { return false }
        return isAllowed(value)
    }

    private func isAllowed(_ value: SubdivisionEstimate) -> Bool {
        value.resultVertices <= MeshSubdivision.maximumVertices && value.resultTriangles <= MeshSubdivision.maximumTriangles
    }

    private func subdivide() {
        guard !isProcessing else { return }
        isProcessing = true
        do { try model.subdivideMeshOnce(); dismiss() }
        catch { errorMessage = error.localizedDescription; isProcessing = false }
    }
}
