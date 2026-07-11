import SwiftUI
import UniformTypeIdentifiers

@main
struct Forge3DApp: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

extension UTType {
    static let forge3D = UTType(exportedAs: "com.forge3d.project", conformingTo: .data)
}
