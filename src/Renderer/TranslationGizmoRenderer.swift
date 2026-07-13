import MetalKit
import simd

final class TranslationGizmoRenderer {
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
                                                   length: MemoryLayout<GizmoVertex>.stride * mesh.vertices.count),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                                  length: MemoryLayout<UInt16>.stride * mesh.indices.count) else { return nil }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = mesh.indices.count
    }

    func encode(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                origin: SIMD3<Float>, scale: Float, state: TranslationGizmoState) {
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

    private static func makeMesh() -> (vertices: [GizmoVertex], indices: [UInt16]) {
        var vertices: [GizmoVertex] = [], indices: [UInt16] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  color: SIMD4<Float>, handle: TranslationGizmoHandle) {
            let base = UInt16(vertices.count)
            vertices += [GizmoVertex(position: a, color: color, handle: handle.rawValue),
                         GizmoVertex(position: b, color: color, handle: handle.rawValue),
                         GizmoVertex(position: c, color: color, handle: handle.rawValue),
                         GizmoVertex(position: d, color: color, handle: handle.rawValue)]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                      color: SIMD4<Float>, handle: TranslationGizmoHandle) {
            let base = UInt16(vertices.count)
            vertices += [GizmoVertex(position: a, color: color, handle: handle.rawValue),
                         GizmoVertex(position: b, color: color, handle: handle.rawValue),
                         GizmoVertex(position: c, color: color, handle: handle.rawValue)]
            indices += [base, base + 1, base + 2]
        }
        let red = GizmoColors.x, green = GizmoColors.y, blue = GizmoColors.z, t: Float = 0.025
        quad(SIMD3(0, -t, 0), SIMD3(0.82, -t, 0), SIMD3(0.82, t, 0), SIMD3(0, t, 0), color: red, handle: .xAxis)
        triangle(SIMD3(0.82, -0.08, 0), SIMD3(1, 0, 0), SIMD3(0.82, 0.08, 0), color: red, handle: .xAxis)
        quad(SIMD3(-t, 0, 0), SIMD3(t, 0, 0), SIMD3(t, 0.82, 0), SIMD3(-t, 0.82, 0), color: green, handle: .yAxis)
        triangle(SIMD3(-0.08, 0.82, 0), SIMD3(0, 1, 0), SIMD3(0.08, 0.82, 0), color: green, handle: .yAxis)
        quad(SIMD3(-t, 0, 0), SIMD3(t, 0, 0), SIMD3(t, 0, 0.82), SIMD3(-t, 0, 0.82), color: blue, handle: .zAxis)
        triangle(SIMD3(-0.08, 0, 0.82), SIMD3(0, 0, 1), SIMD3(0.08, 0, 0.82), color: blue, handle: .zAxis)
        let lo = TranslationGizmoGeometry.planeMinimum, hi = TranslationGizmoGeometry.planeMaximum
        quad(SIMD3(lo, lo, 0), SIMD3(hi, lo, 0), SIMD3(hi, hi, 0), SIMD3(lo, hi, 0),
             color: SIMD4(0.9, 0.8, 0.15, 0.75), handle: .xyPlane)
        quad(SIMD3(0, lo, lo), SIMD3(0, hi, lo), SIMD3(0, hi, hi), SIMD3(0, lo, hi),
             color: SIMD4(0.1, 0.8, 0.8, 0.75), handle: .yzPlane)
        quad(SIMD3(lo, 0, lo), SIMD3(hi, 0, lo), SIMD3(hi, 0, hi), SIMD3(lo, 0, hi),
             color: SIMD4(0.9, 0.15, 0.75, 0.75), handle: .zxPlane)
        return (vertices, indices)
    }
}

private struct GizmoVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    var handle: Int32
}

struct GizmoUniforms {
    var viewProjection: simd_float4x4
    var origin: SIMD3<Float>
    var scale: Float
    var hoverHandle: Int32
    var activeHandle: Int32
}

enum GizmoColors {
    static let x = SIMD4<Float>(0.95, 0.12, 0.12, 1)
    static let y = SIMD4<Float>(0.12, 0.9, 0.25, 1)
    static let z = SIMD4<Float>(0.15, 0.4, 1, 1)

    static func color(forAxis axis: Int32) -> SIMD4<Float> {
        axis == 0 ? x : (axis == 1 ? y : z)
    }
}
