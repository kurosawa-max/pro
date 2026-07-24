import Foundation
import MetalKit
import simd

protocol EdgeSelectionPairBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer?
}

struct MetalEdgeSelectionPairBufferAllocator: EdgeSelectionPairBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        device.makeBuffer(length: length, options: .storageModeShared)
    }
}

struct EdgeSelectionOverlayCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let tableFingerprint: UInt64
    let selectionVersion: EdgeSelectionVersion
    let hoveredEdgeID: Int?
}

final class EdgeSelectionOverlayRenderer {
    private let device: MTLDevice
    private let allocator: EdgeSelectionPairBufferAllocating
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var selectedBuffer: MTLBuffer?
    private var hoverBuffer: MTLBuffer?
    private(set) var selectedEdgeCount = 0
    private(set) var hoverEdgeCount = 0
    private(set) var uploadedKey: EdgeSelectionOverlayCacheKey?
    #if DEBUG
    private(set) var uploadCount = 0
    #endif

    init?(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        allocator: EdgeSelectionPairBufferAllocating = MetalEdgeSelectionPairBufferAllocator()
    ) {
        guard let vertex = library.makeFunction(name: "edgeSelectionVertex"),
              let fragment = library.makeFunction(name: "edgeSelectionFragment") else { return nil }
        self.device = device
        self.allocator = allocator
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
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
    func update(
        mesh: EditableMesh,
        table: MeshEdgeTable?,
        selection: EdgeSelection,
        hoveredEdgeID: Int?
    ) -> Bool {
        guard let table, table.matches(mesh), selection.matches(table) else {
            invalidate()
            return false
        }
        let validHover = hoveredEdgeID.flatMap { table.edges.indices.contains($0) ? $0 : nil }
        let key = EdgeSelectionOverlayCacheKey(
            topologyID: table.sourceTopologyID,
            topologyRevision: table.sourceTopologyRevision,
            tableFingerprint: table.fingerprint,
            selectionVersion: selection.version,
            hoveredEdgeID: validHover)
        guard uploadedKey != key else { return false }
        selectedEdgeCount = 0
        hoverEdgeCount = 0
        uploadedKey = nil
        do {
            let selectedPairs = try pairs(
                edgeIDs: selection.selectedEdgeIDs(), table: table, vertexCount: mesh.vertices.count)
            let hoverPairs = try pairs(
                edgeIDs: validHover.map { [$0] } ?? [], table: table, vertexCount: mesh.vertices.count)
            let selectedTarget: MTLBuffer?
            if selectedPairs.isEmpty {
                selectedTarget = nil
            } else {
                selectedTarget = try buffer(for: selectedPairs, reusing: selectedBuffer)
            }
            let hoverTarget: MTLBuffer?
            if hoverPairs.isEmpty {
                hoverTarget = nil
            } else {
                hoverTarget = try buffer(for: hoverPairs, reusing: hoverBuffer)
            }
            selectedBuffer = selectedTarget
            hoverBuffer = hoverTarget
            selectedEdgeCount = selectedPairs.count
            hoverEdgeCount = hoverPairs.count
            uploadedKey = key
            #if DEBUG
            uploadCount += 1
            #endif
            return true
        } catch {
            invalidate()
            return false
        }
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        vertexBuffer: MTLBuffer,
        viewProjection: simd_float4x4,
        model: simd_float4x4,
        viewportSize: SIMD2<Float>
    ) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setDepthBias(-2, slopeScale: -1, clamp: -0.0001)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        if let selectedBuffer, selectedEdgeCount > 0 {
            encode(buffer: selectedBuffer, edgeCount: selectedEdgeCount, thickness: 2.5,
                   color: SIMD4<Float>(1, 0.76, 0.08, 0.95), encoder: encoder,
                   viewProjection: viewProjection, model: model, viewportSize: viewportSize)
        }
        if let hoverBuffer, hoverEdgeCount > 0 {
            encode(buffer: hoverBuffer, edgeCount: hoverEdgeCount, thickness: 5,
                   color: SIMD4<Float>(1, 1, 1, 1), encoder: encoder,
                   viewProjection: viewProjection, model: model, viewportSize: viewportSize)
        }
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    private func encode(
        buffer: MTLBuffer,
        edgeCount: Int,
        thickness: Float,
        color: SIMD4<Float>,
        encoder: MTLRenderCommandEncoder,
        viewProjection: simd_float4x4,
        model: simd_float4x4,
        viewportSize: SIMD2<Float>
    ) {
        var uniforms = EdgeSelectionOverlayUniforms(
            viewProjection: viewProjection, model: model,
            viewportSize: viewportSize, thickness: thickness, color: color)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<EdgeSelectionOverlayUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: edgeCount)
    }

    private func pairs(
        edgeIDs: [Int],
        table: MeshEdgeTable,
        vertexCount: Int
    ) throws -> [SIMD2<UInt32>] {
        var result: [SIMD2<UInt32>] = []
        result.reserveCapacity(edgeIDs.count)
        for edgeID in edgeIDs {
            guard table.edges.indices.contains(edgeID) else { throw EdgeSelectionError.invalidEdgeID }
            let key = table.edges[edgeID].key
            guard Int(key.low) < vertexCount, Int(key.high) < vertexCount else {
                throw EdgeSelectionError.invalidTable
            }
            result.append(SIMD2(key.low, key.high))
        }
        return result
    }

    private func buffer(
        for pairs: [SIMD2<UInt32>],
        reusing existing: MTLBuffer?
    ) throws -> MTLBuffer {
        let (bytes, overflow) = pairs.count.multipliedReportingOverflow(
            by: MemoryLayout<SIMD2<UInt32>>.stride)
        guard !overflow, bytes > 0 else { throw EdgeSelectionError.allocationOverflow }
        guard let target = existing.flatMap({ $0.length >= bytes ? $0 : nil })
            ?? allocator.makeBuffer(device: device, length: bytes) else {
            throw EdgeSelectionError.unavailable
        }
        let copied = pairs.withUnsafeBufferPointer { source -> Bool in
            guard let source = source.baseAddress else { return false }
            target.contents().copyMemory(from: source, byteCount: bytes)
            return true
        }
        guard copied else { throw EdgeSelectionError.unavailable }
        return target
    }

    private func invalidate() {
        selectedEdgeCount = 0
        hoverEdgeCount = 0
        uploadedKey = nil
    }
}

struct EdgeSelectionOverlayUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var viewportSize: SIMD2<Float>
    var thickness: Float
    var padding: Float = 0
    var color: SIMD4<Float>
}
