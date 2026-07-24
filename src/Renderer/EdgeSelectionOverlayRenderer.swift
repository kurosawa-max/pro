import Foundation
import MetalKit
import simd

protocol EdgeSelectionPairBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer?
    func copy(_ pairs: [SIMD2<UInt32>], byteCount: Int, to buffer: MTLBuffer) -> Bool
}

struct MetalEdgeSelectionPairBufferAllocator: EdgeSelectionPairBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        device.makeBuffer(length: length, options: .storageModeShared)
    }

    func copy(_ pairs: [SIMD2<UInt32>], byteCount: Int, to buffer: MTLBuffer) -> Bool {
        pairs.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, byteCount > 0, buffer.length >= byteCount else {
                return false
            }
            buffer.contents().copyMemory(from: base, byteCount: byteCount)
            return true
        }
    }
}

struct EdgeSelectionOverlayCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let tableFingerprint: UInt64
    let selectionVersion: EdgeSelectionVersion
    let hoveredEdgeID: Int?
}

enum EdgeSelectionOverlayError: Error, LocalizedError, Equatable {
    case staleTable
    case staleSelection
    case invalidEndpoint
    case arithmeticOverflow
    case allocationFailed
    case copyFailed
    case invalidViewport
    case invalidDisplayScale

    var errorDescription: String? {
        switch self {
        case .staleTable: "The edge overlay table is stale."
        case .staleSelection: "The edge overlay selection is stale."
        case .invalidEndpoint: "The edge overlay contains an invalid endpoint."
        case .arithmeticOverflow: "The edge overlay buffer size is not representable."
        case .allocationFailed: "The edge overlay buffer could not be allocated."
        case .copyFailed: "The edge overlay buffer could not be populated."
        case .invalidViewport: "The edge overlay viewport is invalid."
        case .invalidDisplayScale: "The edge overlay display scale is invalid."
        }
    }
}

enum EdgeSelectionOverlayUpdateResult: Equatable {
    case unchanged
    case updated
    case unavailable(EdgeSelectionOverlayError)
}

enum EdgeSelectionOverlayMetrics {
    static func thicknessPixels(
        thicknessPoints: Float,
        displayScale: Float
    ) -> Result<Float, EdgeSelectionOverlayError> {
        guard thicknessPoints.isFinite, thicknessPoints > 0 else {
            return .failure(.invalidViewport)
        }
        guard displayScale.isFinite, displayScale > 0 else {
            return .failure(.invalidDisplayScale)
        }
        let value = thicknessPoints * displayScale
        guard value.isFinite else { return .failure(.arithmeticOverflow) }
        return .success(value)
    }
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

    func update(
        mesh: EditableMesh,
        table: MeshEdgeTable?,
        selection: EdgeSelection,
        hoveredEdgeID: Int?,
        drawableSizePixels: CGSize,
        displayScale: CGFloat
    ) -> EdgeSelectionOverlayUpdateResult {
        guard drawableSizePixels.width.isFinite, drawableSizePixels.height.isFinite,
              drawableSizePixels.width > 0, drawableSizePixels.height > 0 else {
            invalidate()
            return .unavailable(.invalidViewport)
        }
        guard displayScale.isFinite, displayScale > 0 else {
            invalidate()
            return .unavailable(.invalidDisplayScale)
        }
        guard let table, table.matches(mesh) else {
            invalidate()
            return .unavailable(.staleTable)
        }
        guard selection.matches(table) else {
            invalidate()
            return .unavailable(.staleSelection)
        }
        let validHover = hoveredEdgeID.flatMap { table.edges.indices.contains($0) ? $0 : nil }
        let key = EdgeSelectionOverlayCacheKey(
            topologyID: table.sourceTopologyID,
            topologyRevision: table.sourceTopologyRevision,
            tableFingerprint: table.fingerprint,
            selectionVersion: selection.version,
            hoveredEdgeID: validHover)
        guard uploadedKey != key else { return .unchanged }
        do {
            let selectedPairs = try pairs(
                edgeIDs: selection.selectedEdgeIDs(), table: table, vertexCount: mesh.vertices.count)
            let hoverPairs = try pairs(
                edgeIDs: validHover.map { [$0] } ?? [], table: table, vertexCount: mesh.vertices.count)
            let selectedTarget: MTLBuffer?
            if selectedPairs.isEmpty {
                selectedTarget = nil
            } else {
                selectedTarget = try freshBuffer(for: selectedPairs)
            }
            let hoverTarget: MTLBuffer?
            if hoverPairs.isEmpty {
                hoverTarget = nil
            } else {
                hoverTarget = try freshBuffer(for: hoverPairs)
            }
            // Commit references, counts, and key only after every fallible allocation and copy.
            selectedBuffer = selectedTarget
            hoverBuffer = hoverTarget
            selectedEdgeCount = selectedPairs.count
            hoverEdgeCount = hoverPairs.count
            uploadedKey = key
            #if DEBUG
            uploadCount += 1
            #endif
            return .updated
        } catch let error as EdgeSelectionOverlayError {
            invalidate()
            return .unavailable(error)
        } catch {
            invalidate()
            return .unavailable(.copyFailed)
        }
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        vertexBuffer: MTLBuffer,
        viewProjection: simd_float4x4,
        model: simd_float4x4,
        drawableSizePixels: SIMD2<Float>,
        displayScale: Float
    ) {
        guard drawableSizePixels.x.isFinite, drawableSizePixels.y.isFinite,
              drawableSizePixels.x > 0, drawableSizePixels.y > 0,
              displayScale.isFinite, displayScale > 0 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setDepthBias(-2, slopeScale: -1, clamp: -0.0001)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        if let selectedBuffer, selectedEdgeCount > 0 {
            encode(buffer: selectedBuffer, edgeCount: selectedEdgeCount, thicknessPoints: 2.5,
                   color: SIMD4<Float>(1, 0.76, 0.08, 0.95), encoder: encoder,
                   viewProjection: viewProjection, model: model,
                   drawableSizePixels: drawableSizePixels, displayScale: displayScale)
        }
        if let hoverBuffer, hoverEdgeCount > 0 {
            encode(buffer: hoverBuffer, edgeCount: hoverEdgeCount, thicknessPoints: 5,
                   color: SIMD4<Float>(1, 1, 1, 1), encoder: encoder,
                   viewProjection: viewProjection, model: model,
                   drawableSizePixels: drawableSizePixels, displayScale: displayScale)
        }
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    private func encode(
        buffer: MTLBuffer,
        edgeCount: Int,
        thicknessPoints: Float,
        color: SIMD4<Float>,
        encoder: MTLRenderCommandEncoder,
        viewProjection: simd_float4x4,
        model: simd_float4x4,
        drawableSizePixels: SIMD2<Float>,
        displayScale: Float
    ) {
        var uniforms = EdgeSelectionOverlayUniforms(
            viewProjection: viewProjection, model: model,
            drawableSizePixels: drawableSizePixels,
            thicknessPoints: thicknessPoints, displayScale: displayScale, color: color)
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
            guard table.edges.indices.contains(edgeID) else {
                throw EdgeSelectionOverlayError.staleSelection
            }
            let key = table.edges[edgeID].key
            guard Int(key.low) < vertexCount, Int(key.high) < vertexCount else {
                throw EdgeSelectionOverlayError.invalidEndpoint
            }
            result.append(SIMD2(key.low, key.high))
        }
        return result
    }

    private func freshBuffer(for pairs: [SIMD2<UInt32>]) throws -> MTLBuffer {
        let (bytes, overflow) = pairs.count.multipliedReportingOverflow(
            by: MemoryLayout<SIMD2<UInt32>>.stride)
        guard !overflow, bytes > 0 else { throw EdgeSelectionOverlayError.arithmeticOverflow }
        guard let target = allocator.makeBuffer(device: device, length: bytes) else {
            throw EdgeSelectionOverlayError.allocationFailed
        }
        guard allocator.copy(pairs, byteCount: bytes, to: target) else {
            throw EdgeSelectionOverlayError.copyFailed
        }
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
    var drawableSizePixels: SIMD2<Float>
    var thicknessPoints: Float
    var displayScale: Float
    var color: SIMD4<Float>
}
