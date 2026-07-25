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

struct EdgeSelectedOverlayCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let tableFingerprint: UInt64
    let selectionVersion: EdgeSelectionVersion
}

struct EdgeHoverOverlayCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let tableFingerprint: UInt64
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

enum EdgeOverlayComponentUpdate: Equatable {
    case unchanged
    case updated
    case cleared
    case unavailable(EdgeSelectionOverlayError)
}

struct EdgeSelectionOverlayUpdateSummary: Equatable {
    let selected: EdgeOverlayComponentUpdate
    let hover: EdgeOverlayComponentUpdate

    static let unchanged = EdgeSelectionOverlayUpdateSummary(
        selected: .unchanged, hover: .unchanged)
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
    private(set) var selectedUploadedKey: EdgeSelectedOverlayCacheKey?
    private(set) var hoverUploadedKey: EdgeHoverOverlayCacheKey?
    #if DEBUG
    var hasSelectedBuffer: Bool { selectedBuffer != nil }
    var hasHoverBuffer: Bool { hoverBuffer != nil }
    private(set) var selectedUploadCount = 0
    private(set) var hoverUploadCount = 0
    private(set) var selectedPairGenerationCount = 0
    private(set) var hoverPairGenerationCount = 0
    private(set) var selectedAllocationCount = 0
    private(set) var hoverAllocationCount = 0
    private(set) var selectedCopyCount = 0
    private(set) var hoverCopyCount = 0
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
    ) -> EdgeSelectionOverlayUpdateSummary {
        guard drawableSizePixels.width.isFinite, drawableSizePixels.height.isFinite,
              drawableSizePixels.width > 0, drawableSizePixels.height > 0 else {
            invalidateAll()
            return unavailableSummary(.invalidViewport)
        }
        guard displayScale.isFinite, displayScale > 0 else {
            invalidateAll()
            return unavailableSummary(.invalidDisplayScale)
        }
        guard let table, table.matches(mesh) else {
            invalidateAll()
            return unavailableSummary(.staleTable)
        }
        guard selection.matches(table) else {
            invalidateAll()
            return unavailableSummary(.staleSelection)
        }
        let validHover = hoveredEdgeID.flatMap { table.edges.indices.contains($0) ? $0 : nil }
        let selectedKey = EdgeSelectedOverlayCacheKey(
            topologyID: table.sourceTopologyID,
            topologyRevision: table.sourceTopologyRevision,
            tableFingerprint: table.fingerprint,
            selectionVersion: selection.version)
        let hoverKey = EdgeHoverOverlayCacheKey(
            topologyID: table.sourceTopologyID,
            topologyRevision: table.sourceTopologyRevision,
            tableFingerprint: table.fingerprint,
            hoveredEdgeID: validHover)
        let selectedChanged = selectedUploadedKey != selectedKey
        let hoverChanged = hoverUploadedKey != hoverKey
        guard selectedChanged || hoverChanged else { return .unchanged }

        if selectedChanged && hoverChanged {
            do {
                let selectedStaged = try stageSelected(
                    selection: selection, table: table, vertexCount: mesh.vertices.count)
                let hoverStaged: StagedComponent
                do {
                    hoverStaged = try stageHover(
                        edgeID: validHover, table: table, vertexCount: mesh.vertices.count)
                } catch {
                    invalidateAll()
                    return EdgeSelectionOverlayUpdateSummary(
                        selected: .cleared, hover: .unavailable(overlayError(error)))
                }
                commitSelected(selectedStaged, key: selectedKey)
                commitHover(hoverStaged, key: hoverKey)
                return EdgeSelectionOverlayUpdateSummary(
                    selected: componentResult(selectedStaged),
                    hover: componentResult(hoverStaged))
            } catch {
                invalidateAll()
                return EdgeSelectionOverlayUpdateSummary(
                    selected: .unavailable(overlayError(error)), hover: .cleared)
            }
        }

        if selectedChanged {
            do {
                let staged = try stageSelected(
                    selection: selection, table: table, vertexCount: mesh.vertices.count)
                commitSelected(staged, key: selectedKey)
                return EdgeSelectionOverlayUpdateSummary(
                    selected: componentResult(staged), hover: .unchanged)
            } catch {
                invalidateSelected()
                return EdgeSelectionOverlayUpdateSummary(
                    selected: .unavailable(overlayError(error)), hover: .unchanged)
            }
        }

        do {
            let staged = try stageHover(
                edgeID: validHover, table: table, vertexCount: mesh.vertices.count)
            commitHover(staged, key: hoverKey)
            return EdgeSelectionOverlayUpdateSummary(
                selected: .unchanged, hover: componentResult(staged))
        } catch {
            invalidateHover()
            return EdgeSelectionOverlayUpdateSummary(
                selected: .unchanged, hover: .unavailable(overlayError(error)))
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

    private struct StagedComponent {
        let buffer: MTLBuffer?
        let count: Int
    }

    private enum Component { case selected, hover }

    private func stageSelected(
        selection: EdgeSelection,
        table: MeshEdgeTable,
        vertexCount: Int
    ) throws -> StagedComponent {
        #if DEBUG
        selectedPairGenerationCount += 1
        #endif
        return try stage(
            edgeIDs: selection.selectedEdgeIDs(), table: table,
            vertexCount: vertexCount, component: .selected)
    }

    private func stageHover(
        edgeID: Int?,
        table: MeshEdgeTable,
        vertexCount: Int
    ) throws -> StagedComponent {
        guard let edgeID else { return StagedComponent(buffer: nil, count: 0) }
        #if DEBUG
        hoverPairGenerationCount += 1
        #endif
        return try stage(
            edgeIDs: [edgeID], table: table,
            vertexCount: vertexCount, component: .hover)
    }

    private func stage(
        edgeIDs: [Int],
        table: MeshEdgeTable,
        vertexCount: Int,
        component: Component
    ) throws -> StagedComponent {
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
        guard !result.isEmpty else { return StagedComponent(buffer: nil, count: 0) }
        let (bytes, overflow) = result.count.multipliedReportingOverflow(
            by: MemoryLayout<SIMD2<UInt32>>.stride)
        guard !overflow, bytes > 0 else { throw EdgeSelectionOverlayError.arithmeticOverflow }
        #if DEBUG
        switch component {
        case .selected: selectedAllocationCount += 1
        case .hover: hoverAllocationCount += 1
        }
        #endif
        guard let target = allocator.makeBuffer(device: device, length: bytes) else {
            throw EdgeSelectionOverlayError.allocationFailed
        }
        #if DEBUG
        switch component {
        case .selected: selectedCopyCount += 1
        case .hover: hoverCopyCount += 1
        }
        #endif
        guard allocator.copy(result, byteCount: bytes, to: target) else {
            throw EdgeSelectionOverlayError.copyFailed
        }
        return StagedComponent(buffer: target, count: result.count)
    }

    private func commitSelected(_ staged: StagedComponent, key: EdgeSelectedOverlayCacheKey) {
        selectedBuffer = staged.buffer
        selectedEdgeCount = staged.count
        selectedUploadedKey = key
        #if DEBUG
        if staged.count > 0 { selectedUploadCount += 1 }
        #endif
    }

    private func commitHover(_ staged: StagedComponent, key: EdgeHoverOverlayCacheKey) {
        hoverBuffer = staged.buffer
        hoverEdgeCount = staged.count
        hoverUploadedKey = key
        #if DEBUG
        if staged.count > 0 { hoverUploadCount += 1 }
        #endif
    }

    private func componentResult(_ staged: StagedComponent) -> EdgeOverlayComponentUpdate {
        staged.count == 0 ? .cleared : .updated
    }

    private func overlayError(_ error: Error) -> EdgeSelectionOverlayError {
        error as? EdgeSelectionOverlayError ?? .copyFailed
    }

    private func unavailableSummary(
        _ error: EdgeSelectionOverlayError
    ) -> EdgeSelectionOverlayUpdateSummary {
        EdgeSelectionOverlayUpdateSummary(
            selected: .unavailable(error), hover: .unavailable(error))
    }

    private func invalidateSelected() {
        selectedBuffer = nil
        selectedEdgeCount = 0
        selectedUploadedKey = nil
    }

    private func invalidateHover() {
        hoverBuffer = nil
        hoverEdgeCount = 0
        hoverUploadedKey = nil
    }

    private func invalidateAll() {
        invalidateSelected()
        invalidateHover()
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
