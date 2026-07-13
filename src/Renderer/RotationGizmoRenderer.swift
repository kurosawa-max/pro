import MetalKit
import simd

final class RotationGizmoRenderer {
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
        guard let vertexBuffer = device.makeBuffer(bytes: mesh.vertices,
                                                   length: MemoryLayout<RotationGizmoVertex>.stride * mesh.vertices.count),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                                  length: MemoryLayout<UInt16>.stride * mesh.indices.count) else { return nil }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = mesh.indices.count
    }

    func encode(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                origin: SIMD3<Float>, scale: Float, state: RotationGizmoState) {
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

    private static func makeMesh(segments: Int = 96) -> (vertices: [RotationGizmoVertex], indices: [UInt16]) {
        var vertices: [RotationGizmoVertex] = [], indices: [UInt16] = []
        let radius = RotationGizmoGeometry.ringRadius, halfWidth: Float = 0.018
        for handle in RotationGizmoHandle.allCases {
            let color = GizmoColors.color(forAxis: handle.rawValue)
            let base = UInt16(vertices.count)
            for segment in 0...segments {
                let angle = Float(segment) / Float(segments) * 2 * .pi
                let inner = radius - halfWidth, outer = radius + halfWidth
                let c = cos(angle), s = sin(angle)
                func point(_ r: Float) -> SIMD3<Float> {
                    switch handle {
                    case .xAxis: return SIMD3(0, c * r, s * r)
                    case .yAxis: return SIMD3(c * r, 0, s * r)
                    case .zAxis: return SIMD3(c * r, s * r, 0)
                    }
                }
                vertices.append(RotationGizmoVertex(position: point(inner), color: color, handle: handle.rawValue))
                vertices.append(RotationGizmoVertex(position: point(outer), color: color, handle: handle.rawValue))
            }
            for segment in 0..<segments {
                let i = base + UInt16(segment * 2)
                indices += [i, i + 1, i + 3, i, i + 3, i + 2]
            }
        }
        return (vertices, indices)
    }
}

private struct RotationGizmoVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    var handle: Int32
}
