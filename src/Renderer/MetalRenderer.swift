import Foundation
import MetalKit
import simd

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let gizmoRenderer: TranslationGizmoRenderer
    private let profiler: PerformanceProfiler?
    private var depthState: MTLDepthStencilState
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var uploadedRevision: UInt64?
    private var uploadedTopologyID: UUID?
    var camera = CameraState()
    var objectTransform = ObjectTransform.identity
    var gizmoState = TranslationGizmoState()
    var showsTranslationGizmo = true
    private(set) var gizmoWorldScale: Float = 1
    private(set) var viewProjection = matrix_identity_float4x4

    init?(view: MTKView, profiler: PerformanceProfiler?) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue; self.profiler = profiler
        view.device = device; view.depthStencilPixelFormat = .depth32Float; view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1)
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "meshVertex"),
              let fragment = library.makeFunction(name: "meshFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let gizmoRenderer = TranslationGizmoRenderer(device: device, library: library,
                                                            colorPixelFormat: view.colorPixelFormat,
                                                            depthPixelFormat: view.depthStencilPixelFormat) else { return nil }
        self.pipeline = pipeline
        self.gizmoRenderer = gizmoRenderer
        let depth = MTLDepthStencilDescriptor(); depth.isDepthWriteEnabled = true; depth.depthCompareFunction = .less
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.depthState = depthState
        super.init()
    }

    func update(mesh: EditableMesh) {
        profiler?.updateMeshCounts(vertexCount: mesh.vertices.count, triangleCount: mesh.indices.count / 3)
        let vertexByteCount = MemoryLayout<MeshVertex>.stride * mesh.vertices.count
        let topologyChanged = uploadedTopologyID != mesh.runtime.topologyID
        if topologyChanged {
            PerformanceProfiler.measure(profiler, metric: .indexUpload) {
                let indexByteCount = MemoryLayout<UInt32>.stride * mesh.indices.count
                indexBuffer = makeOrReuse(buffer: indexBuffer, requiredLength: indexByteCount)
                copy(mesh.indices, to: indexBuffer, byteCount: indexByteCount)
                indexCount = mesh.indices.count
                uploadedTopologyID = mesh.runtime.topologyID
                uploadedRevision = nil
            }
        }
        guard uploadedRevision != mesh.runtime.revision else { return }
        PerformanceProfiler.measure(profiler, metric: .vertexUpload) {
            vertexBuffer = makeOrReuse(buffer: vertexBuffer, requiredLength: vertexByteCount)
            copy(mesh.vertices, to: vertexBuffer, byteCount: vertexByteCount)
            uploadedRevision = mesh.runtime.revision
        }
    }

    private func makeOrReuse(buffer: MTLBuffer?, requiredLength: Int) -> MTLBuffer? {
        guard requiredLength > 0 else { return nil }
        if let buffer, buffer.length >= requiredLength { return buffer }
        return device.makeBuffer(length: requiredLength, options: .storageModeShared)
    }

    private func copy<Element>(_ values: [Element], to buffer: MTLBuffer?, byteCount: Int) {
        guard let buffer, byteCount > 0 else { return }
        values.withUnsafeBufferPointer { elements in
            guard let source = elements.baseAddress else { return }
            buffer.contents().copyMemory(from: source, byteCount: byteCount)
        }
    }

    func draw(in view: MTKView) {
        profiler?.recordFrameBoundary()
        PerformanceProfiler.measure(profiler, metric: .frameCPU) {
            drawFrame(in: view)
        }
    }

    private func drawFrame(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass),
              let vertexBuffer, let indexBuffer else { return }
        updateMatrices(size: view.drawableSize)
        var uniforms = Uniforms(viewProjection: viewProjection, model: objectTransform.modelMatrix,
                                normalMatrix: objectTransform.normalMatrix)
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        if showsTranslationGizmo {
            gizmoRenderer.encode(encoder: encoder, viewProjection: viewProjection,
                                 origin: objectTransform.translation, scale: gizmoWorldScale, state: gizmoState)
        }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { updateMatrices(size: size) }

    func ray(at point: CGPoint, viewSize: CGSize) -> Ray? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let x = Float(2 * point.x / viewSize.width - 1)
        let y = Float(1 - 2 * point.y / viewSize.height)
        let inverse = viewProjection.inverse
        let near4 = inverse * SIMD4<Float>(x, y, 0, 1)
        let far4 = inverse * SIMD4<Float>(x, y, 1, 1)
        let near = near4.xyz / near4.w, far = far4.xyz / far4.w
        return Ray(origin: near, direction: simd_normalize(far - near))
    }

    private func updateMatrices(size: CGSize) {
        let aspect = max(Float(size.width / max(size.height, 1)), 0.01)
        let projection = float4x4.perspective(fovY: 45 * .pi / 180, aspect: aspect, near: 0.01, far: 100)
        let cp = cos(camera.pitch), eye = camera.target + SIMD3<Float>(sin(camera.yaw) * cp, sin(camera.pitch), cos(camera.yaw) * cp) * camera.distance
        viewProjection = projection * float4x4.lookAt(eye: eye, center: camera.target, up: SIMD3<Float>(0, 1, 0))
        let distance = simd_length(eye - objectTransform.translation)
        gizmoWorldScale = TranslationGizmoGeometry.worldScale(cameraDistance: distance,
                                                               viewportHeight: Float(size.height),
                                                               fovYRadians: 45 * .pi / 180)
    }

    var cameraViewDirection: SIMD3<Float> {
        let cp = cos(camera.pitch)
        let eye = camera.target + SIMD3<Float>(sin(camera.yaw) * cp, sin(camera.pitch), cos(camera.yaw) * cp) * camera.distance
        return simd_normalize(camera.target - eye)
    }
}

private struct Uniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var normalMatrix: simd_float3x3
}
private extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x, y, z) } }

extension float4x4 {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0))
    }
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = simd_normalize(eye - center), x = simd_normalize(simd_cross(up, z)), y = simd_cross(z, x)
        return float4x4(SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
                        SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1))
    }
}
