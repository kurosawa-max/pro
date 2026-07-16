import MetalKit
import simd

final class MeshDiagnosticsOverlayRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var boundaryBuffer: MTLBuffer?
    private var nonManifoldBuffer: MTLBuffer?
    private var windingBuffer: MTLBuffer?
    private var degenerateBuffer: MTLBuffer?
    private var isolatedBuffer: MTLBuffer?
    private var boundaryCount = 0
    private var nonManifoldCount = 0
    private var windingCount = 0
    private var degenerateCount = 0
    private var isolatedCount = 0
    private(set) var uploadedRevision: UInt64?
    private(set) var uploadCount = 0

    init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat) {
        guard let vertex = library.makeFunction(name: "diagnosticsOverlayVertex"),
              let fragment = library.makeFunction(name: "diagnosticsOverlayFragment") else { return nil }
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        let depth = MTLDepthStencilDescriptor()
        depth.isDepthWriteEnabled = false
        // Diagnostics are intentionally visible through the surface so a defect is not hidden
        // by the current camera angle. This overlay never participates in picking.
        depth.depthCompareFunction = .always
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.depthState = depthState
    }

    @discardableResult
    func update(data: MeshDiagnosticsOverlayData?, revision: UInt64) -> Bool {
        guard Self.requiresUpload(previousRevision: uploadedRevision, newRevision: revision) else { return false }
        let data = data ?? MeshDiagnosticsOverlayData()
        (boundaryBuffer, boundaryCount) = updateLineBuffer(
            boundaryBuffer, segments: data.boundaryEdges, color: SIMD4<Float>(1.0, 0.68, 0.08, 1))
        (nonManifoldBuffer, nonManifoldCount) = updateLineBuffer(
            nonManifoldBuffer, segments: data.nonManifoldEdges, color: SIMD4<Float>(1.0, 0.12, 0.2, 1))
        (windingBuffer, windingCount) = updateLineBuffer(
            windingBuffer, segments: data.windingConflicts, color: SIMD4<Float>(1.0, 0.1, 0.75, 1))
        (degenerateBuffer, degenerateCount) = updatePointBuffer(
            degenerateBuffer, points: data.degenerateTrianglePoints, color: SIMD4<Float>(1.0, 0.05, 0.05, 1))
        (isolatedBuffer, isolatedCount) = updatePointBuffer(
            isolatedBuffer, points: data.isolatedVertexPoints, color: SIMD4<Float>(1.0, 0.82, 0.05, 1))
        uploadedRevision = revision
        uploadCount += 1
        return true
    }

    func encode(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                model: simd_float4x4, options: MeshDiagnosticsOverlayOptions) {
        guard options.isVisible else { return }
        var uniforms = DiagnosticsOverlayUniforms(viewProjection: viewProjection, model: model, pointSize: 11)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DiagnosticsOverlayUniforms>.stride, index: 1)
        if options.boundaryEdges { draw(encoder, buffer: boundaryBuffer, count: boundaryCount, type: .line) }
        if options.nonManifoldEdges { draw(encoder, buffer: nonManifoldBuffer, count: nonManifoldCount, type: .line) }
        if options.windingConflicts { draw(encoder, buffer: windingBuffer, count: windingCount, type: .line) }
        if options.degenerateTriangles { draw(encoder, buffer: degenerateBuffer, count: degenerateCount, type: .point) }
        if options.isolatedVertices { draw(encoder, buffer: isolatedBuffer, count: isolatedCount, type: .point) }
    }

    static func requiresUpload(previousRevision: UInt64?, newRevision: UInt64) -> Bool {
        previousRevision != newRevision
    }

    private func updateLineBuffer(_ buffer: MTLBuffer?, segments: [MeshDiagnosticSegment],
                                  color: SIMD4<Float>) -> (MTLBuffer?, Int) {
        var vertices: [DiagnosticsOverlayVertex] = []
        vertices.reserveCapacity(segments.count * 2)
        for segment in segments {
            vertices.append(DiagnosticsOverlayVertex(position: segment.start, color: color))
            vertices.append(DiagnosticsOverlayVertex(position: segment.end, color: color))
        }
        return update(buffer, vertices: vertices)
    }

    private func updatePointBuffer(_ buffer: MTLBuffer?, points: [SIMD3<Float>],
                                   color: SIMD4<Float>) -> (MTLBuffer?, Int) {
        update(buffer, vertices: points.map { DiagnosticsOverlayVertex(position: $0, color: color) })
    }

    private func update(_ buffer: MTLBuffer?, vertices: [DiagnosticsOverlayVertex]) -> (MTLBuffer?, Int) {
        guard !vertices.isEmpty else { return (buffer, 0) }
        let byteCount = vertices.count * MemoryLayout<DiagnosticsOverlayVertex>.stride
        guard let target = buffer.flatMap({ $0.length >= byteCount ? $0 : nil })
            ?? device.makeBuffer(length: byteCount, options: .storageModeShared) else { return (nil, 0) }
        vertices.withUnsafeBufferPointer { source in
            guard let source = source.baseAddress else { return }
            target.contents().copyMemory(from: source, byteCount: byteCount)
        }
        return (target, vertices.count)
    }

    private func draw(_ encoder: MTLRenderCommandEncoder, buffer: MTLBuffer?, count: Int,
                      type: MTLPrimitiveType) {
        guard let buffer, count > 0 else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: type, vertexStart: 0, vertexCount: count)
    }
}

struct DiagnosticsOverlayVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

struct DiagnosticsOverlayUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var pointSize: Float
}
