import Foundation
import MetalKit
import simd

protocol VertexSelectionIDBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer?
    func copy(_ ids: [UInt32], byteCount: Int, to buffer: MTLBuffer) -> Bool
}

struct MetalVertexSelectionIDBufferAllocator: VertexSelectionIDBufferAllocating {
    func makeBuffer(device: MTLDevice, length: Int) -> MTLBuffer? {
        device.makeBuffer(length: length, options: .storageModeShared)
    }

    func copy(_ ids: [UInt32], byteCount: Int, to buffer: MTLBuffer) -> Bool {
        ids.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, byteCount > 0, buffer.length >= byteCount else { return false }
            buffer.contents().copyMemory(from: base, byteCount: byteCount)
            return true
        }
    }
}

struct VertexSelectedOverlayCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let topologyFingerprint: UInt64
    let selectionVersion: VertexSelectionVersion
}

struct VertexHoverOverlayCacheKey: Equatable {
    let topologyID: UUID
    let topologyRevision: UInt64
    let topologyFingerprint: UInt64
    let hoverVersion: VertexSelectionVersion
}

enum VertexSelectionOverlayError: Error, Equatable {
    case staleTopology, staleSelection, invalidVertexID, arithmeticOverflow, allocationFailed, copyFailed
}

enum VertexOverlayComponentUpdate: Equatable {
    case unchanged, updated, cleared
    case unavailable(VertexSelectionOverlayError)
}

struct VertexSelectionOverlayUpdateSummary: Equatable {
    let selected: VertexOverlayComponentUpdate
    let hover: VertexOverlayComponentUpdate
    static let unchanged = Self(selected: .unchanged, hover: .unchanged)
}

final class VertexSelectionOverlayRenderer {
    private let device: MTLDevice
    private let allocator: VertexSelectionIDBufferAllocating
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var selectedBuffer: MTLBuffer?
    private var hoverBuffer: MTLBuffer?
    private(set) var selectedCount = 0
    private(set) var hoverCount = 0
    private(set) var selectedUploadedKey: VertexSelectedOverlayCacheKey?
    private(set) var hoverUploadedKey: VertexHoverOverlayCacheKey?
    #if DEBUG
    private(set) var selectedUploadCount = 0
    private(set) var hoverUploadCount = 0
    var hasSelectedBuffer: Bool { selectedBuffer != nil }
    var hasHoverBuffer: Bool { hoverBuffer != nil }
    #endif

    init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat,
          allocator: VertexSelectionIDBufferAllocating = MetalVertexSelectionIDBufferAllocator()) {
        guard let vertex = library.makeFunction(name: "vertexSelectionVertex"),
              let fragment = library.makeFunction(name: "vertexSelectionFragment") else { return nil }
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

    func update(mesh: EditableMesh, table: MeshVertexTopologyTable?, selection: VertexSelection,
                hover: VertexHoverState) -> VertexSelectionOverlayUpdateSummary {
        guard let table, table.matches(mesh) else {
            invalidateAll(); return unavailable(.staleTopology)
        }
        guard selection.matches(table) else {
            invalidateAll(); return unavailable(.staleSelection)
        }
        let selectedKey = VertexSelectedOverlayCacheKey(
            topologyID: table.sourceTopologyID, topologyRevision: table.sourceTopologyRevision,
            topologyFingerprint: table.fingerprint, selectionVersion: selection.version)
        let hoverKey = VertexHoverOverlayCacheKey(
            topologyID: table.sourceTopologyID, topologyRevision: table.sourceTopologyRevision,
            topologyFingerprint: table.fingerprint, hoverVersion: hover.version)
        let selectedChanged = selectedUploadedKey != selectedKey
        let hoverChanged = hoverUploadedKey != hoverKey
        guard selectedChanged || hoverChanged else { return .unchanged }

        let selectedResult = selectedChanged ? stageResult(selection.selectedVertexIDs(), vertexCount: mesh.vertices.count) : nil
        let hoverResult = hoverChanged ? stageResult(hover.vertexID.map { [$0] } ?? [], vertexCount: mesh.vertices.count) : nil
        let selectedUpdate: VertexOverlayComponentUpdate
        switch selectedResult {
        case .success(let staged):
            commitSelected(staged, key: selectedKey)
            selectedUpdate = staged.count == 0 ? .cleared : .updated
        case .failure(let error):
            invalidateSelected(); selectedUpdate = .unavailable(error)
        case nil: selectedUpdate = .unchanged
        }
        let hoverUpdate: VertexOverlayComponentUpdate
        switch hoverResult {
        case .success(let staged):
            commitHover(staged, key: hoverKey)
            hoverUpdate = staged.count == 0 ? .cleared : .updated
        case .failure(let error):
            invalidateHover(); hoverUpdate = .unavailable(error)
        case nil: hoverUpdate = .unchanged
        }
        return VertexSelectionOverlayUpdateSummary(selected: selectedUpdate, hover: hoverUpdate)
    }

    func encode(encoder: MTLRenderCommandEncoder, vertexBuffer: MTLBuffer,
                viewProjection: simd_float4x4, model: simd_float4x4, displayScale: Float) {
        guard displayScale.isFinite, displayScale > 0 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setDepthBias(-3, slopeScale: -1, clamp: -0.0001)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        if let selectedBuffer, selectedCount > 0 {
            encode(buffer: selectedBuffer, count: selectedCount, pointSize: 8 * displayScale,
                   color: SIMD4(1, 0.72, 0.05, 1), encoder: encoder,
                   viewProjection: viewProjection, model: model)
        }
        if let hoverBuffer, hoverCount > 0 {
            encode(buffer: hoverBuffer, count: hoverCount, pointSize: 12 * displayScale,
                   color: SIMD4(1, 1, 1, 1), encoder: encoder,
                   viewProjection: viewProjection, model: model)
        }
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    private struct Staged { let buffer: MTLBuffer?; let count: Int }
    private func stageResult(_ ids: [UInt32], vertexCount: Int) -> Result<Staged, VertexSelectionOverlayError> {
        do { return .success(try stage(ids, vertexCount: vertexCount)) }
        catch let error as VertexSelectionOverlayError { return .failure(error) }
        catch { return .failure(.copyFailed) }
    }
    private func stage(_ ids: [UInt32], vertexCount: Int) throws -> Staged {
        guard ids.allSatisfy({ Int($0) < vertexCount }) else { throw VertexSelectionOverlayError.invalidVertexID }
        guard !ids.isEmpty else { return Staged(buffer: nil, count: 0) }
        let (bytes, overflow) = ids.count.multipliedReportingOverflow(by: MemoryLayout<UInt32>.stride)
        guard !overflow, bytes > 0 else { throw VertexSelectionOverlayError.arithmeticOverflow }
        guard let buffer = allocator.makeBuffer(device: device, length: bytes) else { throw VertexSelectionOverlayError.allocationFailed }
        guard allocator.copy(ids, byteCount: bytes, to: buffer) else { throw VertexSelectionOverlayError.copyFailed }
        return Staged(buffer: buffer, count: ids.count)
    }

    private func commitSelected(_ staged: Staged, key: VertexSelectedOverlayCacheKey) {
        selectedBuffer = staged.buffer; selectedCount = staged.count; selectedUploadedKey = key
        #if DEBUG
        if staged.count > 0 { selectedUploadCount += 1 }
        #endif
    }
    private func commitHover(_ staged: Staged, key: VertexHoverOverlayCacheKey) {
        hoverBuffer = staged.buffer; hoverCount = staged.count; hoverUploadedKey = key
        #if DEBUG
        if staged.count > 0 { hoverUploadCount += 1 }
        #endif
    }
    private func encode(buffer: MTLBuffer, count: Int, pointSize: Float, color: SIMD4<Float>,
                        encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                        model: simd_float4x4) {
        var uniforms = VertexSelectionOverlayUniforms(
            viewProjection: viewProjection, model: model, pointSize: pointSize, color: color)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VertexSelectionOverlayUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
    }
    private func invalidateSelected() { selectedBuffer = nil; selectedCount = 0; selectedUploadedKey = nil }
    private func invalidateHover() { hoverBuffer = nil; hoverCount = 0; hoverUploadedKey = nil }
    private func invalidateAll() { invalidateSelected(); invalidateHover() }
    private func unavailable(_ error: VertexSelectionOverlayError) -> VertexSelectionOverlayUpdateSummary {
        Self.summary(selectedChanged: true, hoverChanged: true, error: error)
    }
    private static func summary(selectedChanged: Bool, hoverChanged: Bool,
                                error: VertexSelectionOverlayError) -> VertexSelectionOverlayUpdateSummary {
        .init(selected: selectedChanged ? .unavailable(error) : .unchanged,
              hover: hoverChanged ? .unavailable(error) : .unchanged)
    }
}

private struct VertexSelectionOverlayUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var pointSize: Float
    var color: SIMD4<Float>
}
