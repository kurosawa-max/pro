import SwiftUI

struct VertexSelectionPanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Vertex Selection").font(.headline)
                Text("\(model.selectedVertexCount) selected of \(model.totalVertexCount)")
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel(
                        "Selected vertices \(model.selectedVertexCount), total vertices \(model.totalVertexCount)")
                    .accessibilityIdentifier("vertex-selection-count")

                Picker("Selection Operation", selection: Binding(
                    get: { model.vertexSelectionOperation },
                    set: { model.setVertexSelectionOperation($0) })) {
                    ForEach(VertexSelectionOperation.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("vertex-selection-operation")

                ViewThatFits(in: .horizontal) {
                    HStack { commandButtons }
                    VStack(alignment: .leading) { commandButtons }
                }
                .buttonStyle(.bordered)

                Text("Connected follows mesh edges and applies the selected operation to every vertex in each seeded component.")
                    .font(.caption2)
                Text("Picks a vertex of the nearest visible triangle within 16 points. Runtime only; topology changes clear selection.")
                    .font(.caption2)
                Text("In Move mode, drag the world-space gizmo to preview and commit one non-topology vertex move. Cancel leaves the project unchanged.")
                    .font(.caption2)
                Text("In Rotate mode, drag a world-axis ring around the selected bounds center. Multi-turn rotation is supported and remains a vertex-only edit.")
                    .font(.caption2)
                Text(hoverDescription).font(.caption2)
                    .accessibilityLabel(hoverDescription)
                if let error = model.vertexSelectionError {
                    Text(error).foregroundStyle(.red)
                        .accessibilityLabel("Vertex selection error: \(error)")
                }
                if let error = model.vertexTranslateError {
                    Text(error).foregroundStyle(.red)
                        .accessibilityLabel("Selected vertex move error: \(error)")
                }
                if let error = model.vertexRotateError {
                    Text(error).foregroundStyle(.red)
                        .accessibilityLabel("Selected vertex rotation error: \(error)")
                }
            }
            .padding(10)
        }
        .frame(maxWidth: 440, maxHeight: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var commandButtons: some View {
        Button("Clear", systemImage: "xmark.circle") { model.clearVertexSelection() }
            .disabled(model.selectedVertexCount == 0)
            .accessibilityIdentifier("vertex-selection-clear")
        Button("All", systemImage: "checkmark.circle") { model.selectAllVertices() }
            .disabled(model.totalVertexCount == 0 || model.selectedVertexCount == model.totalVertexCount)
            .accessibilityIdentifier("vertex-selection-all")
        Button("Invert", systemImage: "circle.lefthalf.filled") { model.invertVertexSelection() }
            .disabled(model.totalVertexCount == 0)
            .accessibilityIdentifier("vertex-selection-invert")
        Button("Connected", systemImage: "point.3.connected.trianglepath.dotted") {
            model.selectConnectedVertices()
        }
        .disabled(model.selectedVertexCount == 0)
        .accessibilityIdentifier("vertex-selection-connected")
    }

    private var hoverDescription: String {
        if let id = model.effectiveVertexHoverID { return "Hovered vertex \(id)" }
        if let id = model.vertexHover.vertexID { return "Vertex \(id) is selected" }
        return "No hovered vertex"
    }
}
