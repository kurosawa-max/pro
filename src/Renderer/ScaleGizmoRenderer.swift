import MetalKit
import simd

final class ScaleGizmoRenderer {
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int

    init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat) {
        guard let vertex = library.makeFunction(name: "gizmoVertex"),
              let fragment = library.makeFunction(name: "gizmoFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline

        let depth = MTLDepthStencilDescriptor()
        depth.isDepthWriteEnabled = false
        depth.depthCompareFunction = .always
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.depthState = depthState

        let mesh = Self.makeMesh()
        guard let vertexBuffer = device.makeBuffer(
            bytes: mesh.vertices, length: MemoryLayout<ScaleGizmoVertex>.stride * mesh.vertices.count),
              let indexBuffer = device.makeBuffer(
                bytes: mesh.indices, length: MemoryLayout<UInt16>.stride * mesh.indices.count) else { return nil }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = mesh.indices.count
    }

    func encode(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                origin: SIMD3<Float>, scale: Float, state: ScaleGizmoState) {
        var uniforms = GizmoUniforms(viewProjection: viewProjection, origin: origin, scale: scale,
                                     hoverHandle: state.hoverHandle?.rawValue ?? -1,
                                     activeHandle: state.activeHandle?.rawValue ?? -1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GizmoUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
    }

    private static func makeMesh() -> (vertices: [ScaleGizmoVertex], indices: [UInt16]) {
        var vertices: [ScaleGizmoVertex] = []
        var indices: [UInt16] = []

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  color: SIMD4<Float>, handle: ScaleGizmoHandle) {
            let base = UInt16(vertices.count)
            vertices += [ScaleGizmoVertex(position: a, color: color, handle: handle.rawValue),
                         ScaleGizmoVertex(position: b, color: color, handle: handle.rawValue),
                         ScaleGizmoVertex(position: c, color: color, handle: handle.rawValue),
                         ScaleGizmoVertex(position: d, color: color, handle: handle.rawValue)]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }

        func cube(center: SIMD3<Float>, halfExtent: Float,
                  color: SIMD4<Float>, handle: ScaleGizmoHandle) {
            let base = UInt16(vertices.count)
            let x = center.x, y = center.y, z = center.z, h = halfExtent
            let points = [
                SIMD3<Float>(x - h, y - h, z - h), SIMD3<Float>(x + h, y - h, z - h),
                SIMD3<Float>(x + h, y + h, z - h), SIMD3<Float>(x - h, y + h, z - h),
                SIMD3<Float>(x - h, y - h, z + h), SIMD3<Float>(x + h, y - h, z + h),
                SIMD3<Float>(x + h, y + h, z + h), SIMD3<Float>(x - h, y + h, z + h),
            ]
            vertices += points.map { ScaleGizmoVertex(position: $0, color: color, handle: handle.rawValue) }
            let faces: [UInt16] = [
                0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
                0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2,
                0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
            ]
            indices += faces.map { base + $0 }
        }

        let shaftHalfWidth: Float = 0.025
        let shaftStart = ScaleGizmoGeometry.axisMinimum
        let shaftEnd: Float = 0.88
        quad(SIMD3(shaftStart, -shaftHalfWidth, 0), SIMD3(shaftEnd, -shaftHalfWidth, 0),
             SIMD3(shaftEnd, shaftHalfWidth, 0), SIMD3(shaftStart, shaftHalfWidth, 0),
             color: GizmoColors.x, handle: .xAxis)
        quad(SIMD3(-shaftHalfWidth, shaftStart, 0), SIMD3(shaftHalfWidth, shaftStart, 0),
             SIMD3(shaftHalfWidth, shaftEnd, 0), SIMD3(-shaftHalfWidth, shaftEnd, 0),
             color: GizmoColors.y, handle: .yAxis)
        quad(SIMD3(-shaftHalfWidth, 0, shaftStart), SIMD3(shaftHalfWidth, 0, shaftStart),
             SIMD3(shaftHalfWidth, 0, shaftEnd), SIMD3(-shaftHalfWidth, 0, shaftEnd),
             color: GizmoColors.z, handle: .zAxis)
        cube(center: SIMD3(1, 0, 0), halfExtent: 0.075, color: GizmoColors.x, handle: .xAxis)
        cube(center: SIMD3(0, 1, 0), halfExtent: 0.075, color: GizmoColors.y, handle: .yAxis)
        cube(center: SIMD3(0, 0, 1), halfExtent: 0.075, color: GizmoColors.z, handle: .zAxis)
        cube(center: .zero, halfExtent: 0.11,
             color: SIMD4<Float>(0.88, 0.88, 0.92, 1), handle: .uniform)
        return (vertices, indices)
    }
}

private struct ScaleGizmoVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    var handle: Int32
}
