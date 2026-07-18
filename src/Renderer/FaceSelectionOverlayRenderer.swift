import Foundation
import MetalKit
import simd

protocol FaceSelectionIndexBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer?
}

struct MetalFaceSelectionIndexBufferAllocator: FaceSelectionIndexBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        device.makeBuffer(length: length, options: .storageModeShared)
    }
}

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
    private let bufferAllocator: FaceSelectionIndexBufferAllocating
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var indexBuffer: MTLBuffer?
    private(set) var selectedIndexCount = 0
    private(set) var uploadedKey: FaceSelectionOverlayCacheKey?
    #if DEBUG
    private(set) var uploadCount = 0
    #endif

    init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat,
          bufferAllocator: FaceSelectionIndexBufferAllocating = MetalFaceSelectionIndexBufferAllocator()) {
        guard let vertex = library.makeFunction(name: "faceSelectionVertex"),
              let fragment = library.makeFunction(name: "faceSelectionFragment") else { return nil }
        self.device = device
        self.bufferAllocator = bufferAllocator
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
        uploadedKey = nil
        selectedIndexCount = 0
        guard selection.matches(mesh) else { return false }
        guard selection.selectedCount > 0 else {
            uploadedKey = key
            return true
        }

        guard let indices = try? selection.selectedIndices(from: mesh), !indices.isEmpty else { return false }
        let (byteCount, overflow) = indices.count.multipliedReportingOverflow(by: MemoryLayout<UInt32>.stride)
        guard !overflow, byteCount > 0 else { return false }
        guard let target = indexBuffer.flatMap({ $0.length >= byteCount ? $0 : nil })
            ?? bufferAllocator.makeBuffer(device: device, length: byteCount) else { return false }
        let copied = indices.withUnsafeBufferPointer { source -> Bool in
            guard let source = source.baseAddress else { return false }
            target.contents().copyMemory(from: source, byteCount: byteCount)
            return true
        }
        guard copied else { return false }
        indexBuffer = target
        selectedIndexCount = indices.count
        uploadedKey = key
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
