import Foundation
import MetalKit
import simd

struct FaceSelectionOverlayCacheKey: Equatable {
    let meshTopologyID: UUID
    let meshTopologyRevision: UInt64
    let selectionTopologyID: UUID
    let selectionTopologyRevision: UInt64
    let triangleCount: Int
    let selectionVersion: FaceSelectionVersion
}

final class FaceSelectionOverlayRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var indexBuffer: MTLBuffer?
    private(set) var selectedIndexCount = 0
    private(set) var uploadedKey: FaceSelectionOverlayCacheKey?
    #if DEBUG
    private(set) var uploadCount = 0
    #endif

    init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat) {
        guard let vertex = library.makeFunction(name: "faceSelectionVertex"),
              let fragment = library.makeFunction(name: "faceSelectionFragment") else { return nil }
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
        depth.depthCompareFunction = .lessEqual
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.depthState = depthState
    }

    @discardableResult
    func update(mesh: EditableMesh, selection: FaceSelection) -> Bool {
        let key = FaceSelectionOverlayCacheKey(
            meshTopologyID: mesh.runtime.topologyID,
            meshTopologyRevision: mesh.runtime.topologyRevision,
            selectionTopologyID: selection.sourceTopologyID,
            selectionTopologyRevision: selection.sourceTopologyRevision,
            triangleCount: selection.triangleCount,
            selectionVersion: selection.version)
        guard Self.requiresUpload(previous: uploadedKey, current: key) else { return false }
        uploadedKey = key
        selectedIndexCount = 0
        guard selection.matches(mesh), selection.selectedCount > 0 else { return true }

        guard let indices = try? selection.selectedIndices(from: mesh), !indices.isEmpty else { return true }
        let (byteCount, overflow) = indices.count.multipliedReportingOverflow(by: MemoryLayout<UInt32>.stride)
        guard !overflow, byteCount > 0 else { return true }
        guard let target = indexBuffer.flatMap({ $0.length >= byteCount ? $0 : nil })
            ?? device.makeBuffer(length: byteCount, options: .storageModeShared) else { return true }
        indices.withUnsafeBufferPointer { source in
            guard let source = source.baseAddress else { return }
            target.contents().copyMemory(from: source, byteCount: byteCount)
        }
        indexBuffer = target
        selectedIndexCount = indices.count
        #if DEBUG
        uploadCount += 1
        #endif
        return true
    }

    func encode(encoder: MTLRenderCommandEncoder, vertexBuffer: MTLBuffer,
                viewProjection: simd_float4x4, model: simd_float4x4) {
        guard let indexBuffer, selectedIndexCount > 0 else { return }
        var uniforms = FaceSelectionOverlayUniforms(viewProjection: viewProjection, model: model)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setDepthBias(-1, slopeScale: -1, clamp: -0.0001)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FaceSelectionOverlayUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: selectedIndexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    static func requiresUpload(previous: FaceSelectionOverlayCacheKey?,
                               current: FaceSelectionOverlayCacheKey) -> Bool {
        previous != current
    }
}

struct FaceSelectionOverlayUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
}
