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
    var transform: ObjectTransform = .identity
    var metadata: [String: String] = [:]

    init(formatVersion: Int = currentFormatVersion, mesh: EditableMesh, camera: CameraState,
         transform: ObjectTransform = .identity, metadata: [String: String] = [:]) {
        self.formatVersion = formatVersion; self.mesh = mesh; self.camera = camera
        self.transform = transform.sanitized(); self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, mesh, camera, transform, metadata }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        mesh = try container.decode(EditableMesh.self, forKey: .mesh)
        camera = try container.decode(CameraState.self, forKey: .camera)
        transform = try container.decodeIfPresent(ObjectTransform.self, forKey: .transform)?.sanitized() ?? .identity
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

enum ProjectCodec {
    static func encode(_ project: ForgeProject) throws -> Data {
        _ = try project.mesh.validated()
        var safeProject = project
        safeProject.transform = project.transform.sanitized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(safeProject)
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
