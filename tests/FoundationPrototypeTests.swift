import XCTest
import UniformTypeIdentifiers
import simd
@testable import Forge3D

final class FoundationPrototypeTests: XCTestCase {
    func testForgeProjectTypeIdentifierAndExtension() {
        XCTAssertEqual(UTType.forge3D.identifier, "com.forge3d.project")
        XCTAssertEqual(UTType.forge3D.preferredFilenameExtension, "forge3d")
        XCTAssertTrue(ForgeFile.readableContentTypes.contains(.forge3D))
    }

    func testIcosphereIsValidWeldedAndHasNoDegenerateTriangles() throws {
        let mesh = EditableMesh.icosphere(subdivisions: 2)
        XCTAssertNoThrow(try mesh.validated())
        XCTAssertEqual(Set(mesh.vertices.map(\.position)).count, mesh.vertices.count)
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[triangle])].position
            let b = mesh.vertices[Int(mesh.indices[triangle + 1])].position
            let c = mesh.vertices[Int(mesh.indices[triangle + 2])].position
            XCTAssertGreaterThan(simd_length(simd_cross(b - a, c - a)) * 0.5, 0.000_001)
        }
        XCTAssertTrue(mesh.vertices.allSatisfy { abs(simd_length($0.normal) - 1) < 0.001 })
    }

    func testAdjacencyCacheIsSymmetricAndRebuildsAfterDecoding() throws {
        var mesh = EditableMesh.icosphere(subdivisions: 1)
        XCTAssertTrue(mesh.hasCachedAdjacency)
        let original = mesh.adjacency()
        for vertex in original.indices {
            XCTAssertFalse(original[vertex].contains(vertex))
            for neighbor in original[vertex] { XCTAssertTrue(original[neighbor].contains(vertex)) }
        }
        var decoded = try JSONDecoder().decode(EditableMesh.self, from: JSONEncoder().encode(mesh))
        XCTAssertFalse(decoded.hasCachedAdjacency)
        XCTAssertEqual(decoded.adjacency(), original)
        XCTAssertTrue(decoded.hasCachedAdjacency)
        XCTAssertNotEqual(decoded.runtime.topologyID, mesh.runtime.topologyID)
    }

    func testMeshRevisionChangesOnlyForActualVertexMutation() {
        var mesh = EditableMesh.icosphere(subdivisions: 0)
        let initial = mesh.runtime.revision
        XCTAssertTrue(mesh.updatePositions([0: mesh.vertices[0].position]).isEmpty)
        XCTAssertEqual(mesh.runtime.revision, initial)
        _ = mesh.updatePositions([0: mesh.vertices[0].position * 1.01])
        XCTAssertGreaterThan(mesh.runtime.revision, initial)
    }

    func testPickingReturnsBarycentricInterpolatedNormalsAtCenterVertexAndEdge() {
        let mesh = pickingTriangle()
        let center = MeshPicker.hit(ray: Ray(origin: SIMD3<Float>(0, -1 / 3, 1), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh)
        XCTAssertNotNil(center)
        XCTAssertEqual(center!.barycentric.x, 1 / 3, accuracy: 0.001)
        XCTAssertEqual(center!.barycentric.y, 1 / 3, accuracy: 0.001)
        XCTAssertEqual(center!.barycentric.z, 1 / 3, accuracy: 0.001)
        let expectedNormal = simd_normalize(SIMD3<Float>(1, 1, 1))
        XCTAssertLessThan(simd_distance(center!.normal, expectedNormal), 0.001)

        let nearVertex = MeshPicker.hit(ray: Ray(origin: SIMD3<Float>(-0.98, -0.98, 1), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh)
        XCTAssertGreaterThan(nearVertex!.barycentric.x, 0.97)
        let edge = MeshPicker.hit(ray: Ray(origin: SIMD3<Float>(0, -1, 1), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh)
        XCTAssertEqual(edge!.barycentric.z, 0, accuracy: 0.001)
    }

    func testPickingDoubleSidedAndBackFaceCullingPolicy() {
        let mesh = pickingTriangle()
        let backRay = Ray(origin: SIMD3<Float>(0, -0.25, -1), direction: SIMD3<Float>(0, 0, 1))
        XCTAssertNotNil(MeshPicker.hit(ray: backRay, mesh: mesh, culling: .none))
        XCTAssertNil(MeshPicker.hit(ray: backRay, mesh: mesh, culling: .back))
    }

    func testDrawSmoothAndGrabReturnOnlyChangedVertices() {
        for kind in BrushKind.allCases {
            var mesh = EditableMesh.icosphere(subdivisions: 1)
            let original = mesh
            let mutations = SculptBrush.apply(
                kind: kind, center: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 1, 0),
                drag: SIMD3<Float>(0.1, 0, 0), pressure: 1,
                settings: BrushSettings(radius: 0.8, strength: 0.25), mesh: &mesh
            )
            XCTAssertFalse(mutations.isEmpty, "\(kind) must modify nearby vertices")
            XCTAssertLessThan(mutations.count, mesh.vertices.count)
            XCTAssertNotEqual(mesh, original)
        }
    }

    func testRepeatedSmoothRemainsFinite() {
        var mesh = EditableMesh.icosphere(subdivisions: 1)
        for _ in 0..<500 {
            _ = SculptBrush.apply(
                kind: .smooth, center: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 1, 0), drag: .zero,
                pressure: 1, settings: BrushSettings(radius: 1.5, strength: 1), mesh: &mesh
            )
        }
        XCTAssertTrue(mesh.vertices.allSatisfy { $0.position.allFinite && $0.normal.allFinite })
    }

    func testUndoRedoAndEmptyStrokePolicy() {
        var mesh = EditableMesh.icosphere(subdivisions: 1)
        let original = mesh
        let mutations = SculptBrush.apply(
            kind: .draw, center: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 1, 0), drag: .zero,
            pressure: 1, settings: BrushSettings(radius: 0.8, strength: 0.2), mesh: &mesh
        )
        let changed = mesh
        let command = StrokeCommand(changes: mutations.map { VertexChange(index: $0.index, before: $0.before, after: $0.after) })
        var history = StrokeHistory()
        history.record(StrokeCommand(changes: []))
        XCTAssertEqual(history.undoStack.count, 0)
        history.record(command)
        history.undo(mesh: &mesh); XCTAssertEqual(mesh, original)
        history.redo(mesh: &mesh); XCTAssertEqual(mesh, changed)
    }

    func testCameraInputPolicyRejectsPencil() {
        XCTAssertTrue(CameraInputPolicy.permitsCameraGesture(from: .finger))
        XCTAssertFalse(CameraInputPolicy.permitsCameraGesture(from: .pencil))
        XCTAssertFalse(CameraInputPolicy.permitsCameraGesture(from: .indirect))
    }

    func testProjectSurvivesOneHundredRoundTripsAndRejectsNonFiniteMesh() throws {
        var project = ForgeProject(mesh: .icosphere(subdivisions: 1), camera: CameraState())
        let original = project.mesh
        for _ in 0..<100 { project = try ProjectCodec.decode(ProjectCodec.encode(project)) }
        XCTAssertEqual(project.mesh, original)

        var vertices = original.vertices
        vertices[0].position.x = .nan
        let nanMesh = EditableMesh(vertices: vertices, indices: original.indices)
        XCTAssertThrowsError(try ProjectCodec.encode(ForgeProject(mesh: nanMesh, camera: CameraState())))
        vertices[0].position.x = .infinity
        let infiniteMesh = EditableMesh(vertices: vertices, indices: original.indices)
        XCTAssertThrowsError(try ProjectCodec.encode(ForgeProject(mesh: infiniteMesh, camera: CameraState())))
    }

    func testProjectRejectsUnsupportedVersionAndInvalidIndices() throws {
        let valid = EditableMesh.icosphere(subdivisions: 0)
        var project = ForgeProject(mesh: valid, camera: CameraState())
        project.formatVersion = 99
        XCTAssertThrowsError(try ProjectCodec.decode(JSONEncoder().encode(project)))
        var invalidIndices = valid.indices
        invalidIndices[0] = UInt32(valid.vertices.count)
        XCTAssertThrowsError(try EditableMesh(vertices: valid.vertices, indices: invalidIndices).validated())
    }

    func testBinarySTLStructureAndEmptyMeshRejection() throws {
        let mesh = EditableMesh.icosphere(subdivisions: 1)
        let data = try BinarySTLExporter.data(for: mesh)
        XCTAssertEqual(data.count, 84 + (mesh.indices.count / 3) * 50)
        let count = data[80..<84].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        XCTAssertEqual(Int(count), mesh.indices.count / 3)
        XCTAssertThrowsError(try BinarySTLExporter.data(for: EditableMesh(vertices: [], indices: [])))
    }

    @MainActor
    func testLoadClearsInProgressStrokeState() throws {
        let model = WorkspaceModel()
        model.beginStroke()
        XCTAssertTrue(model.isStrokeActive)
        let data = try ProjectCodec.encode(ForgeProject(mesh: .icosphere(subdivisions: 0), camera: CameraState()))
        model.load(data: data)
        XCTAssertFalse(model.isStrokeActive)
        XCTAssertEqual(model.undoCount, 0)
    }

    @MainActor
    func testEmptyWorkspaceStrokeIsNotRecordedAndCancellationRestoresMesh() {
        let model = WorkspaceModel()
        model.beginStroke()
        model.endStroke()
        XCTAssertEqual(model.undoCount, 0)

        let original = model.mesh
        model.beginStroke()
        let sample = PencilSample(location: .zero, force: 1, maximumForce: 1, altitude: 1, azimuth: 0, timestamp: 0)
        model.updateStroke(sample: sample, ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)))
        model.cancelStroke()
        XCTAssertEqual(model.mesh, original)
        XCTAssertFalse(model.isStrokeActive)
        XCTAssertEqual(model.undoCount, 0)
    }

    func testPencilSampleNormalizesPressureAndKeepsTilt() {
        let sample = PencilSample(location: .zero, force: 2, maximumForce: 4, altitude: 0.7, azimuth: 1.2, timestamp: 5)
        XCTAssertEqual(sample.pressure, 0.5, accuracy: 0.001)
        XCTAssertEqual(sample.altitude, 0.7, accuracy: 0.001)
        XCTAssertEqual(sample.azimuth, 1.2, accuracy: 0.001)
    }

    private func pickingTriangle() -> EditableMesh {
        EditableMesh(
            vertices: [
                MeshVertex(position: SIMD3<Float>(-1, -1, 0), normal: SIMD3<Float>(1, 0, 0)),
                MeshVertex(position: SIMD3<Float>(1, -1, 0), normal: SIMD3<Float>(0, 1, 0)),
                MeshVertex(position: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 0, 1)),
            ],
            indices: [0, 1, 2]
        )
    }
}
