import Foundation
import simd

struct CameraState: Codable, Equatable {
    var yaw: Float = 0.4
    var pitch: Float = 0.25
    var distance: Float = 3.5
    var target: SIMD3<Float> = .zero
}

struct ForgeProject: Codable, Equatable {
    static let currentFormatVersion = 1
    var formatVersion = currentFormatVersion
    var mesh: EditableMesh
    var camera: CameraState
    var metadata: [String: String] = [:]
}

enum ProjectCodec {
    static func encode(_ project: ForgeProject) throws -> Data {
        _ = try project.mesh.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    static func decode(_ data: Data, maximumBytes: Int = 128 * 1_024 * 1_024) throws -> ForgeProject {
        guard data.count <= maximumBytes else { throw ProjectError.tooLarge }
        let project = try JSONDecoder().decode(ForgeProject.self, from: data)
        guard project.formatVersion == ForgeProject.currentFormatVersion else { throw ProjectError.unsupportedVersion }
        _ = try project.mesh.validated()
        return project
    }
}

enum ProjectError: Error { case tooLarge, unsupportedVersion }
