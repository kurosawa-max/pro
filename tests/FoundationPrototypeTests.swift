import XCTest
import UniformTypeIdentifiers
import simd
@testable import Forge3D

final class FoundationPrototypeTests: XCTestCase {
    func testBenchmarkPresetsProduceIncreasingValidNonDegenerateMeshes() throws {
        var previousVertices = 0
        var previousTriangles = 0
        for preset in BenchmarkPreset.allCases {
            let mesh = preset.makeMesh()
            XCTAssertNoThrow(try mesh.validated())
            XCTAssertEqual(mesh.vertices.count, preset.expectedVertexCount)
            XCTAssertEqual(mesh.indices.count / 3, preset.expectedTriangleCount)
            XCTAssertGreaterThan(mesh.vertices.count, previousVertices)
            XCTAssertGreaterThan(mesh.indices.count / 3, previousTriangles)
            XCTAssertTrue(mesh.vertices.allSatisfy { $0.position.allFinite && $0.normal.allFinite })
            XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.vertices.count })
            let hasOnlyNonDegenerateTriangles = stride(from: 0, to: mesh.indices.count, by: 3).allSatisfy { triangle in
                let a = mesh.vertices[Int(mesh.indices[triangle])].position
                let b = mesh.vertices[Int(mesh.indices[triangle + 1])].position
                let c = mesh.vertices[Int(mesh.indices[triangle + 2])].position
                return simd_length(simd_cross(b - a, c - a)) * 0.5 > 0.000_001
            }
            XCTAssertTrue(hasOnlyNonDegenerateTriangles)
            previousVertices = mesh.vertices.count
            previousTriangles = mesh.indices.count / 3
        }
    }

    func testPerformanceProfilerResetClearsSamplesAndPreservesCurrentMeshCounts() {
        let profiler = PerformanceProfiler()
        profiler.record(.picking, milliseconds: 4)
        profiler.record(.frameInterval, milliseconds: 16)
        profiler.updateMeshCounts(vertexCount: 162, triangleCount: 320)
        XCTAssertEqual(profiler.snapshot()[.picking].sampleCount, 1)

        profiler.reset(vertexCount: 2_562, triangleCount: 5_120)
        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot.vertexCount, 2_562)
        XCTAssertEqual(snapshot.triangleCount, 5_120)
        XCTAssertEqual(snapshot.framesPerSecond, 0)
        XCTAssertTrue(snapshot.framesPerSecond.isFinite)
        for metric in PerformanceMetric.allCases {
            XCTAssertEqual(snapshot[metric].sampleCount, 0)
            XCTAssertEqual(snapshot[metric].latestMilliseconds, 0)
            XCTAssertEqual(snapshot[metric].averageMilliseconds, 0)
            XCTAssertTrue(snapshot[metric].averageMilliseconds.isFinite)
        }
    }

    func testBenchmarkCompileModeMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertTrue(BenchmarkFeature.isCompiled)
        #else
        XCTAssertFalse(BenchmarkFeature.isCompiled)
        #endif
    }

    func testRollingAverageDropsSamplesBeyondCapacity() {
        var average = RollingAverage(capacity: 2)
        average.append(1)
        average.append(2)
        average.append(3)
        XCTAssertEqual(average.sampleCount, 2)
        XCTAssertEqual(average.latest, 3)
        XCTAssertEqual(average.average, 2.5, accuracy: 0.000_001)
    }

    func testRollingAverageCalculatesMeanAndEmptyValueIsFinite() {
        var average = RollingAverage(capacity: 60)
        XCTAssertEqual(average.average, 0)
        XCTAssertTrue(average.average.isFinite)
        average.append(2)
        average.append(4)
        average.append(6)
        XCTAssertEqual(average.average, 4, accuracy: 0.000_001)
    }

    func testPerformanceSnapshotReportsMeshCountsAndSafeEmptyFPS() {
        let snapshot = PerformanceSnapshot(vertexCount: 642, triangleCount: 1_280)
        XCTAssertEqual(snapshot.vertexCount, 642)
        XCTAssertEqual(snapshot.triangleCount, 1_280)
        XCTAssertEqual(snapshot.framesPerSecond, 0)
        XCTAssertTrue(snapshot.framesPerSecond.isFinite)
    }

    func testInstrumentationCompileModeMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertTrue(PerformanceProfiler.isInstrumentationCompiled)
        #else
        XCTAssertFalse(PerformanceProfiler.isInstrumentationCompiled)
        #endif
    }

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

    @MainActor
    func testBenchmarkSwitchClearsUndoRedoAndKeepsDefaultStartupMesh() {
        let model = WorkspaceModel()
        XCTAssertEqual(model.mesh.vertices.count, 642)
        XCTAssertEqual(model.mesh.indices.count / 3, 1_280)
        model.beginStroke()
        let sample = PencilSample(location: .zero, force: 1, maximumForce: 1, altitude: 1, azimuth: 0, timestamp: 0)
        model.updateStroke(sample: sample, ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)))
        model.endStroke()
        XCTAssertGreaterThan(model.undoCount, 0)
        model.undo()
        XCTAssertGreaterThan(model.redoCount, 0)

        model.loadBenchmarkPreset(.small)
        XCTAssertEqual(model.undoCount, 0)
        XCTAssertEqual(model.redoCount, 0)
        XCTAssertEqual(model.benchmarkDisplayName, "Small")
        XCTAssertEqual(model.mesh.vertices.count, BenchmarkPreset.small.expectedVertexCount)
    }

    @MainActor
    func testBenchmarkSwitchSafelyCancelsActiveStroke() throws {
        let model = WorkspaceModel()
        let previousTopologyID = model.mesh.runtime.topologyID
        model.beginStroke()
        XCTAssertTrue(model.isStrokeActive)
        model.loadBenchmarkPreset(.medium)
        XCTAssertFalse(model.isStrokeActive)
        XCTAssertEqual(model.undoCount, 0)
        XCTAssertEqual(model.redoCount, 0)
        XCTAssertNoThrow(try model.mesh.validated())
        XCTAssertNotEqual(model.mesh.runtime.topologyID, previousTopologyID)
    }

    func testPencilSampleNormalizesPressureAndKeepsTilt() {
        let sample = PencilSample(location: .zero, force: 2, maximumForce: 4, altitude: 0.7, azimuth: 1.2, timestamp: 5)
        XCTAssertEqual(sample.pressure, 0.5, accuracy: 0.001)
        XCTAssertEqual(sample.altitude, 0.7, accuracy: 0.001)
        XCTAssertEqual(sample.azimuth, 1.2, accuracy: 0.001)
    }

    func testRollingAverageProvidesBoundedStatistics() {
        var values = RollingAverage(capacity: 3)
        [1.0, 2.0, 6.0, 4.0].forEach { values.append($0) }
        XCTAssertEqual(values.sampleCount, 3); XCTAssertEqual(values.latest, 4)
        XCTAssertEqual(values.average, 4); XCTAssertEqual(values.minimum, 2); XCTAssertEqual(values.maximum, 6)
        let empty = RollingAverage()
        XCTAssertTrue([empty.latest, empty.average, empty.minimum, empty.maximum].allSatisfy(\.isFinite))
    }

    @MainActor
    func testAutomatedBenchmarkCasesAndConfigurationAreDeterministic() {
        XCTAssertEqual(BenchmarkCase.allCases.map(\.rawValue), ["Picking", "Draw brush", "Smooth brush", "Grab brush", "Normal rebuild", "Vertex buffer upload", "Index buffer upload"])
        XCTAssertEqual(BenchmarkRunConfiguration.standard.warmUpIterations, 10)
        XCTAssertEqual(BenchmarkRunConfiguration.standard.measuredIterations, 60)
        XCTAssertEqual(BenchmarkRunner.fixedRay.origin, SIMD3<Float>(0, 0, 3))
    }

    func testBenchmarkReportJSONRoundTripAndTextFields() throws {
        let item = BenchmarkCaseResult(caseName: "Picking", sampleCount: 60, latestMilliseconds: 1, averageMilliseconds: 2, minimumMilliseconds: 0.5, maximumMilliseconds: 4)
        let report = BenchmarkReport(executedAt: Date(timeIntervalSince1970: 0), environment: "Simulator", buildConfiguration: "Debug", configuration: .standard, presets: [BenchmarkPresetResult(presetName: "Small", vertexCount: 162, triangleCount: 320, cases: [item])])
        XCTAssertEqual(try JSONDecoder().decode(BenchmarkReport.self, from: JSONEncoder().encode(report)), report)
        for required in ["Small", "162 vertices", "320 triangles", "Picking", "latest", "avg", "min", "max", "Simulator", "Debug"] { XCTAssertTrue(report.plainText.contains(required)) }
    }

    @MainActor
    func testAutomatedRunnerProducesEveryPresetAndExcludesWarmup() async {
        let report = await BenchmarkRunner().run(profiler: PerformanceProfiler(), configuration: BenchmarkRunConfiguration(warmUpIterations: 1, measuredIterations: 2), progress: { _, _ in }, installMesh: { _ in })
        XCTAssertEqual(report?.presets.map(\.presetName), BenchmarkPreset.allCases.map(\.rawValue))
        XCTAssertEqual(report?.presets.count, 3)
        XCTAssertEqual(report?.presets.first?.cases.first { $0.caseName == BenchmarkCase.picking.rawValue }?.sampleCount, 2)
    }

    @MainActor
    func testAutomatedBenchmarkCancellationRestoresWorkspaceState() async {
        let model = WorkspaceModel(); let originalMesh = model.mesh; let originalCamera = model.camera; let originalSettings = model.brushSettings
        model.runAllBenchmarks(); model.cancelBenchmarks()
        for _ in 0..<100 where model.isBenchmarkRunning { await Task.yield() }
        XCTAssertFalse(model.isBenchmarkRunning); XCTAssertEqual(model.mesh, originalMesh); XCTAssertEqual(model.camera, originalCamera)
        XCTAssertEqual(model.brushSettings.radius, originalSettings.radius); XCTAssertEqual(model.undoCount, 0); XCTAssertEqual(model.redoCount, 0)
    }

    func testAutomatedBenchmarkReleaseBoundary() {
        #if DEBUG
        XCTAssertTrue(AutomatedBenchmarkFeature.isCompiled)
        #else
        XCTAssertFalse(AutomatedBenchmarkFeature.isCompiled)
        #endif
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
