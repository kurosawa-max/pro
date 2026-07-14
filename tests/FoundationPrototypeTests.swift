import XCTest
import UniformTypeIdentifiers
import MetalKit
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
        let profiler = PerformanceProfiler()
        let report = await BenchmarkRunner().run(profiler: profiler, configuration: BenchmarkRunConfiguration(warmUpIterations: 1, measuredIterations: 2), progress: { _, _ in }, installMesh: { _ in
            profiler.record(.vertexUpload, milliseconds: 1)
            profiler.record(.indexUpload, milliseconds: 1)
        })
        XCTAssertEqual(report?.presets.map(\.presetName), BenchmarkPreset.allCases.map(\.rawValue))
        XCTAssertEqual(report?.presets.count, 3)
        XCTAssertEqual(report?.presets.first?.cases.first { $0.caseName == BenchmarkCase.picking.rawValue }?.sampleCount, 2)
        for preset in report?.presets ?? [] {
            XCTAssertEqual(preset.cases.first { $0.caseName == BenchmarkCase.vertexUpload.rawValue }?.sampleCount, 2)
            XCTAssertEqual(preset.cases.first { $0.caseName == BenchmarkCase.indexUpload.rawValue }?.sampleCount, 2)
        }
    }

    @MainActor
    func testIndexUploadMeshesMatchEveryPresetScaleAndRefreshTopology() {
        for preset in BenchmarkPreset.allCases {
            let first = BenchmarkRunner.makeIndexUploadMesh(for: preset)
            let second = BenchmarkRunner.makeIndexUploadMesh(for: preset)
            XCTAssertEqual(first.vertices.count, preset.expectedVertexCount)
            XCTAssertEqual(first.indices.count / 3, preset.expectedTriangleCount)
            XCTAssertEqual(second.vertices.count, preset.expectedVertexCount)
            XCTAssertEqual(second.indices.count / 3, preset.expectedTriangleCount)
            XCTAssertNotEqual(first.runtime.topologyID, second.runtime.topologyID)
        }
        let large = BenchmarkRunner.makeIndexUploadMesh(for: .large)
        XCTAssertEqual(large.vertices.count, BenchmarkPreset.large.expectedVertexCount)
        XCTAssertEqual(large.indices.count / 3, BenchmarkPreset.large.expectedTriangleCount)
    }

    @MainActor
    func testUploadAcknowledgementTimeoutDoesNotProduceSuccessfulReport() async {
        let report = await BenchmarkRunner().run(profiler: PerformanceProfiler(),
            configuration: BenchmarkRunConfiguration(warmUpIterations: 0, measuredIterations: 1),
            progress: { _, _ in }, installMesh: { _ in })
        XCTAssertNil(report)
    }

    @MainActor
    func testAutomatedBenchmarkCancellationRestoresWorkspaceState() async {
        let model = WorkspaceModel()
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3), scale: SIMD3<Float>(2, 1, 0.5)))
        let originalMesh = model.mesh; let originalCamera = model.camera; let originalSettings = model.brushSettings
        let originalTransform = model.objectTransform
        let originalUndoCount = model.undoCount, originalRedoCount = model.redoCount
        model.runAllBenchmarks()
        XCTAssertFalse(model.canUndo); XCTAssertFalse(model.canRedo)
        XCTAssertTrue(model.objectTransform.isIdentity)
        for _ in 0..<10_000 where model.isBenchmarkRunning && model.benchmarkProgress < (5.0 / 21.0) { await Task.yield() }
        model.cancelBenchmarks()
        for _ in 0..<1_000 where model.isBenchmarkRunning { await Task.yield() }
        XCTAssertFalse(model.isBenchmarkRunning); XCTAssertEqual(model.mesh, originalMesh); XCTAssertEqual(model.camera, originalCamera)
        XCTAssertEqual(model.objectTransform, originalTransform)
        XCTAssertEqual(model.brushSettings.radius, originalSettings.radius)
        XCTAssertEqual(model.undoCount, originalUndoCount); XCTAssertEqual(model.redoCount, originalRedoCount)
        XCTAssertEqual(model.canUndo, originalUndoCount > 0); XCTAssertEqual(model.canRedo, originalRedoCount > 0)
    }

    func testAutomatedBenchmarkReleaseBoundary() {
        #if DEBUG
        XCTAssertTrue(AutomatedBenchmarkFeature.isCompiled)
        #else
        XCTAssertFalse(AutomatedBenchmarkFeature.isCompiled)
        #endif
    }

    func testAABBInclusionUnionAndRayVariants() {
        var box = AxisAlignedBoundingBox(); XCTAssertFalse(box.isFinite)
        box.include(SIMD3<Float>(-1, -2, -3)); box.include(SIMD3<Float>(1, 2, 3))
        XCTAssertTrue(box.contains(.zero)); XCTAssertEqual(box.center, .zero)
        XCTAssertEqual(box.extent, SIMD3<Float>(2, 4, 6)); XCTAssertEqual(box.surfaceArea, 88)
        var other = AxisAlignedBoundingBox(); other.include(SIMD3<Float>(-2, 0, 0)); other.include(SIMD3<Float>(0, 1, 1)); box.include(other)
        XCTAssertTrue(box.contains(other))
        XCTAssertNotNil(box.rayNearDistance(Ray(origin: SIMD3<Float>(-4, 0, 0), direction: SIMD3<Float>(1, 0, 0))))
        XCTAssertNotNil(box.rayNearDistance(Ray(origin: SIMD3<Float>(4, 0, 0), direction: SIMD3<Float>(-1, 0, 0))))
        XCTAssertNotNil(box.rayNearDistance(Ray(origin: .zero, direction: SIMD3<Float>(0, 1, 0))))
        XCTAssertNil(box.rayNearDistance(Ray(origin: SIMD3<Float>(4, 4, 4), direction: SIMD3<Float>(0, 1, 0))))
        XCTAssertNotNil(box.rayNearDistance(Ray(origin: SIMD3<Float>(-2, 0, 0), direction: SIMD3<Float>(1, 0, 0))))
        XCTAssertNil(box.rayNearDistance(Ray(origin: SIMD3<Float>(.nan, 0, 0), direction: SIMD3<Float>(1, 0, 0))))
        XCTAssertNil(box.rayNearDistance(Ray(origin: .zero, direction: SIMD3<Float>(.infinity, 0, 0))))
    }

    func testBVHBuildHandlesEmptySingleDegenerateAndCoincidentCentroids() throws {
        XCTAssertTrue(try MeshBVH(mesh: EditableMesh(vertices: [], indices: [])).isEmpty)
        let single = pickingTriangle(); let singleBVH = try MeshBVH(mesh: single)
        XCTAssertEqual(singleBVH.triangles.count, 1); XCTAssertEqual(singleBVH.nodes.count, 1)
        let degenerate = EditableMesh(vertices: [MeshVertex(position: .zero, normal: SIMD3<Float>(0, 1, 0)), MeshVertex(position: .zero, normal: SIMD3<Float>(0, 1, 0)), MeshVertex(position: .zero, normal: SIMD3<Float>(0, 1, 0))], indices: [0, 1, 2])
        XCTAssertNoThrow(try MeshBVH(mesh: degenerate))
        let coincident = EditableMesh(vertices: single.vertices, indices: Array(repeating: [UInt32(0), 1, 2], count: 9).flatMap { $0 })
        let coincidentBVH = try MeshBVH(mesh: coincident)
        XCTAssertEqual(coincidentBVH.triangles.count, 9)
        XCTAssertEqual(coincidentBVH.nodes.count, 1)
    }

    func testBVHStoresEveryTriangleOnceAndBoundsHierarchyIsValid() throws {
        let mesh = EditableMesh.icosphere(subdivisions: 2), bvh = try MeshBVH(mesh: mesh)
        XCTAssertEqual(bvh.triangles.map(\.triangleStart).sorted(), Array(stride(from: 0, to: mesh.indices.count, by: 3)))
        XCTAssertEqual(Set(bvh.triangles.map(\.triangleStart)).count, mesh.indices.count / 3)
        XCTAssertTrue(bvh.nodes[0].bounds.isFinite)
        for node in bvh.nodes where !node.isLeaf {
            XCTAssertTrue(node.left >= 0 && node.right >= 0)
            XCTAssertTrue(node.bounds.contains(bvh.nodes[node.left].bounds))
            XCTAssertTrue(node.bounds.contains(bvh.nodes[node.right].bounds))
        }
        XCTAssertTrue(bvh.nodes.filter(\.isLeaf).allSatisfy { $0.count <= MeshBVH.leafThreshold })
        func depth(_ index: Int) -> Int {
            let node = bvh.nodes[index]
            return node.isLeaf ? 1 : 1 + max(depth(node.left), depth(node.right))
        }
        XCTAssertLessThanOrEqual(depth(0), MeshBVH.maximumDepth + 1)
    }

    func testBVHPickingMatchesLinearAcrossPresetsAndRays() {
        let rays = [
            Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)),
            Ray(origin: SIMD3<Float>(3, 0, 0), direction: SIMD3<Float>(-1, 0, 0)),
            Ray(origin: SIMD3<Float>(0, 0, 3), direction: simd_normalize(SIMD3<Float>(0.3, 0.1, -3))),
            Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 1, 0)),
            Ray(origin: .zero, direction: SIMD3<Float>(0, 0, 1)),
        ]
        for preset in BenchmarkPreset.allCases {
            let mesh = preset.makeMesh(), cache = MeshBVHCache()
            for ray in rays { assertEquivalent(linear: MeshPicker.hitLinear(ray: ray, mesh: mesh), bvh: MeshPicker.hit(ray: ray, mesh: mesh, cache: cache)) }
        }
    }

    func testBVHCacheReusesRefitsAndRebuilds() {
        var mesh = EditableMesh.icosphere(subdivisions: 1); let cache = MeshBVHCache()
        XCTAssertNotNil(MeshPicker.hit(ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh, cache: cache))
        XCTAssertEqual(cache.buildCount, 1)
        _ = cache.index(for: mesh); XCTAssertEqual(cache.reuseCount, 1)
        let oldRoot = cache.bvh?.nodes.first?.bounds
        _ = mesh.updatePositions([0: mesh.vertices[0].position * 1.2])
        _ = cache.index(for: mesh); XCTAssertEqual(cache.refitCount, 1); XCTAssertNotEqual(cache.bvh?.nodes.first?.bounds, oldRoot)
        assertEquivalent(linear: MeshPicker.hitLinear(ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh), bvh: MeshPicker.hit(ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)), mesh: mesh, cache: cache))
        let replacement = EditableMesh.icosphere(subdivisions: 2); _ = cache.index(for: replacement)
        XCTAssertEqual(cache.buildCount, 2); XCTAssertEqual(cache.topologyID, replacement.runtime.topologyID)
    }

    private func assertEquivalent(linear: MeshHit?, bvh: MeshHit?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(linear != nil, bvh != nil, file: file, line: line)
        guard let linear, let bvh else { return }
        XCTAssertEqual(linear.triangleStart, bvh.triangleStart, file: file, line: line)
        XCTAssertEqual(linear.distance, bvh.distance, accuracy: 0.000_01, file: file, line: line)
        for axis in 0..<3 {
            XCTAssertEqual(linear.position[axis], bvh.position[axis], accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(linear.barycentric[axis], bvh.barycentric[axis], accuracy: 0.000_01, file: file, line: line)
            XCTAssertEqual(linear.normal[axis], bvh.normal[axis], accuracy: 0.000_01, file: file, line: line)
        }
    }

    func testObjectTransformIdentityTranslationRotationAndScaleMatrices() {
        XCTAssertTrue(ObjectTransform.identity.isIdentity)
        assertMatrix(ObjectTransform.identity.modelMatrix, equals: matrix_identity_float4x4)
        let translation = ObjectTransform(translation: SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(translation.worldPosition(fromLocal: .zero), SIMD3<Float>(1, 2, 3))
        let rotation = ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(0, 90, 0)))
        let rotated = rotation.worldDirection(fromLocal: SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(rotated.x, 1, accuracy: 0.000_1)
        let uniform = ObjectTransform(scale: SIMD3<Float>(repeating: 2))
        XCTAssertEqual(uniform.worldPosition(fromLocal: SIMD3<Float>(1, 1, 1)), SIMD3<Float>(2, 2, 2))
        let nonUniform = ObjectTransform(scale: SIMD3<Float>(2, 3, 4))
        XCTAssertEqual(nonUniform.worldPosition(fromLocal: SIMD3<Float>(1, 1, 1)), SIMD3<Float>(2, 3, 4))
    }

    func testObjectTransformInverseRoundTripAndNormalMatrixAreFinite() {
        let transform = ObjectTransform(translation: SIMD3<Float>(2, -1, 4),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(25, 40, -15)), scale: SIMD3<Float>(2, 0.5, 3))
        let local = SIMD3<Float>(0.2, -0.7, 1.1)
        let roundTrip = transform.localPosition(fromWorld: transform.worldPosition(fromLocal: local))
        for axis in 0..<3 { XCTAssertEqual(roundTrip[axis], local[axis], accuracy: 0.000_1) }
        let normal = transform.worldNormal(fromLocal: simd_normalize(SIMD3<Float>(1, 2, 3)))
        XCTAssertTrue(normal.allFinite); XCTAssertEqual(simd_length(normal), 1, accuracy: 0.000_1)
        for column in 0..<3 { XCTAssertTrue(transform.normalMatrix[column].allFinite) }
    }

    func testObjectTransformSanitizesZeroExtremeAndNonFiniteValues() {
        let value = ObjectTransform(translation: SIMD3<Float>(.nan, 1, 2), rotation: SIMD4<Float>(.nan, 0, 0, 0),
                                    scale: SIMD3<Float>(0, .infinity, -Float.greatestFiniteMagnitude))
        XCTAssertTrue(value.isFinite)
        XCTAssertEqual(value.translation, .zero)
        XCTAssertEqual(value.scale.x, ObjectTransform.minimumScaleMagnitude)
        XCTAssertEqual(value.scale.y, 1)
        XCTAssertEqual(value.scale.z, ObjectTransform.maximumScaleMagnitude)
        let column = value.modelMatrix.columns.0
        XCTAssertTrue(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite)
    }

    func testTransformedWorldRayPickingMatchesLocalPicking() {
        let mesh = EditableMesh.icosphere(subdivisions: 2)
        let localRay = Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1))
        let expected = MeshPicker.hit(ray: localRay, mesh: mesh)
        for transform in [
            ObjectTransform.identity,
            ObjectTransform(translation: SIMD3<Float>(2, -1, 0.5)),
            ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(20, 35, 10))),
            ObjectTransform(scale: SIMD3<Float>(repeating: 2)),
            ObjectTransform(scale: SIMD3<Float>(2, 0.75, 1.5)),
        ] {
            let worldRay = Ray(origin: transform.worldPosition(fromLocal: localRay.origin),
                               direction: transform.worldDirection(fromLocal: localRay.direction))
            guard let converted = transform.localRay(fromWorld: worldRay) else { return XCTFail("Ray conversion failed") }
            let actual = MeshPicker.hit(ray: converted, mesh: mesh)
            XCTAssertEqual(actual?.triangleStart, expected?.triangleStart)
            XCTAssertEqual(actual?.distance ?? -1, expected?.distance ?? -1, accuracy: 0.000_1)
        }
    }

    @MainActor
    func testTransformChangesDoNotMutateMeshRevisionOrUploadMetrics() {
        let model = WorkspaceModel(), topology = model.mesh.runtime.topologyID, revision = model.mesh.runtime.revision
        let before = model.profiler?.snapshot()
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3), scale: SIMD3<Float>(2, 3, 4)))
        XCTAssertEqual(model.mesh.runtime.topologyID, topology); XCTAssertEqual(model.mesh.runtime.revision, revision)
        XCTAssertEqual(model.profiler?.snapshot()[.vertexUpload].sampleCount, before?[.vertexUpload].sampleCount)
        XCTAssertEqual(model.profiler?.snapshot()[.indexUpload].sampleCount, before?[.indexUpload].sampleCount)
    }

    @MainActor
    func testTransformedWorkspaceSculptEditsLocalMeshForAllBrushes() {
        for kind in BrushKind.allCases {
            let model = WorkspaceModel(); model.brush = kind
            let transform = ObjectTransform(translation: SIMD3<Float>(2, 0, 0),
                rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(0, 25, 0)), scale: SIMD3<Float>(1.5, 0.8, 1.2))
            model.updateTransform(transform)
            let origin = transform.worldPosition(fromLocal: SIMD3<Float>(0, 0, 3))
            let direction = transform.worldDirection(fromLocal: SIMD3<Float>(0, 0, -1))
            let revision = model.mesh.runtime.revision
            model.beginStroke()
            model.updateStroke(sample: PencilSample(location: .zero, force: 1, maximumForce: 1, altitude: 1, azimuth: 0, timestamp: 0),
                               ray: Ray(origin: origin, direction: direction))
            let movedOrigin = transform.worldPosition(fromLocal: SIMD3<Float>(0.05, 0, 3))
            model.updateStroke(sample: PencilSample(location: .zero, force: 1, maximumForce: 1, altitude: 1, azimuth: 0, timestamp: 1),
                               ray: Ray(origin: movedOrigin, direction: direction))
            model.endStroke()
            XCTAssertGreaterThan(model.mesh.runtime.revision, revision)
            XCTAssertEqual(model.objectTransform, transform)
        }
    }

    func testProjectTransformRoundTripAndLegacyIdentityFallback() throws {
        let transform = ObjectTransform(translation: SIMD3<Float>(1, 2, 3),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 20, 30)), scale: SIMD3<Float>(2, 3, 4))
        let project = ForgeProject(mesh: .icosphere(subdivisions: 0), camera: CameraState(), transform: transform)
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).transform, transform)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "transform")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try ProjectCodec.decode(legacy).transform.isIdentity)
    }

    func testGizmoRayLineClosestAndParallelFallbackAreFinite() throws {
        let ray = Ray(origin: SIMD3<Float>(0.25, 1, 5), direction: simd_normalize(SIMD3<Float>(0, -0.2, -1)))
        let closest = try XCTUnwrap(TranslationGizmoGeometry.closestRayAndLine(
            ray: ray, lineOrigin: .zero, lineDirection: SIMD3<Float>(1, 0, 0)))
        XCTAssertEqual(closest.lineParameter, 0.25, accuracy: 0.000_1)
        XCTAssertTrue(closest.distance.isFinite)
        let parallel = Ray(origin: SIMD3<Float>(0, 1, 0), direction: SIMD3<Float>(1, 0, 0))
        XCTAssertNil(TranslationGizmoGeometry.closestRayAndLine(ray: parallel, lineOrigin: .zero,
                                                                lineDirection: SIMD3<Float>(1, 0, 0)))
        let nearParallel = Ray(origin: SIMD3<Float>(0, 1, 1),
                               direction: simd_normalize(SIMD3<Float>(1, 0, -0.01)))
        let fallback = try XCTUnwrap(TranslationGizmoGeometry.axisConstraintPoint(
            ray: nearParallel, origin: .zero, axis: SIMD3<Float>(1, 0, 0), cameraDirection: SIMD3<Float>(0, 0, -1)))
        XCTAssertTrue(fallback.allFinite)
        XCTAssertNotNil(TranslationGizmoGeometry.fallbackPlaneNormal(axis: SIMD3<Float>(1, 0, 0),
                                                                      cameraDirection: SIMD3<Float>(1, 0, 0)))
    }

    func testGizmoAxisAndPlaneDragConstraints() throws {
        let transform = ObjectTransform.identity
        let axisStart = Ray(origin: SIMD3<Float>(0.2, 1, 5), direction: simd_normalize(SIMD3<Float>(0, -0.2, -1)))
        let axisSession = try XCTUnwrap(TranslationGizmoGeometry.beginSession(
            handle: .xAxis, ray: axisStart, transform: transform, cameraDirection: SIMD3<Float>(0, 0, -1)))
        let unchanged = try XCTUnwrap(TranslationGizmoGeometry.translation(
            session: axisSession, ray: axisStart, cameraDirection: SIMD3<Float>(0, 0, -1)))
        XCTAssertEqual(unchanged, .zero)
        let axisMoved = Ray(origin: SIMD3<Float>(0.7, 1, 5), direction: axisStart.direction)
        let axisValue = try XCTUnwrap(TranslationGizmoGeometry.translation(
            session: axisSession, ray: axisMoved, cameraDirection: SIMD3<Float>(0, 0, -1)))
        XCTAssertEqual(axisValue.x, 0.5, accuracy: 0.000_1); XCTAssertEqual(axisValue.y, 0, accuracy: 0.000_1)

        let cases: [(TranslationGizmoHandle, Ray, Ray, Int)] = [
            (.xyPlane, Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1)),
             Ray(origin: SIMD3<Float>(0.5, 0.6, 5), direction: SIMD3<Float>(0, 0, -1)), 2),
            (.yzPlane, Ray(origin: SIMD3<Float>(5, 0.3, 0.3), direction: SIMD3<Float>(-1, 0, 0)),
             Ray(origin: SIMD3<Float>(5, 0.5, 0.6), direction: SIMD3<Float>(-1, 0, 0)), 0),
            (.zxPlane, Ray(origin: SIMD3<Float>(0.3, 5, 0.3), direction: SIMD3<Float>(0, -1, 0)),
             Ray(origin: SIMD3<Float>(0.5, 5, 0.6), direction: SIMD3<Float>(0, -1, 0)), 1),
        ]
        for (handle, start, current, fixedAxis) in cases {
            let session = try XCTUnwrap(TranslationGizmoGeometry.beginSession(
                handle: handle, ray: start, transform: transform, cameraDirection: SIMD3<Float>(0, 0, -1)))
            let value = try XCTUnwrap(TranslationGizmoGeometry.translation(
                session: session, ray: current, cameraDirection: SIMD3<Float>(0, 0, -1)))
            XCTAssertEqual(value[fixedAxis], 0, accuracy: 0.000_1)
        }
    }

    func testGizmoWorldScaleTracksDistanceAndClamps() {
        let near = TranslationGizmoGeometry.worldScale(cameraDistance: 2, viewportHeight: 1_000, fovYRadians: .pi / 4)
        let far = TranslationGizmoGeometry.worldScale(cameraDistance: 10, viewportHeight: 1_000, fovYRadians: .pi / 4)
        XCTAssertGreaterThan(far, near)
        XCTAssertEqual(TranslationGizmoGeometry.worldScale(cameraDistance: 0, viewportHeight: 1_000,
                                                            fovYRadians: .pi / 4), 0.05)
        XCTAssertEqual(TranslationGizmoGeometry.worldScale(cameraDistance: Float.greatestFiniteMagnitude,
                                                            viewportHeight: 1, fovYRadians: .pi / 4), 100)
    }

    func testGizmoPickingAllHandlesMissPriorityAndScaledTolerance() throws {
        let origin = SIMD3<Float>.zero
        let rays: [(TranslationGizmoHandle, Ray)] = [
            (.xAxis, Ray(origin: SIMD3<Float>(0.6, 0.04, 5), direction: SIMD3<Float>(0, 0, -1))),
            (.yAxis, Ray(origin: SIMD3<Float>(0.04, 0.6, 5), direction: SIMD3<Float>(0, 0, -1))),
            (.zAxis, Ray(origin: SIMD3<Float>(0.04, 5, 0.6), direction: SIMD3<Float>(0, -1, 0))),
            (.xyPlane, Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))),
            (.yzPlane, Ray(origin: SIMD3<Float>(5, 0.3, 0.3), direction: SIMD3<Float>(-1, 0, 0))),
            (.zxPlane, Ray(origin: SIMD3<Float>(0.3, 5, 0.3), direction: SIMD3<Float>(0, -1, 0))),
        ]
        for (expected, ray) in rays {
            XCTAssertEqual(TranslationGizmoGeometry.hit(ray: ray, origin: origin, scale: 1)?.handle, expected)
        }
        XCTAssertNil(TranslationGizmoGeometry.hit(ray: Ray(origin: SIMD3<Float>(2, 2, 5), direction: SIMD3<Float>(0, 0, -1)),
                                                  origin: origin, scale: 1))
        let overlap = Ray(origin: SIMD3<Float>(0.3, 0.04, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(TranslationGizmoGeometry.hit(ray: overlap, origin: origin, scale: 1)?.handle, .xAxis)
        let scaledRay = Ray(origin: SIMD3<Float>(1.2, 0.15, 10), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(TranslationGizmoGeometry.hit(ray: scaledRay, origin: origin, scale: 2)?.handle, .xAxis)
    }

    @MainActor
    func testWorkspaceGizmoBeginUpdateEndCancelAndRevisionStability() throws {
        let model = WorkspaceModel(), revision = model.mesh.runtime.revision, topology = model.mesh.runtime.topologyID
        let uploadsBefore = model.profiler?.snapshot()
        let start = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start,
                                                       cameraDirection: SIMD3<Float>(0, 0, -1)))
        model.updateTranslationGizmoDrag(ray: Ray(origin: SIMD3<Float>(0.8, 0.6, 5), direction: SIMD3<Float>(0, 0, -1)),
                                          cameraDirection: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(model.objectTransform.translation.x, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(model.objectTransform.translation.y, 0.3, accuracy: 0.000_1)
        model.endTranslationGizmoDrag(); XCTAssertFalse(model.translationGizmoState.isDragging)
        XCTAssertEqual(model.mesh.runtime.revision, revision); XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertEqual(model.profiler?.snapshot()[.vertexUpload].sampleCount, uploadsBefore?[.vertexUpload].sampleCount)
        XCTAssertEqual(model.profiler?.snapshot()[.indexUpload].sampleCount, uploadsBefore?[.indexUpload].sampleCount)

        let committed = model.objectTransform
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: start,
                                                       cameraDirection: SIMD3<Float>(0, 0, -1)))
        model.updateTranslationGizmoDrag(ray: Ray(origin: SIMD3<Float>(1, 1, 5), direction: SIMD3<Float>(0, 0, -1)),
                                          cameraDirection: SIMD3<Float>(0, 0, -1))
        model.cancelTranslationGizmoDrag()
        XCTAssertEqual(model.objectTransform, committed)
    }

    @MainActor
    func testWorkspaceGizmoCancelsSculptAndFollowsPanelTranslation() {
        let model = WorkspaceModel(); model.beginStroke(); XCTAssertTrue(model.isStrokeActive)
        let ray = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray,
                                                       cameraDirection: SIMD3<Float>(0, 0, -1)))
        XCTAssertFalse(model.isStrokeActive); model.endTranslationGizmoDrag()
        model.updateTranslation(SIMD3<Float>(2, 3, 4))
        XCTAssertEqual(model.objectTransform.translation, SIMD3<Float>(2, 3, 4))
        XCTAssertEqual(model.translationGizmoHit(ray: Ray(origin: SIMD3<Float>(2.3, 3.3, 9), direction: SIMD3<Float>(0, 0, -1)),
                                                 scale: 1)?.handle, .xyPlane)
    }

    @MainActor
    func testBenchmarkBlocksGizmoDrag() async {
        let model = WorkspaceModel(); model.runAllBenchmarks()
        let ray = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertFalse(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: ray,
                                                        cameraDirection: SIMD3<Float>(0, 0, -1)))
        model.cancelBenchmarks()
        for _ in 0..<1_000 where model.isBenchmarkRunning { await Task.yield() }
    }

    func testGizmoUniformSwiftMetalLayout() {
        XCTAssertEqual(MemoryLayout<GizmoUniforms>.stride, 96)
        XCTAssertEqual(MemoryLayout<GizmoUniforms>.offset(of: \GizmoUniforms.origin), 64)
        XCTAssertEqual(MemoryLayout<GizmoUniforms>.offset(of: \GizmoUniforms.scale), 80)
        XCTAssertEqual(MemoryLayout<GizmoUniforms>.offset(of: \GizmoUniforms.hoverHandle), 84)
        XCTAssertEqual(MemoryLayout<GizmoUniforms>.offset(of: \GizmoUniforms.activeHandle), 88)
    }

    func testRotationGizmoHitsWorldAxisRingsAndMissesInvalidAreas() {
        let cases: [(RotationGizmoHandle, Ray)] = [
            (.xAxis, Ray(origin: SIMD3<Float>(5, 0, 0.82), direction: SIMD3<Float>(-1, 0, 0))),
            (.yAxis, Ray(origin: SIMD3<Float>(0, 5, 0.82), direction: SIMD3<Float>(0, -1, 0))),
            (.zAxis, Ray(origin: SIMD3<Float>(0.82, 0, 5), direction: SIMD3<Float>(0, 0, -1))),
        ]
        for (handle, ray) in cases {
            XCTAssertEqual(RotationGizmoGeometry.hit(ray: ray, origin: .zero, scale: 1)?.handle, handle)
        }
        XCTAssertNil(RotationGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(5, 0, 0), direction: SIMD3<Float>(-1, 0, 0)), origin: .zero, scale: 1))
        XCTAssertNil(RotationGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(5, 0, 1.3), direction: SIMD3<Float>(-1, 0, 0)), origin: .zero, scale: 1))
        XCTAssertNil(RotationGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(0, 0, 0.3), direction: SIMD3<Float>(0, 1, 0)), origin: .zero, scale: 1))
        XCTAssertNil(RotationGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(.nan, 0, 1), direction: SIMD3<Float>(-1, 0, 0)), origin: .zero, scale: 1))
    }

    func testRotationGizmoPickingScalesAndUsesStableTieBreak() {
        let scaled = Ray(origin: SIMD3<Float>(5, 0, 1.64), direction: SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(RotationGizmoGeometry.hit(ray: scaled, origin: .zero, scale: 2)?.handle, .xAxis)
        XCTAssertNil(RotationGizmoGeometry.hit(ray: scaled, origin: .zero, scale: 1))
        let tie = Ray(origin: SIMD3<Float>(5, 5, 0.82), direction: simd_normalize(SIMD3<Float>(-1, -1, 0)))
        XCTAssertEqual(RotationGizmoGeometry.hit(ray: tie, origin: .zero, scale: 1)?.handle, .xAxis)
    }

    func testRotationSignedAnglesCoverZeroPositiveNegativeAndPi() throws {
        let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
        XCTAssertEqual(try XCTUnwrap(RotationGizmoGeometry.signedAngle(from: x, to: x, axis: z)), 0, accuracy: 0.000_01)
        XCTAssertEqual(try XCTUnwrap(RotationGizmoGeometry.signedAngle(from: x, to: y, axis: z)), .pi / 2, accuracy: 0.000_01)
        XCTAssertEqual(try XCTUnwrap(RotationGizmoGeometry.signedAngle(from: x, to: -y, axis: z)), -.pi / 2, accuracy: 0.000_01)
        let nearPi = try XCTUnwrap(RotationGizmoGeometry.signedAngle(
            from: x, to: simd_normalize(SIMD3<Float>(-1, 0.000_01, 0)), axis: z))
        XCTAssertTrue(nearPi.isFinite); XCTAssertEqual(abs(nearPi), .pi, accuracy: 0.000_1)
        XCTAssertNil(RotationGizmoGeometry.signedAngle(from: .zero, to: y, axis: z))
        XCTAssertNil(RotationGizmoGeometry.signedAngle(from: SIMD3<Float>(.nan, 0, 0), to: y, axis: z))
    }

    func testRotationGizmoQuaternionUsesWorldSpaceLeftMultiplication() throws {
        for handle in RotationGizmoHandle.allCases {
            let startRay: Ray, currentRay: Ray
            switch handle {
            case .xAxis:
                startRay = Ray(origin: SIMD3<Float>(5, 0, 1), direction: SIMD3<Float>(-1, 0, 0))
                currentRay = Ray(origin: SIMD3<Float>(5, -1, 0), direction: SIMD3<Float>(-1, 0, 0))
            case .yAxis:
                startRay = Ray(origin: SIMD3<Float>(1, 5, 0), direction: SIMD3<Float>(0, -1, 0))
                currentRay = Ray(origin: SIMD3<Float>(0, 5, -1), direction: SIMD3<Float>(0, -1, 0))
            case .zAxis:
                startRay = Ray(origin: SIMD3<Float>(1, 0, 5), direction: SIMD3<Float>(0, 0, -1))
                currentRay = Ray(origin: SIMD3<Float>(0, 1, 5), direction: SIMD3<Float>(0, 0, -1))
            }
            let session = try XCTUnwrap(RotationGizmoGeometry.beginSession(
                handle: handle, ray: startRay, transform: .identity))
            XCTAssertEqual(try XCTUnwrap(RotationGizmoGeometry.rotation(session: session, ray: startRay)).accumulatedAngle,
                           0, accuracy: 0.000_01)
            let update = try XCTUnwrap(RotationGizmoGeometry.rotation(session: session, ray: currentRay))
            XCTAssertEqual(abs(update.accumulatedAngle), .pi / 2, accuracy: 0.000_1)
            XCTAssertEqual(simd_length(update.rotation), 1, accuracy: 0.000_1)
        }

        let start = ObjectTransform(rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(0, 90, 0)),
                                    scale: SIMD3<Float>(2, 3, 4))
        let session = try XCTUnwrap(RotationGizmoGeometry.beginSession(
            handle: .xAxis, ray: Ray(origin: SIMD3<Float>(5, 0, 1), direction: SIMD3<Float>(-1, 0, 0)),
            transform: start))
        let update = try XCTUnwrap(RotationGizmoGeometry.rotation(
            session: session, ray: Ray(origin: SIMD3<Float>(5, -1, 0), direction: SIMD3<Float>(-1, 0, 0))))
        let expected = simd_normalize(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)) * start.quaternion)
        XCTAssertLessThan(min(simd_distance(update.rotation, expected.vector), simd_distance(update.rotation, -expected.vector)), 0.000_1)
        var transformed = start; transformed.rotation = update.rotation
        XCTAssertEqual(transformed.translation, start.translation); XCTAssertEqual(transformed.scale, start.scale)
    }

    func testRotationAngleUnwrapCrossesPositiveAndNegativePiContinuously() throws {
        let positive179 = Float(179) * .pi / 180, negative179 = -positive179
        let beforePositiveCross = try XCTUnwrap(RotationGizmoGeometry.unwrap(
            rawAngle: positive179, lastRawAngle: 0, accumulatedAngle: 0))
        let afterPositiveCross = try XCTUnwrap(RotationGizmoGeometry.unwrap(
            rawAngle: negative179, lastRawAngle: beforePositiveCross.rawAngle,
            accumulatedAngle: beforePositiveCross.accumulatedAngle))
        XCTAssertEqual(afterPositiveCross.accumulatedAngle - beforePositiveCross.accumulatedAngle,
                       2 * .pi / 180, accuracy: 0.000_01)
        XCTAssertEqual(afterPositiveCross.accumulatedAngle, Float(181) * .pi / 180, accuracy: 0.000_01)

        let beforeNegativeCross = try XCTUnwrap(RotationGizmoGeometry.unwrap(
            rawAngle: negative179, lastRawAngle: 0, accumulatedAngle: 0))
        let afterNegativeCross = try XCTUnwrap(RotationGizmoGeometry.unwrap(
            rawAngle: positive179, lastRawAngle: beforeNegativeCross.rawAngle,
            accumulatedAngle: beforeNegativeCross.accumulatedAngle))
        XCTAssertEqual(afterNegativeCross.accumulatedAngle - beforeNegativeCross.accumulatedAngle,
                       -2 * .pi / 180, accuracy: 0.000_01)
        XCTAssertEqual(afterNegativeCross.accumulatedAngle, -Float(181) * .pi / 180, accuracy: 0.000_01)
    }

    func testRotationAngleUnwrapSupportsFullAndDoubleTurnsWithNormalizedQuaternion() throws {
        func accumulate(_ degrees: [Float]) throws -> Float {
            var raw: Float = 0, accumulated: Float = 0
            for degree in degrees {
                let update = try XCTUnwrap(RotationGizmoGeometry.unwrap(
                    rawAngle: degree * .pi / 180, lastRawAngle: raw, accumulatedAngle: accumulated))
                raw = update.rawAngle; accumulated = update.accumulatedAngle
            }
            return accumulated
        }
        let oneTurn = try accumulate([90, 179, -90, 0])
        XCTAssertEqual(oneTurn, 2 * .pi, accuracy: 0.000_1)
        let twoTurns = try accumulate([90, 179, -90, 0, 90, 179, -90, 0])
        XCTAssertEqual(twoTurns, 4 * .pi, accuracy: 0.000_1)
        let transform = ObjectTransform(translation: SIMD3<Float>(1, 2, 3),
                                        rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 20, 30)),
                                        scale: SIMD3<Float>(2, 3, 4))
        let quaternion = try XCTUnwrap(RotationGizmoGeometry.worldRotation(
            startTransform: transform, axis: SIMD3<Float>(0, 1, 0), accumulatedAngle: twoTurns))
        XCTAssertTrue(quaternion.x.isFinite && quaternion.y.isFinite && quaternion.z.isFinite && quaternion.w.isFinite)
        XCTAssertEqual(simd_length(quaternion), 1, accuracy: 0.000_1)
        XCTAssertEqual(transform.translation, SIMD3<Float>(1, 2, 3)); XCTAssertEqual(transform.scale, SIMD3<Float>(2, 3, 4))
    }

    @MainActor
    func testRotationWorkspaceUnwrapSurvivesInvalidRayAndRebuildsFromStart() throws {
        let model = WorkspaceModel(); model.setGizmoMode(.rotate)
        let start = Ray(origin: SIMD3<Float>(5, 0, 1), direction: SIMD3<Float>(-1, 0, 0))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: start))
        func ray(degrees: Float) -> Ray {
            let angle = degrees * .pi / 180
            return Ray(origin: SIMD3<Float>(5, -sin(angle), cos(angle)), direction: SIMD3<Float>(-1, 0, 0))
        }
        model.updateRotationGizmoDrag(ray: ray(degrees: 179))
        let beforeInvalid = try XCTUnwrap(model.rotationGizmoState.dragSession)
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3<Float>(0, 1, 0), direction: SIMD3<Float>(0, 1, 0)))
        let afterInvalid = try XCTUnwrap(model.rotationGizmoState.dragSession)
        XCTAssertEqual(afterInvalid.lastRawAngle, beforeInvalid.lastRawAngle)
        XCTAssertEqual(afterInvalid.accumulatedAngle, beforeInvalid.accumulatedAngle)
        model.updateRotationGizmoDrag(ray: ray(degrees: -179))
        let crossed = try XCTUnwrap(model.rotationGizmoState.dragSession)
        XCTAssertEqual(crossed.accumulatedAngle, Float(181) * .pi / 180, accuracy: 0.000_1)
        let expected = try XCTUnwrap(RotationGizmoGeometry.worldRotation(
            startTransform: crossed.startTransform, axis: crossed.axis,
            accumulatedAngle: crossed.accumulatedAngle))
        XCTAssertLessThan(min(simd_distance(model.objectTransform.rotation, expected),
                              simd_distance(model.objectTransform.rotation, -expected)), 0.000_1)
        XCTAssertEqual(model.objectTransform.translation, crossed.startTransform.translation)
        XCTAssertEqual(model.objectTransform.scale, crossed.startTransform.scale)
    }

    @MainActor
    func testWorkspaceRotationGizmoBeginUpdateEndCancelAndNoMeshUpload() throws {
        let model = WorkspaceModel(); model.setGizmoMode(.rotate)
        let revision = model.mesh.runtime.revision, topology = model.mesh.runtime.topologyID
        let uploads = model.profiler?.snapshot(), original = model.objectTransform
        let start = Ray(origin: SIMD3<Float>(5, 0, 1), direction: SIMD3<Float>(-1, 0, 0))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: start))
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3<Float>(5, -1, 0), direction: SIMD3<Float>(-1, 0, 0)))
        XCTAssertEqual(simd_length(model.objectTransform.rotation), 1, accuracy: 0.000_1)
        let validRotation = model.objectTransform.rotation
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3<Float>(0, 1, 0), direction: SIMD3<Float>(0, 1, 0)))
        XCTAssertEqual(model.objectTransform.rotation, validRotation)
        model.endRotationGizmoDrag(); XCTAssertFalse(model.rotationGizmoState.isDragging)
        XCTAssertEqual(model.mesh.runtime.revision, revision); XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertEqual(model.profiler?.snapshot()[.vertexUpload].sampleCount, uploads?[.vertexUpload].sampleCount)
        XCTAssertEqual(model.profiler?.snapshot()[.indexUpload].sampleCount, uploads?[.indexUpload].sampleCount)

        let committed = model.objectTransform
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: start))
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3<Float>(5, 1, 0), direction: SIMD3<Float>(-1, 0, 0)))
        model.cancelRotationGizmoDrag(); XCTAssertEqual(model.objectTransform, committed)
        XCTAssertNotEqual(model.objectTransform.rotation, original.rotation)
    }

    @MainActor
    func testRotationGizmoModeExclusionSculptCancellationAndPanelSync() {
        let model = WorkspaceModel()
        let revision = model.mesh.runtime.revision, topology = model.mesh.runtime.topologyID
        let translationRay = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        let rotationRay = Ray(origin: SIMD3<Float>(5, 0, 0.82), direction: SIMD3<Float>(-1, 0, 0))
        XCTAssertNotNil(model.translationGizmoHit(ray: translationRay, scale: 1))
        XCTAssertNil(model.rotationGizmoHit(ray: rotationRay, scale: 1))
        model.setGizmoMode(.rotate)
        XCTAssertEqual(model.mesh.runtime.revision, revision); XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertNil(model.translationGizmoHit(ray: translationRay, scale: 1))
        XCTAssertNotNil(model.rotationGizmoHit(ray: rotationRay, scale: 1))
        model.beginStroke(); XCTAssertTrue(model.isStrokeActive)
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: rotationRay))
        XCTAssertFalse(model.isStrokeActive); XCTAssertTrue(model.isGizmoDragging)
        model.setGizmoMode(.translate)
        XCTAssertFalse(model.isGizmoDragging); XCTAssertTrue(model.objectTransform.isIdentity)
        model.updateRotationDegrees(SIMD3<Float>(15, 25, 35))
        XCTAssertTrue(model.objectTransform.rotationDegrees.allFinite)
    }

    @MainActor
    func testRotationGizmoResetLoadAndBenchmarkClearInteraction() async throws {
        let model = WorkspaceModel(); model.setGizmoMode(.rotate)
        let start = Ray(origin: SIMD3<Float>(5, 0, 1), direction: SIMD3<Float>(-1, 0, 0))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: start))
        model.resetTransform(); XCTAssertFalse(model.rotationGizmoState.isDragging); XCTAssertTrue(model.objectTransform.isIdentity)
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: start))
        model.load(data: try model.projectData()); XCTAssertFalse(model.rotationGizmoState.isDragging)
        model.runAllBenchmarks(); XCTAssertFalse(model.isGizmoDragging)
        XCTAssertFalse(model.beginRotationGizmoDrag(handle: .xAxis, ray: start))
        model.cancelBenchmarks()
        for _ in 0..<1_000 where model.isBenchmarkRunning { await Task.yield() }
    }

    func testScaleGizmoHitsAxesUniformCenterAndUsesStablePriority() {
        let cases: [(ScaleGizmoHandle, Ray)] = [
            (.xAxis, Ray(origin: SIMD3<Float>(0.7, 0.05, 5), direction: SIMD3<Float>(0, 0, -1))),
            (.yAxis, Ray(origin: SIMD3<Float>(0.05, 0.7, 5), direction: SIMD3<Float>(0, 0, -1))),
            (.zAxis, Ray(origin: SIMD3<Float>(0.05, 5, 0.7), direction: SIMD3<Float>(0, -1, 0))),
            (.uniform, Ray(origin: SIMD3<Float>(0, 0, 5), direction: SIMD3<Float>(0, 0, -1))),
        ]
        for (handle, ray) in cases {
            XCTAssertEqual(ScaleGizmoGeometry.hit(ray: ray, origin: .zero, scale: 1)?.handle, handle)
        }
        let centerOverlap = Ray(origin: SIMD3<Float>(0.1, 0, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(ScaleGizmoGeometry.hit(ray: centerOverlap, origin: .zero, scale: 1)?.handle, .uniform)
        XCTAssertNil(ScaleGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(1.3, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
            origin: .zero, scale: 1))
        XCTAssertNil(ScaleGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(.nan, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
            origin: .zero, scale: 1))
        XCTAssertNil(ScaleGizmoGeometry.hit(
            ray: Ray(origin: SIMD3<Float>(0.7, 0, 5), direction: .zero), origin: .zero, scale: 1))

        let distanceScaled = Ray(origin: SIMD3<Float>(1.4, 0.15, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertNil(ScaleGizmoGeometry.hit(ray: distanceScaled, origin: .zero, scale: 1))
        XCTAssertEqual(ScaleGizmoGeometry.hit(ray: distanceScaled, origin: .zero, scale: 2)?.handle, .xAxis)
    }

    func testScaleGizmoAxisDragChangesOnlySelectedAxisFromStart() throws {
        let camera = SIMD3<Float>(0, 0, -1)
        let startScale = SIMD3<Float>(2, 3, 4)
        let transform = ObjectTransform(scale: startScale)
        let cases: [(ScaleGizmoHandle, Ray, Ray, SIMD3<Float>)] = [
            (.xAxis,
             Ray(origin: SIMD3<Float>(0.4, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
             Ray(origin: SIMD3<Float>(1.4, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
             SIMD3<Float>(4, 3, 4)),
            (.yAxis,
             Ray(origin: SIMD3<Float>(0, 0.4, 5), direction: SIMD3<Float>(0, 0, -1)),
             Ray(origin: SIMD3<Float>(0, 1.4, 5), direction: SIMD3<Float>(0, 0, -1)),
             SIMD3<Float>(2, 6, 4)),
            (.zAxis,
             Ray(origin: SIMD3<Float>(5, 0, 0.4), direction: SIMD3<Float>(-1, 0, 0)),
             Ray(origin: SIMD3<Float>(5, 0, 1.4), direction: SIMD3<Float>(-1, 0, 0)),
             SIMD3<Float>(2, 3, 8)),
        ]
        for (handle, startRay, currentRay, expected) in cases {
            let session = try XCTUnwrap(ScaleGizmoGeometry.beginSession(
                handle: handle, ray: startRay, transform: transform,
                cameraDirection: camera, referenceLength: 1))
            XCTAssertEqual(try XCTUnwrap(ScaleGizmoGeometry.scale(
                session: session, ray: startRay, cameraDirection: camera)), startScale)
            XCTAssertEqual(try XCTUnwrap(ScaleGizmoGeometry.scale(
                session: session, ray: currentRay, cameraDirection: camera)), expected)
        }

        let session = try XCTUnwrap(ScaleGizmoGeometry.beginSession(
            handle: .xAxis,
            ray: Ray(origin: SIMD3<Float>(0.4, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
            transform: transform, cameraDirection: camera, referenceLength: 1))
        let first = try XCTUnwrap(ScaleGizmoGeometry.scale(
            session: session,
            ray: Ray(origin: SIMD3<Float>(1.4, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: camera))
        let second = try XCTUnwrap(ScaleGizmoGeometry.scale(
            session: session,
            ray: Ray(origin: SIMD3<Float>(0.9, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: camera))
        XCTAssertEqual(first.x, 4, accuracy: 0.000_1)
        XCTAssertEqual(second.x, 3, accuracy: 0.000_1)
    }

    func testScaleGizmoAxisFallbackAndClampRemainFinite() throws {
        let nearParallel = simd_normalize(SIMD3<Float>(-0.01, -0.1, -1))
        let point = TranslationGizmoGeometry.axisConstraintPoint(
            ray: Ray(origin: SIMD3<Float>(0.4, 0.2, 5), direction: nearParallel),
            origin: .zero, axis: SIMD3<Float>(0, 0, 1), cameraDirection: nearParallel)
        XCTAssertNotNil(point); XCTAssertTrue(try XCTUnwrap(point).allFinite)
        let fallbackRay = Ray(origin: SIMD3<Float>(0.4, 0.2, 5), direction: nearParallel)
        let fallbackSession = try XCTUnwrap(ScaleGizmoGeometry.beginSession(
            handle: .zAxis, ray: fallbackRay, transform: .identity,
            cameraDirection: nearParallel, referenceLength: 1))
        XCTAssertTrue(try XCTUnwrap(ScaleGizmoGeometry.scale(
            session: fallbackSession, ray: fallbackRay,
            cameraDirection: nearParallel)).allFinite)
        XCTAssertNil(TranslationGizmoGeometry.axisConstraintPoint(
            ray: Ray(origin: SIMD3<Float>(0, 0, 5), direction: SIMD3<Float>(0, 0, -1)),
            origin: .zero, axis: SIMD3<Float>(0, 0, 1), cameraDirection: .zero))

        let minimum = try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 3, 4), handle: .xAxis, factor: -10))
        XCTAssertEqual(minimum, SIMD3<Float>(ObjectTransform.minimumScaleMagnitude, 3, 4))
        let maximum = try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 3, 4), handle: .zAxis, factor: 10_000))
        XCTAssertEqual(maximum, SIMD3<Float>(2, 3, ObjectTransform.maximumScaleMagnitude))
        let finiteExtreme = try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 3, 4), handle: .xAxis,
            factor: Float.greatestFiniteMagnitude))
        XCTAssertEqual(finiteExtreme.x, ObjectTransform.maximumScaleMagnitude)
        XCTAssertTrue(finiteExtreme.allFinite)
        XCTAssertNil(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 3, 4), handle: .xAxis, factor: .nan))
        XCTAssertNil(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, .infinity, 4), handle: .uniform, factor: 2))
    }

    func testScaleGizmoUniformScalePreservesNonUniformRatiosAndClampsGlobally() throws {
        XCTAssertEqual(try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(repeating: 1), handle: .uniform, factor: 2)),
                       SIMD3<Float>(repeating: 2))
        let doubled = try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 1, 0.5), handle: .uniform, factor: 2))
        XCTAssertEqual(doubled, SIMD3<Float>(4, 2, 1))
        XCTAssertEqual(doubled.x / doubled.y, 2, accuracy: 0.000_1)
        XCTAssertEqual(doubled.y / doubled.z, 2, accuracy: 0.000_1)

        let minimum = try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 1, 0.5), handle: .uniform, factor: -1))
        XCTAssertEqual(minimum.x, 0.004, accuracy: 0.000_001)
        XCTAssertEqual(minimum.y, 0.002, accuracy: 0.000_001)
        XCTAssertEqual(minimum.z, 0.001, accuracy: 0.000_001)
        let maximum = try XCTUnwrap(ScaleGizmoGeometry.applyFactor(
            startScale: SIMD3<Float>(2, 1, 0.5), handle: .uniform, factor: 10_000))
        XCTAssertEqual(maximum, SIMD3<Float>(1_000, 500, 250))
        XCTAssertTrue(minimum.allFinite && maximum.allFinite)
    }

    func testScaleGizmoUniformDragUsesCameraPlaneAndIgnoresInvalidFrame() throws {
        let camera = SIMD3<Float>(0, 0, -1)
        let startRay = Ray(origin: SIMD3<Float>(0, 0, 5), direction: camera)
        let transform = ObjectTransform(scale: SIMD3<Float>(2, 1, 0.5))
        let session = try XCTUnwrap(ScaleGizmoGeometry.beginSession(
            handle: .uniform, ray: startRay, transform: transform,
            cameraDirection: camera, referenceLength: 1))
        let direction = try XCTUnwrap(session.uniformDirection)
        let currentRay = Ray(origin: direction + SIMD3<Float>(0, 0, 5), direction: camera)
        XCTAssertEqual(try XCTUnwrap(ScaleGizmoGeometry.scale(
            session: session, ray: currentRay, cameraDirection: camera)), SIMD3<Float>(4, 2, 1))
        XCTAssertNil(ScaleGizmoGeometry.scale(
            session: session,
            ray: Ray(origin: SIMD3<Float>(0, 0, 5), direction: SIMD3<Float>(1, 0, 0)),
            cameraDirection: camera))
        XCTAssertNil(ScaleGizmoGeometry.scale(
            session: session,
            ray: Ray(origin: SIMD3<Float>(0, 0, 5), direction: SIMD3<Float>(.nan, 0, 0)),
            cameraDirection: camera))
    }

    @MainActor
    func testWorkspaceScaleGizmoLifecyclePreservesTransformPartsMeshAndUploads() throws {
        let model = WorkspaceModel(); model.setGizmoMode(.scale)
        let original = ObjectTransform(translation: SIMD3<Float>(2, 3, 4),
            rotation: ObjectTransform.rotation(degrees: SIMD3<Float>(10, 20, 30)),
            scale: SIMD3<Float>(2, 3, 4))
        model.updateTransform(original)
        let revision = model.mesh.runtime.revision, topology = model.mesh.runtime.topologyID
        let uploads = model.profiler?.snapshot()
        let start = Ray(origin: SIMD3<Float>(2.4, 3, 9), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: start,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1),
                                                 referenceLength: 1))
        model.updateScaleGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(3.4, 3, 9), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(model.objectTransform.scale, SIMD3<Float>(4, 3, 4))
        XCTAssertEqual(model.objectTransform.translation, original.translation)
        XCTAssertEqual(model.objectTransform.rotation, original.rotation)
        let valid = try XCTUnwrap(model.scaleGizmoState.dragSession).lastValidScale
        model.updateScaleGizmoDrag(
            ray: Ray(origin: .zero, direction: .zero), cameraDirection: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(model.objectTransform.scale, valid)
        XCTAssertEqual(try XCTUnwrap(model.scaleGizmoState.dragSession).lastValidScale, valid)
        model.beginStroke(); XCTAssertFalse(model.isStrokeActive)
        model.endScaleGizmoDrag(); XCTAssertFalse(model.isGizmoDragging)
        XCTAssertEqual(model.mesh.runtime.revision, revision)
        XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertEqual(model.profiler?.snapshot()[.vertexUpload].sampleCount,
                       uploads?[.vertexUpload].sampleCount)
        XCTAssertEqual(model.profiler?.snapshot()[.indexUpload].sampleCount,
                       uploads?[.indexUpload].sampleCount)

        let committed = model.objectTransform
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: start,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1),
                                                 referenceLength: 1))
        model.updateScaleGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(4.4, 3, 9), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        model.cancelScaleGizmoDrag()
        XCTAssertEqual(model.objectTransform, committed)
    }

    @MainActor
    func testScaleGizmoModeExclusionSculptCancellationPanelSyncAndReset() throws {
        let model = WorkspaceModel()
        let translationRay = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        let rotationRay = Ray(origin: SIMD3<Float>(5, 0, 0.82), direction: SIMD3<Float>(-1, 0, 0))
        let scaleRay = Ray(origin: SIMD3<Float>(0.7, 0.05, 5), direction: SIMD3<Float>(0, 0, -1))
        let revision = model.mesh.runtime.revision, topology = model.mesh.runtime.topologyID
        XCTAssertNotNil(model.translationGizmoHit(ray: translationRay, scale: 1))
        XCTAssertNil(model.rotationGizmoHit(ray: rotationRay, scale: 1))
        XCTAssertNil(model.scaleGizmoHit(ray: scaleRay, scale: 1))

        model.setGizmoMode(.scale)
        XCTAssertEqual(model.mesh.runtime.revision, revision)
        XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertNil(model.translationGizmoHit(ray: translationRay, scale: 1))
        XCTAssertNil(model.rotationGizmoHit(ray: rotationRay, scale: 1))
        XCTAssertNotNil(model.scaleGizmoHit(ray: scaleRay, scale: 1))
        model.updateScaleGizmoHover(ray: scaleRay, scale: 1)
        XCTAssertEqual(model.scaleGizmoState.hoverHandle, .xAxis)
        model.beginStroke(); XCTAssertTrue(model.isStrokeActive)
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: scaleRay,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1),
                                                 referenceLength: 1))
        XCTAssertFalse(model.isStrokeActive)
        model.updateScaleGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(1.2, 0.05, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        model.setGizmoMode(.rotate)
        XCTAssertFalse(model.isGizmoDragging)
        XCTAssertNil(model.scaleGizmoState.hoverHandle)
        XCTAssertTrue(model.objectTransform.isIdentity)

        model.updateScale(SIMD3<Float>(0, -2, 2_000))
        XCTAssertEqual(model.objectTransform.scale,
                       SIMD3<Float>(ObjectTransform.minimumScaleMagnitude, 2,
                                    ObjectTransform.maximumScaleMagnitude))
        model.resetTransform(); XCTAssertTrue(model.objectTransform.isIdentity)
        model.setTranslationGizmoVisible(false)
        model.setGizmoMode(.scale)
        XCTAssertNil(model.scaleGizmoHit(ray: scaleRay, scale: 1))
    }

    @MainActor
    func testScaleGizmoLoadAndBenchmarkCancelInteraction() async throws {
        let model = WorkspaceModel(); model.setGizmoMode(.scale)
        let start = Ray(origin: SIMD3<Float>(0.4, 0, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: start,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1),
                                                 referenceLength: 1))
        model.resetTransform()
        XCTAssertFalse(model.scaleGizmoState.isDragging)
        XCTAssertTrue(model.objectTransform.isIdentity)
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: start,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1),
                                                 referenceLength: 1))
        model.load(data: try model.projectData())
        XCTAssertFalse(model.scaleGizmoState.isDragging)
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: start,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1),
                                                 referenceLength: 1))
        model.runAllBenchmarks()
        XCTAssertFalse(model.isGizmoDragging)
        XCTAssertFalse(model.beginScaleGizmoDrag(handle: .xAxis, ray: start,
                                                  cameraDirection: SIMD3<Float>(0, 0, -1),
                                                  referenceLength: 1))
        model.cancelBenchmarks()
        for _ in 0..<1_000 where model.isBenchmarkRunning { await Task.yield() }
    }

    func testTransformCommandRejectsNoOpAndNonFiniteValues() {
        XCTAssertNil(TransformCommand(before: .identity, after: .identity))
        var equivalent = ObjectTransform.identity
        equivalent.rotation = -equivalent.rotation
        XCTAssertNil(TransformCommand(before: .identity, after: equivalent))
        var invalid = ObjectTransform.identity
        invalid.translation.x = .nan
        XCTAssertNil(TransformCommand(before: .identity, after: invalid))
        XCTAssertNotNil(TransformCommand(
            before: .identity,
            after: ObjectTransform(translation: SIMD3<Float>(0.01, 0, 0))))
    }

    @MainActor
    func testTransformPanelTransactionCoalescesLiveUpdatesAndSupportsUndoRedo() {
        let model = WorkspaceModel()
        model.beginTransformPanelTransaction()
        model.updateTranslation(SIMD3<Float>(1, 0, 0))
        model.updateTranslation(SIMD3<Float>(2, 3, 4))
        model.updateRotationDegrees(SIMD3<Float>(10, 20, 30))
        model.updateScale(SIMD3<Float>(2, 3, 4))
        XCTAssertEqual(model.undoCount, 0)
        XCTAssertTrue(model.isTransformPanelEditing)
        let final = model.objectTransform
        model.commitTransformPanelTransaction()
        XCTAssertEqual(model.undoCount, 1)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.objectTransform.isIdentity)
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.objectTransform, final)
    }

    @MainActor
    func testTransformPanelFocusTransactionsAndResetAreSeparateCommands() {
        let model = WorkspaceModel()
        model.beginTransformPanelTransaction()
        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        model.commitTransformPanelTransaction()
        model.beginTransformPanelTransaction()
        model.updateScale(SIMD3<Float>(2, 2, 2))
        model.commitTransformPanelTransaction()
        XCTAssertEqual(model.undoCount, 2)
        let transformed = model.objectTransform
        model.resetTransform()
        XCTAssertEqual(model.undoCount, 3)
        model.undo()
        XCTAssertEqual(model.objectTransform, transformed)
        model.redo()
        XCTAssertTrue(model.objectTransform.isIdentity)
        model.resetTransform()
        XCTAssertEqual(model.undoCount, 3)
    }

    @MainActor
    func testEachGizmoDragRecordsExactlyOneTransformCommandAndCancelRecordsNone() throws {
        let model = WorkspaceModel()
        let moveStart = Ray(origin: SIMD3<Float>(0.3, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginTranslationGizmoDrag(handle: .xyPlane, ray: moveStart,
                                                       cameraDirection: SIMD3<Float>(0, 0, -1)))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(0.8, 0.6, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        model.updateTranslationGizmoDrag(
            ray: Ray(origin: SIMD3<Float>(1.0, 0.7, 5), direction: SIMD3<Float>(0, 0, -1)),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        model.endTranslationGizmoDrag()
        XCTAssertEqual(model.undoCount, 1)

        model.setGizmoMode(.rotate)
        let rotateStart = Ray(origin: SIMD3<Float>(5, 0, 1), direction: SIMD3<Float>(-1, 0, 0))
        XCTAssertTrue(model.beginRotationGizmoDrag(handle: .xAxis, ray: rotateStart))
        model.updateRotationGizmoDrag(ray: Ray(origin: SIMD3<Float>(5, -1, 0), direction: SIMD3<Float>(-1, 0, 0)))
        model.endRotationGizmoDrag()
        XCTAssertEqual(model.undoCount, 2)

        model.setGizmoMode(.scale)
        let scaleStart = Ray(origin: model.objectTransform.translation + SIMD3<Float>(0.4, 0, 5),
                             direction: SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: scaleStart,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1), referenceLength: 1))
        model.updateScaleGizmoDrag(
            ray: Ray(origin: scaleStart.origin + SIMD3<Float>(0.5, 0, 0), direction: scaleStart.direction),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        model.endScaleGizmoDrag()
        XCTAssertEqual(model.undoCount, 3)
        let committed = model.objectTransform
        XCTAssertTrue(model.beginScaleGizmoDrag(handle: .xAxis, ray: scaleStart,
                                                 cameraDirection: SIMD3<Float>(0, 0, -1), referenceLength: 1))
        model.updateScaleGizmoDrag(
            ray: Ray(origin: scaleStart.origin + SIMD3<Float>(1, 0, 0), direction: scaleStart.direction),
            cameraDirection: SIMD3<Float>(0, 0, -1))
        model.cancelScaleGizmoDrag()
        XCTAssertEqual(model.objectTransform, committed)
        XCTAssertEqual(model.undoCount, 3)
    }

    @MainActor
    func testUnifiedHistoryPreservesSculptAndTransformChronology() {
        let model = WorkspaceModel()
        let initialMesh = model.mesh
        let sample = PencilSample(location: .zero, force: 1, maximumForce: 1,
                                  altitude: 1, azimuth: 0, timestamp: 0)
        let ray = Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1))
        model.beginStroke(); model.updateStroke(sample: sample, ray: ray); model.endStroke()
        let sculptA = model.mesh
        model.updateTranslation(SIMD3<Float>(1, 0, 0))
        let moved = model.objectTransform
        let transformedRay = Ray(origin: moved.worldPosition(fromLocal: SIMD3<Float>(0, 0, 3)),
                                 direction: moved.worldDirection(fromLocal: SIMD3<Float>(0, 0, -1)))
        model.beginStroke(); model.updateStroke(sample: sample, ray: transformedRay); model.endStroke()
        let sculptB = model.mesh
        model.updateScale(SIMD3<Float>(2, 2, 2))
        XCTAssertEqual(model.undoCount, 4)

        model.undo(); XCTAssertEqual(model.objectTransform, moved); XCTAssertEqual(model.mesh, sculptB)
        model.undo(); XCTAssertEqual(model.mesh, sculptA); XCTAssertEqual(model.objectTransform, moved)
        model.undo(); XCTAssertTrue(model.objectTransform.isIdentity); XCTAssertEqual(model.mesh, sculptA)
        model.undo(); XCTAssertEqual(model.mesh, initialMesh)
        model.redo(); XCTAssertEqual(model.mesh, sculptA)
        model.redo(); XCTAssertEqual(model.objectTransform, moved)
        model.redo(); XCTAssertEqual(model.mesh, sculptB)
        model.redo(); XCTAssertEqual(model.objectTransform.scale, SIMD3<Float>(repeating: 2))
    }

    @MainActor
    func testNewMeaningfulEditInvalidatesRedoButNoOpDoesNot() {
        let model = WorkspaceModel()
        model.updateTranslation(SIMD3<Float>(1, 0, 0))
        model.undo()
        XCTAssertEqual(model.redoCount, 1)
        model.updateTransform(.identity)
        XCTAssertEqual(model.redoCount, 1)
        model.updateTranslation(SIMD3<Float>(2, 0, 0))
        XCTAssertEqual(model.redoCount, 0)
        XCTAssertFalse(model.canRedo)
    }

    @MainActor
    func testLoadClearsUnifiedHistoryAndTransformPanelTransaction() throws {
        let model = WorkspaceModel()
        let data = try model.projectData()
        model.updateTranslation(SIMD3<Float>(1, 2, 3))
        model.beginTransformPanelTransaction()
        model.updateScale(SIMD3<Float>(2, 2, 2))
        model.load(data: data)
        XCTAssertTrue(model.objectTransform.isIdentity)
        XCTAssertEqual(model.undoCount, 0); XCTAssertEqual(model.redoCount, 0)
        XCTAssertFalse(model.canUndo); XCTAssertFalse(model.canRedo)
        XCTAssertFalse(model.isTransformPanelEditing)
    }

    @MainActor
    func testTransformUndoRedoDoesNotChangeMeshRevisionOrUploadMetrics() {
        let model = WorkspaceModel()
        let revision = model.mesh.runtime.revision, topology = model.mesh.runtime.topologyID
        let uploads = model.profiler?.snapshot()
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3), scale: SIMD3<Float>(2, 3, 4)))
        model.undo(); model.redo()
        XCTAssertEqual(model.mesh.runtime.revision, revision)
        XCTAssertEqual(model.mesh.runtime.topologyID, topology)
        XCTAssertEqual(model.profiler?.snapshot()[.vertexUpload].sampleCount,
                       uploads?[.vertexUpload].sampleCount)
        XCTAssertEqual(model.profiler?.snapshot()[.indexUpload].sampleCount,
                       uploads?[.indexUpload].sampleCount)
    }

    func testUVSphereTopologyCountsPolesNormalsAndDeterminism() throws {
        let mesh = try PrimitiveMeshBuilder.sphere(radius: 0.5, longitudeSegments: 32, latitudeRings: 16)
        XCTAssertEqual(mesh.vertices.count, 2 + 32 * 15)
        XCTAssertEqual(mesh.indices.count / 3, 2 * 32 * 15)
        XCTAssertEqual(mesh.vertices.filter { simd_distance($0.position, SIMD3<Float>(0, 0.5, 0)) < 0.000_001 }.count, 1)
        XCTAssertEqual(mesh.vertices.filter { simd_distance($0.position, SIMD3<Float>(0, -0.5, 0)) < 0.000_001 }.count, 1)
        XCTAssertTrue(mesh.vertices.allSatisfy { abs(simd_length($0.position) - 0.5) < 0.000_1 })
        XCTAssertTrue(mesh.vertices.allSatisfy { $0.normal.allFinite && abs(simd_length($0.normal) - 1) < 0.000_1 })
        XCTAssertEqual(mesh, try PrimitiveMeshBuilder.sphere(radius: 0.5, longitudeSegments: 32, latitudeRings: 16))
        assertClosedOutwardMesh(mesh)
    }

    func testUVSphereMinimumAndHighValidSegmentsHaveNoSeamOrDegeneracy() throws {
        let minimum = try PrimitiveMeshBuilder.sphere(radius: 0.001, longitudeSegments: 3, latitudeRings: 2)
        XCTAssertEqual(minimum.vertices.count, 5); XCTAssertEqual(minimum.indices.count / 3, 6)
        assertClosedOutwardMesh(minimum, areaEpsilon: 0.000_000_000_001)
        let high = try PrimitiveMeshBuilder.sphere(radius: 1, longitudeSegments: 128, latitudeRings: 128)
        XCTAssertEqual(high.vertices.count, 2 + 128 * 127)
        XCTAssertNoThrow(try high.validated())
    }

    func testCubeUsesEightSharedVerticesAndTwelveOutwardTriangles() throws {
        let mesh = try PrimitiveMeshBuilder.cube(size: 2)
        XCTAssertEqual(mesh.vertices.count, 8); XCTAssertEqual(mesh.indices.count, 36)
        XCTAssertEqual(mesh.indices.count / 3, 12)
        XCTAssertEqual(mesh.bounds.minimum, SIMD3<Float>(repeating: -1))
        XCTAssertEqual(mesh.bounds.maximum, SIMD3<Float>(repeating: 1))
        XCTAssertEqual(mesh, try PrimitiveMeshBuilder.cube(size: 2))
        assertClosedOutwardMesh(mesh)
    }

    func testCylinderCountsDimensionsSegmentsAndDeterminism() throws {
        for (radial, heightSegments) in [(32, 1), (3, 1), (12, 4)] {
            let mesh = try PrimitiveMeshBuilder.cylinder(radius: 0.5, height: 2,
                                                         radialSegments: radial, heightSegments: heightSegments)
            XCTAssertEqual(mesh.vertices.count, (heightSegments + 1) * radial + 2)
            XCTAssertEqual(mesh.indices.count / 3, 2 * radial * heightSegments + 2 * radial)
            XCTAssertEqual(mesh.bounds.minimum.y, -1, accuracy: 0.000_01)
            XCTAssertEqual(mesh.bounds.maximum.y, 1, accuracy: 0.000_01)
            XCTAssertTrue(mesh.vertices.dropLast(2).allSatisfy {
                abs(simd_length(SIMD2<Float>($0.position.x, $0.position.z)) - 0.5) < 0.000_1
            })
            assertClosedOutwardMesh(mesh)
        }
        XCTAssertEqual(try PrimitiveMeshBuilder.cylinder(radius: 0.5, height: 1, radialSegments: 8, heightSegments: 2),
                       try PrimitiveMeshBuilder.cylinder(radius: 0.5, height: 1, radialSegments: 8, heightSegments: 2))
    }

    func testPrimitiveInputValidationRejectsInvalidAndAcceptsExtremeFiniteValues() throws {
        XCTAssertThrowsError(try PrimitiveMeshBuilder.sphere(radius: 0, longitudeSegments: 32, latitudeRings: 16))
        XCTAssertThrowsError(try PrimitiveMeshBuilder.cube(size: -1))
        XCTAssertThrowsError(try PrimitiveMeshBuilder.cube(size: .nan))
        XCTAssertThrowsError(try PrimitiveMeshBuilder.cube(size: .infinity))
        XCTAssertThrowsError(try PrimitiveMeshBuilder.sphere(radius: 1, longitudeSegments: 2, latitudeRings: 16))
        XCTAssertThrowsError(try PrimitiveMeshBuilder.sphere(radius: 1, longitudeSegments: 257, latitudeRings: 16))
        XCTAssertThrowsError(try PrimitiveMeshBuilder.cylinder(radius: 1, height: 0, radialSegments: 8, heightSegments: 1))
        XCTAssertNoThrow(try PrimitiveMeshBuilder.cube(size: 0.001))
        XCTAssertNoThrow(try PrimitiveMeshBuilder.cube(size: 1_000))
    }

    @MainActor
    func testPrimitiveReplacementResetsStateFramesCameraAndIsOneUndoCommand() throws {
        let model = WorkspaceModel()
        model.updateTransform(ObjectTransform(translation: SIMD3<Float>(1, 2, 3), scale: SIMD3<Float>(2, 3, 4)))
        let beforeMesh = model.mesh, beforeTransform = model.objectTransform, beforeCamera = model.camera
        let count = model.undoCount
        var parameters = PrimitiveParameters(kind: .cube); parameters.size = 2
        try model.createPrimitive(parameters: parameters)
        XCTAssertEqual(model.mesh.vertices.count, 8); XCTAssertTrue(model.objectTransform.isIdentity)
        XCTAssertEqual(model.undoCount, count + 1); XCTAssertTrue(model.camera.distance.isFinite)
        XCTAssertTrue(model.camera.target.allFinite); XCTAssertNil(model.hoverLocation)
        let cube = model.mesh, cubeCamera = model.camera
        XCTAssertNotEqual(cube.runtime.topologyID, beforeMesh.runtime.topologyID)
        XCTAssertTrue(cube.hasCachedAdjacency)
        let cache = MeshBVHCache()
        XCTAssertNotNil(cache.index(for: beforeMesh)); XCTAssertEqual(cache.buildCount, 1)
        XCTAssertNotNil(cache.index(for: cube)); XCTAssertEqual(cache.buildCount, 2)
        model.undo()
        XCTAssertEqual(model.mesh, beforeMesh); XCTAssertEqual(model.objectTransform, beforeTransform)
        XCTAssertEqual(model.camera, beforeCamera)
        model.redo()
        XCTAssertEqual(model.mesh, cube); XCTAssertTrue(model.objectTransform.isIdentity)
        XCTAssertEqual(model.camera, cubeCamera)
    }

    @MainActor
    func testPrimitiveReplacementCancelsActiveEditingAndRedoSnapshotIsNotPolluted() throws {
        let model = WorkspaceModel()
        model.beginStroke(); XCTAssertTrue(model.isStrokeActive)
        var cube = PrimitiveParameters(kind: .cube); cube.size = 1
        try model.createPrimitive(parameters: cube)
        XCTAssertFalse(model.isStrokeActive); XCTAssertFalse(model.isGizmoDragging)
        model.undo(); let restored = model.mesh
        model.beginStroke()
        let sample = PencilSample(location: .zero, force: 1, maximumForce: 1, altitude: 1, azimuth: 0, timestamp: 0)
        model.updateStroke(sample: sample, ray: Ray(origin: SIMD3<Float>(0, 0, 3), direction: SIMD3<Float>(0, 0, -1)))
        model.endStroke()
        XCTAssertNotEqual(model.mesh, restored); XCTAssertFalse(model.canRedo)
    }

    @MainActor
    func testPrimitiveSaveLoadRoundTripUsesFoundationV1MeshOnly() throws {
        for kind in PrimitiveKind.allCases {
            let model = WorkspaceModel(); var parameters = PrimitiveParameters(kind: kind)
            if kind == .cube { parameters.size = 1.25 }
            try model.createPrimitive(parameters: parameters)
            let expected = model.mesh, data = try model.projectData()
            let decoded = try ProjectCodec.decode(data)
            XCTAssertEqual(decoded.formatVersion, 1); XCTAssertEqual(decoded.mesh, expected)
            XCTAssertTrue(decoded.transform.isIdentity)
            let loaded = WorkspaceModel(); loaded.load(data: data)
            XCTAssertEqual(loaded.mesh, expected); XCTAssertEqual(loaded.undoCount, 0)
        }
    }

    @MainActor
    func testPrimitiveGenerationIsRejectedDuringBenchmarkWithoutHistoryPollution() async {
        let model = WorkspaceModel(); model.updateTranslation(SIMD3<Float>(1, 0, 0))
        let mesh = model.mesh, transform = model.objectTransform, undoCount = model.undoCount
        model.runAllBenchmarks()
        XCTAssertThrowsError(try model.createPrimitive(parameters: PrimitiveParameters(kind: .cube)))
        model.cancelBenchmarks()
        for _ in 0..<2_000 where model.isBenchmarkRunning { await Task.yield() }
        XCTAssertEqual(model.mesh, mesh); XCTAssertEqual(model.objectTransform, transform)
        XCTAssertEqual(model.undoCount, undoCount)
    }

    @MainActor
    func testPrimitiveTopologyReplacementUploadsEachMetalBufferOnceThenSkips() throws {
        let profiler = PerformanceProfiler(), view = MTKView()
        let renderer = try XCTUnwrap(MetalRenderer(view: view, profiler: profiler))
        renderer.update(mesh: .icosphere(subdivisions: 0))
        let cube = try PrimitiveMeshBuilder.cube(size: 1)
        profiler.reset(vertexCount: cube.vertices.count, triangleCount: cube.indices.count / 3)
        renderer.update(mesh: cube)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
        renderer.update(mesh: cube)
        XCTAssertEqual(profiler.snapshot()[.vertexUpload].sampleCount, 1)
        XCTAssertEqual(profiler.snapshot()[.indexUpload].sampleCount, 1)
    }

    private func assertClosedOutwardMesh(_ mesh: EditableMesh, areaEpsilon: Float = 0.000_000_01,
                                         file: StaticString = #filePath, line: UInt = #line) {
        var edgeCounts: [UInt64: Int] = [:], triangles = Set<String>()
        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ids = [mesh.indices[start], mesh.indices[start + 1], mesh.indices[start + 2]]
            let a = mesh.vertices[Int(ids[0])].position, b = mesh.vertices[Int(ids[1])].position
            let c = mesh.vertices[Int(ids[2])].position, cross = simd_cross(b - a, c - a)
            XCTAssertGreaterThan(simd_length(cross) * 0.5, areaEpsilon, file: file, line: line)
            XCTAssertGreaterThan(simd_dot(cross, (a + b + c) / 3), 0, file: file, line: line)
            triangles.insert(ids.sorted().map { String($0) }.joined(separator: ","))
            for (u, v) in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
                let low = min(u, v), high = max(u, v), key = (UInt64(low) << 32) | UInt64(high)
                edgeCounts[key, default: 0] += 1
            }
        }
        XCTAssertEqual(triangles.count, mesh.indices.count / 3, file: file, line: line)
        XCTAssertTrue(edgeCounts.values.allSatisfy { $0 == 2 }, file: file, line: line)
        var copy = mesh, adjacency = copy.adjacency()
        for vertex in adjacency.indices { for neighbor in adjacency[vertex] {
            XCTAssertTrue(adjacency[neighbor].contains(vertex), file: file, line: line)
        } }
    }

    private func assertMatrix(_ lhs: simd_float4x4, equals rhs: simd_float4x4,
                              file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 { for row in 0..<4 {
            XCTAssertEqual(lhs[column][row], rhs[column][row], accuracy: 0.000_01, file: file, line: line)
        } }
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
