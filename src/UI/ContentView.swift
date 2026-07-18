import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showSTLImporter = false
    @State private var showSTLImportConfirmation = false
    @State private var showProjectExporter = false
    @State private var showSTLExporter = false
    @State private var showSTLOptions = false
    @State private var showPrimitiveCreator = false
    @State private var showSubdivision = false
    @State private var showMeshDiagnostics = false
    @State private var showFaceExtrude = false
    @State private var showFaceInset = false
    @State private var projectExport = ForgeFile(data: Data())
    @State private var stlExport = STLFile(data: Data())
    @State private var stlImportResult: STLImportResult?
    @State private var stlImportFileName = "STL"
    @State private var projectSaveSnapshot: ProjectAutosaveSnapshot?
    @State private var confirmsOpeningWithUnsavedChanges = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                MetalCanvas(model: model, isInputSuppressed: isWorkspaceModalPresented)
                    .ignoresSafeArea(edges: .bottom)
                if model.interactionMode == .sculpt, let p = model.hoverLocation {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: brushCursorDiameter, height: brushCursorDiameter)
                        .position(p).allowsHitTesting(false)
                }
                if model.interactionMode == .sculpt {
                    VStack {
                        Spacer()
                        controls.padding()
                    }
                }
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.interactionMode == .faceSelect {
                    FaceSelectionPanel(model: model, onExtrude: beginFaceExtrude, onInset: beginFaceInset)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            }
            .navigationTitle("Forge3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Open", systemImage: "folder") { requestOpenProject() }
                    Button("Import STL", systemImage: "square.and.arrow.down") { showSTLImporter = true }
                        .disabled(importControlsDisabled)
                        .accessibilityHint("Choose a Binary or ASCII STL file to preview")
                    Button("Save", systemImage: "square.and.arrow.down") { saveProject() }
                    Button("New Primitive", systemImage: "cube") { showPrimitiveCreator = true }
                    Button("Subdivide", systemImage: "triangle") { showSubdivision = true }
                        .accessibilityHint("Each triangle becomes four")
                    #if DEBUG
                    .disabled(model.isBenchmarkRunning)
                    #endif
                    Button("Diagnostics", systemImage: "stethoscope") { showMeshDiagnostics = true }
                        .accessibilityHint("Inspect mesh topology, dimensions, and printability warnings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Picker("Editing Mode", selection: Binding(get: { model.interactionMode },
                                                               set: { model.setInteractionMode($0) })) {
                        ForEach(WorkspaceInteractionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityHint("Switch between sculpting and triangle face selection")
                    #if DEBUG
                    .disabled(model.isBenchmarkRunning)
                    #endif
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
                        .disabled(!model.canUndo || model.isGizmoDragging)
                        .keyboardShortcut("z", modifiers: .command)
                    Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                        .disabled(!model.canRedo || model.isGizmoDragging)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Button("STL", systemImage: "square.and.arrow.up") { beginSTLExport() }
                    #if DEBUG
                    .disabled(model.isBenchmarkRunning)
                    #endif
                }
            }
        }
        .task { await model.inspectRecoveryOnLaunch() }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active: await model.handleLifecycleActive()
                case .inactive, .background: await model.handleLifecycleInactiveOrBackground()
                @unknown default: break
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.forge3D]) { result in
            guard case .success(let url) = result else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }
            do {
                try model.loadProject(data: Data(contentsOf: url, options: .mappedIfSafe),
                                      projectName: url.deletingPathExtension().lastPathComponent)
                Task { await model.inspectRecoveryOnLaunch(force: true) }
            }
            catch { model.status = "Open failed: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showSTLImporter, allowedContentTypes: [.stl]) { result in
            previewSTLImport(result)
        }
        .sheet(isPresented: $showPrimitiveCreator) { PrimitiveCreationView(model: model) }
        .sheet(isPresented: $showSubdivision) { MeshSubdivisionView(model: model) }
        .sheet(isPresented: $showMeshDiagnostics) { MeshDiagnosticsView(model: model) }
        .sheet(isPresented: $showFaceExtrude, onDismiss: { model.discardFaceExtrudePreview() }) {
            FaceExtrudeView(model: model)
        }
        .sheet(isPresented: $showFaceInset, onDismiss: { model.discardFaceInsetPreview() }) {
            FaceInsetView(model: model)
        }
        .sheet(isPresented: $showSTLImportConfirmation, onDismiss: { stlImportResult = nil }) {
            if let stlImportResult {
                STLImportView(model: model, result: stlImportResult, fileName: stlImportFileName)
            }
        }
        .sheet(isPresented: $showSTLOptions) {
            STLExportView(model: model) { data in
                stlExport = STLFile(data: data)
                showSTLExporter = true
            }
        }
        .sheet(isPresented: Binding(get: { model.isRecoveryPromptPresented }, set: { visible in
            if !visible { model.postponeRecovery() }
        })) {
            RecoveryView(model: model)
        }
        .fileExporter(isPresented: $showProjectExporter, document: projectExport, contentType: .forge3D,
                      defaultFilename: "\(model.currentProjectName).forge3d") { result in
            let snapshot = projectSaveSnapshot
            projectSaveSnapshot = nil
            switch result {
            case .success(let url):
                if let snapshot { Task { await model.explicitSaveSucceeded(snapshot, url: url) } }
            case .failure(let error):
                if (error as? CocoaError)?.code == .userCancelled { model.explicitSaveCancelled() }
                else { model.explicitSaveFailed(error) }
            }
        }
        .fileExporter(isPresented: $showSTLExporter, document: stlExport, contentType: .stl, defaultFilename: "Forge3D.stl") { result in
            if case .failure(let error) = result { model.status = "Export failed: \(error.localizedDescription)" }
        }
        .alert("Protect Unsaved Changes?", isPresented: $confirmsOpeningWithUnsavedChanges) {
            Button("Continue") {
                Task { if await model.prepareForProjectLoad() { showImporter = true } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forge3D will write a Recovery snapshot before opening another project. The existing project will not be overwritten.")
        }
    }

    private var isWorkspaceModalPresented: Bool {
        showImporter || showSTLImporter || showSTLImportConfirmation
            || showProjectExporter || showSTLExporter || showSTLOptions
            || showPrimitiveCreator || showSubdivision || showMeshDiagnostics
            || showFaceExtrude || showFaceInset
            || confirmsOpeningWithUnsavedChanges || model.isRecoveryPromptPresented
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Brush", selection: $model.brush) {
                ForEach(BrushKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 520)
            HStack(spacing: 4) {
                Text("Symmetry").font(.caption)
                symmetryButton("X", axis: \.x)
                symmetryButton("Y", axis: \.y)
                symmetryButton("Z", axis: \.z)
            }
            .disabled(symmetryControlsDisabled)
            VStack(alignment: .leading) {
                Text("Radius: \(LengthFormatter.string(model.brushSettings.radius, fractionDigits: 1))").font(.caption)
                Slider(value: $model.brushSettings.radius, in: 0.1...25)
            }.frame(width: 150)
            AutosaveStatusView(model: model)
            Text(model.status).font(.caption).lineLimit(1)
        }
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func symmetryButton(_ title: String, axis: WritableKeyPath<SculptSymmetry, Bool>) -> some View {
        Button(title) { model.symmetry[keyPath: axis].toggle() }
            .buttonStyle(.borderedProminent)
            .tint(model.symmetry[keyPath: axis] ? .blue : .gray)
            .controlSize(.small)
            .accessibilityLabel("\(title) axis symmetry")
            .accessibilityValue(model.symmetry[keyPath: axis] ? "On" : "Off")
    }

    private var symmetryControlsDisabled: Bool {
        #if DEBUG
        model.isStrokeActive || model.isBenchmarkRunning
        #else
        model.isStrokeActive
        #endif
    }

    private var importControlsDisabled: Bool {
        #if DEBUG
        model.isSTLImporting || model.isBenchmarkRunning
        #else
        model.isSTLImporting
        #endif
    }

    private var brushCursorDiameter: CGFloat {
        let projectedRadius = model.brushSettings.radius / max(model.camera.distance, 0.001)
        return CGFloat(min(max(projectedRadius * 560, 12), 600))
    }

    private func saveProject() {
        do {
            let snapshot = try model.prepareExplicitSave()
            projectSaveSnapshot = snapshot
            projectExport = ForgeFile(data: try ProjectCodec.encode(snapshot.project))
            showProjectExporter = true
        }
        catch { model.status = "Save failed: \(error.localizedDescription)" }
    }

    private func requestOpenProject() {
        if model.hasRecoveryConflict {
            model.presentRecovery()
        } else if model.isDirty {
            confirmsOpeningWithUnsavedChanges = true
        } else {
            showImporter = true
        }
    }
    private func beginSTLExport() {
        do { try model.prepareForSTLExport(); showSTLOptions = true }
        catch { model.status = "Export failed: \(error.localizedDescription)" }
    }

    private func beginFaceExtrude() {
        do {
            try model.prepareForFaceExtrude()
            showFaceExtrude = true
        } catch {
            model.status = "Extrude unavailable: \(error.localizedDescription)"
        }
    }

    private func beginFaceInset() {
        do {
            try model.prepareForFaceInset()
            showFaceInset = true
        } catch {
            model.status = "Inset unavailable: \(error.localizedDescription)"
        }
    }

    private func previewSTLImport(_ selection: Result<URL, Error>) {
        guard case .success(let url) = selection else {
            if case .failure(let error) = selection { model.status = "Import failed: \(error.localizedDescription)" }
            return
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            stlImportResult = try model.previewSTLImport(data: data)
            stlImportFileName = url.lastPathComponent
            showSTLImportConfirmation = true
        } catch {
            stlImportResult = nil
            model.status = "Import failed: \(error.localizedDescription)"
        }
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
