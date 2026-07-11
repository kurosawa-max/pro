import XCTest
import simd
@testable import Forge3D

final class FoundationPrototypeTests: XCTestCase {
    func testSphereMeshIsValid() throws {
        let mesh = EditableMesh.uvSphere(latitudeSegments: 8, longitudeSegments: 12)
        XCTAssertNoThrow(try mesh.validated())
        XCTAssertEqual(mesh.indices.count, 8 * 12 * 6)
        XCTAssertTrue(mesh.vertices.allSatisfy { abs(simd_length($0.normal) - 1) < 0.001 })
    }

    func testRayPicksSphereSurface() {
        let mesh = EditableMesh.uvSphere(latitudeSegments: 12, longitudeSegments: 18)
        let hit = MeshPicker.hit(ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.distance ?? 0, 2, accuracy: 0.08)
    }

    func testDrawSmoothAndGrabModifyVertices() {
        for kind in BrushKind.allCases {
            var mesh = EditableMesh.uvSphere(latitudeSegments: 8, longitudeSegments: 12)
            let original = mesh
            let command = SculptBrush.apply(kind: kind, center: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 1, 0),
                                            drag: SIMD3<Float>(0.1, 0, 0), pressure: 1,
                                            settings: BrushSettings(radius: 0.6, strength: 0.25), mesh: &mesh)
            XCTAssertFalse(command.changes.isEmpty, "\(kind) must produce a vertex delta")
            XCTAssertNotEqual(mesh, original)
        }
    }

    func testUndoAndRedoOperatePerStroke() {
        var mesh = EditableMesh.uvSphere(latitudeSegments: 8, longitudeSegments: 12)
        let original = mesh
        let command = SculptBrush.apply(kind: .draw, center: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 1, 0),
                                        drag: .zero, pressure: 1, settings: BrushSettings(radius: 0.5, strength: 0.2), mesh: &mesh)
        let changed = mesh
        var history = StrokeHistory(); history.record(command)
        history.undo(mesh: &mesh); XCTAssertEqual(mesh, original)
        history.redo(mesh: &mesh); XCTAssertEqual(mesh, changed)
    }

    func testProjectSurvivesOneHundredRoundTrips() throws {
        var project = ForgeProject(mesh: .uvSphere(latitudeSegments: 6, longitudeSegments: 8), camera: CameraState())
        let original = project.mesh
        for _ in 0..<100 { project = try ProjectCodec.decode(ProjectCodec.encode(project)) }
        XCTAssertEqual(project.mesh, original)
        XCTAssertEqual(project.formatVersion, ForgeProject.currentFormatVersion)
    }

    func testProjectRejectsUnsupportedVersionAndInvalidIndices() throws {
        var project = ForgeProject(mesh: .uvSphere(latitudeSegments: 4, longitudeSegments: 6), camera: CameraState())
        project.formatVersion = 99
        let raw = try JSONEncoder().encode(project)
        XCTAssertThrowsError(try ProjectCodec.decode(raw))
        var invalid = EditableMesh.uvSphere(latitudeSegments: 4, longitudeSegments: 6)
        invalid.indices[0] = UInt32(invalid.vertices.count)
        XCTAssertThrowsError(try invalid.validated())
    }

    func testBinarySTLHasExpectedSizeAndTriangleCount() throws {
        let mesh = EditableMesh.uvSphere(latitudeSegments: 4, longitudeSegments: 6)
        let data = try BinarySTLExporter.data(for: mesh)
        XCTAssertEqual(data.count, 84 + (mesh.indices.count / 3) * 50)
        let count = data[80..<84].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        XCTAssertEqual(Int(count), mesh.indices.count / 3)
    }

    func testPencilSampleNormalizesPressureAndKeepsTilt() {
        let sample = PencilSample(location: .zero, force: 2, maximumForce: 4, altitude: 0.7, azimuth: 1.2, timestamp: 5)
        XCTAssertEqual(sample.pressure, 0.5, accuracy: 0.001)
        XCTAssertEqual(sample.altitude, 0.7, accuracy: 0.001)
        XCTAssertEqual(sample.azimuth, 1.2, accuracy: 0.001)
    }
}
