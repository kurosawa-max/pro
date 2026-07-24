import SwiftUI

struct EdgeSelectionPanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { content }
                VStack(alignment: .leading, spacing: 8) { content }
            }
            .padding(10)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edge Selection").font(.headline)
            Text("\(model.selectedEdgeCount) selected of \(model.totalEdgeCount)")
                .font(.caption.monospacedDigit())
                .accessibilityLabel("Selected edges \(model.selectedEdgeCount), total edges \(model.totalEdgeCount)")
            if let table = model.meshEdgeTable {
                Text("Boundary \(table.boundaryEdgeCount) · Manifold \(table.manifoldEdgeCount) · Non-manifold \(table.nonManifoldEdgeCount)")
                    .font(.caption2)
            }
        }

        Picker("Selection Operation", selection: Binding(
            get: { model.edgeSelectionOperation },
            set: { model.setEdgeSelectionOperation($0) })) {
            ForEach(EdgeSelectionOperation.allCases, id: \.self) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 280)

        Group {
            Button("Clear", systemImage: "xmark.circle") { model.clearEdgeSelection() }
                .disabled(model.selectedEdgeCount == 0)
            Button("All", systemImage: "checkmark.circle") { model.selectAllEdges() }
                .disabled(model.totalEdgeCount == 0 || model.selectedEdgeCount == model.totalEdgeCount)
            Button("Invert", systemImage: "circle.lefthalf.filled") { model.invertEdgeSelection() }
                .disabled(model.totalEdgeCount == 0)
            Button("Select Connected Edges", systemImage: "point.3.connected.trianglepath.dotted") {
                model.selectConnectedEdges()
            }
            .disabled(model.selectedEdgeCount == 0)
        }
        .buttonStyle(.bordered)

        VStack(alignment: .leading, spacing: 2) {
            Text("Picks an edge of the nearest visible triangle within 14 points.")
            Text("Silhouette-only, hidden, through, loop, and ring selection are not included.")
            Text("Runtime only; topology changes clear edge selection.")
            if let error = model.edgeSelectionError {
                Text(error).foregroundStyle(.red).accessibilityLabel("Edge selection error: \(error)")
            }
        }
        .font(.caption2)
        .frame(maxWidth: 360, alignment: .leading)
    }
}
