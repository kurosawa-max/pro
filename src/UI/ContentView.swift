import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var showImporter = false
    @State private var showProjectExporter = false
    @State private var showSTLExporter = false
    @State private var projectExport = ForgeFile(data: Data())
    @State private var stlExport = STLFile(data: Data())

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                MetalCanvas(model: model).ignoresSafeArea(edges: .bottom)
                if let p = model.hoverLocation {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: CGFloat(model.brushSettings.radius * 280), height: CGFloat(model.brushSettings.radius * 280))
                        .position(p).allowsHitTesting(false)
                }
                VStack { Spacer(); controls.padding() }
                TransformPanel(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.top, 56)
                #if DEBUG
                PerformanceHUD(profiler: model.profiler)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                BenchmarkPanel(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
                    .padding(.leading, 8)
                #endif
            }
            .navigationTitle("Forge3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Open", systemImage: "folder") { showImporter = true }
                    Button("Save", systemImage: "square.and.arrow.down") { saveProject() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Picker("Gizmo Mode", selection: Binding(get: { model.gizmoMode },
                                                            set: { model.setGizmoMode($0) })) {
                        ForEach(GizmoMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    #if DEBUG
                    .disabled(model.isBenchmarkRunning)
                    #endif
                    Toggle(isOn: Binding(get: { model.showsTranslationGizmo },
                                         set: { model.setTranslationGizmoVisible($0) })) {
                        Label("Gizmo", systemImage: "move.3d")
                    }
                    #if DEBUG
                    .disabled(model.isBenchmarkRunning)
                    #endif
                    Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                    Button("STL", systemImage: "square.and.arrow.up") { exportSTL() }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.forge3D]) { result in
            guard case .success(let url) = result else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }
            do { model.load(data: try Data(contentsOf: url, options: .mappedIfSafe)) }
            catch { model.status = "Open failed: \(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $showProjectExporter, document: projectExport, contentType: .forge3D, defaultFilename: "Untitled.forge3d") { result in
            if case .failure(let error) = result { model.status = "Save failed: \(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $showSTLExporter, document: stlExport, contentType: .stl, defaultFilename: "Forge3D.stl") { result in
            if case .failure(let error) = result { model.status = "Export failed: \(error.localizedDescription)" }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Brush", selection: $model.brush) {
                ForEach(BrushKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360)
            VStack(alignment: .leading) {
                Text("Radius").font(.caption)
                Slider(value: $model.brushSettings.radius, in: 0.05...0.75)
            }.frame(width: 150)
            Text(model.status).font(.caption).lineLimit(1)
        }
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func saveProject() {
        do { projectExport = ForgeFile(data: try model.projectData()); showProjectExporter = true }
        catch { model.status = "Save failed: \(error.localizedDescription)" }
    }
    private func exportSTL() {
        do { stlExport = STLFile(data: try model.stlData()); showSTLExporter = true }
        catch { model.status = "Export failed: \(error.localizedDescription)" }
    }
}

struct ForgeFile: FileDocument {
    static var readableContentTypes: [UTType] { [.forge3D] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct STLFile: FileDocument {
    static var readableContentTypes: [UTType] { [.stl] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension UTType { static let stl = UTType(filenameExtension: "stl") ?? .data }
