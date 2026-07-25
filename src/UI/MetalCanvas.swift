import SwiftUI
import MetalKit

struct MetalCanvas: UIViewRepresentable {
    @ObservedObject var model: WorkspaceModel
    var isInputSuppressed = false

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, isInputSuppressed: isInputSuppressed)
    }
    func makeUIView(context: Context) -> SculptMTKView {
        let view = SculptMTKView(frame: .zero)
        guard let renderer = MetalRenderer(view: view, profiler: model.profiler) else { return view }
        context.coordinator.renderer = renderer
        renderer.objectTransform = model.objectTransform
        renderer.gizmoState = model.translationGizmoState
        renderer.rotationGizmoState = model.rotationGizmoState
        renderer.scaleGizmoState = model.scaleGizmoState
        renderer.gizmoMode = model.gizmoMode
        renderer.showsTranslationGizmo = model.showsTranslationGizmo
        renderer.updateDiagnostics(data: model.currentMeshDiagnosticsOverlay,
                                   revision: model.meshDiagnosticsOverlayRevision,
                                   options: model.meshDiagnosticsOverlayOptions)
        view.delegate = renderer; view.preferredFramesPerSecond = 60; view.isPaused = false
        view.onPencilBegan = { [weak coordinator = context.coordinator] sample in coordinator?.pencilBegan(sample, in: view) }
        view.onPencilMoved = { [weak coordinator = context.coordinator] sample in coordinator?.pencilMoved(sample, in: view) }
        view.onPencilEnded = { [weak coordinator = context.coordinator] sample in
            coordinator?.inputEnded(sample, in: view)
        }
        view.onPencilCancelled = { [weak coordinator = context.coordinator] in coordinator?.inputCancelled() }
        view.onHover = { [weak coordinator = context.coordinator] point in coordinator?.hover(point, in: view) }
        context.coordinator.installGestures(on: view)
        renderer.update(mesh: model.mesh)
        renderer.updateFaceSelection(mesh: model.mesh, selection: model.faceSelection)
        model.handleEdgeSelectionOverlayUpdate(renderer.updateEdgeSelection(
            mesh: model.mesh, table: model.meshEdgeTable,
            selection: model.edgeSelection, hoveredEdgeID: model.hoveredEdgeID,
            drawableSizePixels: view.drawableSize, displayScale: view.contentScaleFactor))
        renderer.showsFaceSelection = model.interactionMode == .faceSelect
        renderer.showsEdgeSelection = model.interactionMode == .edgeSelect
        return view
    }

    func updateUIView(_ view: SculptMTKView, context: Context) {
        context.coordinator.model = model
        context.coordinator.setInputSuppressed(isInputSuppressed)
        context.coordinator.renderer?.camera = model.camera
        context.coordinator.renderer?.objectTransform = model.objectTransform
        context.coordinator.renderer?.gizmoState = model.translationGizmoState
        context.coordinator.renderer?.rotationGizmoState = model.rotationGizmoState
        context.coordinator.renderer?.scaleGizmoState = model.scaleGizmoState
        context.coordinator.renderer?.gizmoMode = model.gizmoMode
        #if DEBUG
        context.coordinator.renderer?.showsTranslationGizmo = model.showsTranslationGizmo && !model.isBenchmarkRunning
        #else
        context.coordinator.renderer?.showsTranslationGizmo = model.showsTranslationGizmo
        #endif
        context.coordinator.renderer?.updateDiagnostics(data: model.currentMeshDiagnosticsOverlay,
                                                        revision: model.meshDiagnosticsOverlayRevision,
                                                        options: model.meshDiagnosticsOverlayOptions)
        context.coordinator.renderer?.update(mesh: model.mesh)
        context.coordinator.renderer?.updateFaceSelection(mesh: model.mesh, selection: model.faceSelection)
        if let result = context.coordinator.renderer?.updateEdgeSelection(
            mesh: model.mesh, table: model.meshEdgeTable,
            selection: model.edgeSelection, hoveredEdgeID: model.hoveredEdgeID,
            drawableSizePixels: view.drawableSize, displayScale: view.contentScaleFactor) {
            model.handleEdgeSelectionOverlayUpdate(result)
        }
        context.coordinator.renderer?.showsFaceSelection = model.interactionMode == .faceSelect
        context.coordinator.renderer?.showsEdgeSelection = model.interactionMode == .edgeSelect
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var model: WorkspaceModel
        var renderer: MetalRenderer?
        private(set) var isInputSuppressed: Bool
        private var orbitStart = CameraState(), panStart = CameraState(), zoomStart: Float = 0
        private var faceSelectionTap = FaceSelectionTapTracker()
        init(model: WorkspaceModel, isInputSuppressed: Bool = false) {
            self.model = model
            self.isInputSuppressed = isInputSuppressed
        }

        func setInputSuppressed(_ suppressed: Bool) {
            guard suppressed != isInputSuppressed else { return }
            isInputSuppressed = suppressed
            guard suppressed else { return }
            faceSelectionTap.cancel()
            if model.isGizmoDragging { model.cancelAllGizmoDrags() }
            else { model.cancelStroke() }
            model.hoverLocation = nil
            model.clearEdgeHover()
            updateGizmoHover(ray: nil, scale: 1)
        }

        func pencilBegan(_ sample: PencilSample, in view: UIView) {
            guard !isInputSuppressed else { return }
            guard let renderer, let ray = renderer.ray(at: sample.location, viewSize: view.bounds.size) else { return }
            if beginGizmoDrag(ray: ray, renderer: renderer) { return }
            if model.interactionMode == .faceSelect || model.interactionMode == .edgeSelect {
                guard model.interactionMode == .faceSelect
                    ? model.isFaceSelectionInteractionEnabled
                    : model.isEdgeSelectionInteractionEnabled else { return }
                faceSelectionTap.begin(sample)
                return
            }
            model.beginStroke()
            model.updateStroke(sample: sample, ray: ray)
        }
        func pencilMoved(_ sample: PencilSample, in view: UIView) {
            guard !isInputSuppressed else { return }
            if model.isGizmoDragging, let renderer {
                guard let ray = renderer.ray(at: sample.location, viewSize: view.bounds.size) else { return }
                updateGizmoDrag(ray: ray, renderer: renderer)
            } else if faceSelectionTap.isTracking {
                if model.interactionMode == .faceSelect || model.interactionMode == .edgeSelect {
                    faceSelectionTap.update(sample)
                }
                else { faceSelectionTap.cancel() }
            } else {
                guard let ray = renderer?.ray(at: sample.location, viewSize: view.bounds.size) else { return }
                model.updateStroke(sample: sample, ray: ray)
            }
        }

        func inputEnded(_ sample: PencilSample?, in view: UIView) {
            guard !isInputSuppressed else { return }
            if model.isGizmoDragging {
                faceSelectionTap.cancel()
                endGizmoDrag()
            } else if faceSelectionTap.isTracking {
                guard model.interactionMode == .faceSelect || model.interactionMode == .edgeSelect,
                      let sample,
                      let point = faceSelectionTap.finish(sample, viewport: view.bounds),
                      let ray = renderer?.ray(at: point, viewSize: view.bounds.size) else {
                    faceSelectionTap.cancel()
                    return
                }
                if model.interactionMode == .faceSelect {
                    _ = model.selectFace(fromWorldRay: ray)
                } else if let renderer {
                    _ = model.selectEdge(
                        fromWorldRay: ray, screenPoint: point,
                        viewportSize: view.bounds.size, viewProjection: renderer.viewProjection)
                }
            } else {
                model.endStroke()
            }
        }

        func inputCancelled() {
            if faceSelectionTap.isTracking { faceSelectionTap.cancel() }
            else if model.isGizmoDragging { model.cancelAllGizmoDrags() }
            else { model.cancelStroke() }
        }

        func hover(_ point: CGPoint?, in view: UIView) {
            guard !isInputSuppressed else {
                model.hoverLocation = nil
                model.clearEdgeHover()
                updateGizmoHover(ray: nil, scale: 1)
                return
            }
            guard let point, let renderer, let ray = renderer.ray(at: point, viewSize: view.bounds.size) else {
                model.hoverLocation = nil
                model.clearEdgeHover()
                updateGizmoHover(ray: nil, scale: 1)
                return
            }
            updateGizmoHover(ray: ray, scale: renderer.gizmoWorldScale)
            let hasHover: Bool
            switch model.gizmoMode {
            case .translate: hasHover = model.translationGizmoState.hoverHandle != nil
            case .rotate: hasHover = model.rotationGizmoState.hoverHandle != nil
            case .scale: hasHover = model.scaleGizmoState.hoverHandle != nil
            }
            if model.interactionMode == .edgeSelect, !hasHover {
                model.updateEdgeHover(
                    fromWorldRay: ray, screenPoint: point, viewportSize: view.bounds.size,
                    viewProjection: renderer.viewProjection)
            } else if model.interactionMode == .edgeSelect {
                model.updateEdgeHover(
                    fromWorldRay: nil, screenPoint: nil, viewportSize: view.bounds.size,
                    viewProjection: renderer.viewProjection)
            }
            model.hoverLocation = hasHover
                || model.interactionMode == .faceSelect
                || model.interactionMode == .edgeSelect ? nil : point
        }

        private func beginGizmoDrag(ray: Ray, renderer: MetalRenderer) -> Bool {
            switch model.gizmoMode {
            case .translate:
                guard let hit = model.translationGizmoHit(ray: ray, scale: renderer.gizmoWorldScale) else { return false }
                return model.beginTranslationGizmoDrag(handle: hit.handle, ray: ray,
                                                       cameraDirection: renderer.cameraViewDirection)
            case .rotate:
                guard let hit = model.rotationGizmoHit(ray: ray, scale: renderer.gizmoWorldScale) else { return false }
                return model.beginRotationGizmoDrag(handle: hit.handle, ray: ray)
            case .scale:
                guard let hit = model.scaleGizmoHit(ray: ray, scale: renderer.gizmoWorldScale) else { return false }
                return model.beginScaleGizmoDrag(handle: hit.handle, ray: ray,
                                                 cameraDirection: renderer.cameraViewDirection,
                                                 referenceLength: renderer.gizmoWorldScale)
            }
        }

        private func updateGizmoDrag(ray: Ray, renderer: MetalRenderer) {
            if model.translationGizmoState.isDragging {
                model.updateTranslationGizmoDrag(ray: ray, cameraDirection: renderer.cameraViewDirection)
            } else if model.rotationGizmoState.isDragging {
                model.updateRotationGizmoDrag(ray: ray)
            } else if model.scaleGizmoState.isDragging {
                model.updateScaleGizmoDrag(ray: ray, cameraDirection: renderer.cameraViewDirection)
            }
        }

        private func endGizmoDrag() {
            if model.translationGizmoState.isDragging { model.endTranslationGizmoDrag() }
            else if model.rotationGizmoState.isDragging { model.endRotationGizmoDrag() }
            else if model.scaleGizmoState.isDragging { model.endScaleGizmoDrag() }
        }

        private func updateGizmoHover(ray: Ray?, scale: Float) {
            switch model.gizmoMode {
            case .translate: model.updateTranslationGizmoHover(ray: ray, scale: scale)
            case .rotate: model.updateRotationGizmoHover(ray: ray, scale: scale)
            case .scale: model.updateScaleGizmoHover(ray: ray, scale: scale)
            }
        }

        func installGestures(on view: UIView) {
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:))); orbit.maximumNumberOfTouches = 1
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:))); pan.minimumNumberOfTouches = 2
            let zoom = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:)))
            [orbit, pan, zoom].forEach {
                $0.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                $0.delegate = self
                view.addGestureRecognizer($0)
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !isInputSuppressed && !model.isGizmoDragging
        }

        @objc private func orbit(_ gesture: UIPanGestureRecognizer) {
            guard !isInputSuppressed else { return }
            if gesture.state == .began {
                if let view = gesture.view, let renderer,
                   let ray = renderer.ray(at: gesture.location(in: view), viewSize: view.bounds.size),
                   beginGizmoDrag(ray: ray, renderer: renderer) { return }
                orbitStart = model.camera
            }
            if model.isGizmoDragging {
                switch gesture.state {
                case .cancelled, .failed: model.cancelAllGizmoDrags()
                case .ended:
                    if let view = gesture.view, let renderer,
                       let ray = renderer.ray(at: gesture.location(in: view), viewSize: view.bounds.size) {
                        updateGizmoDrag(ray: ray, renderer: renderer)
                    }
                    endGizmoDrag()
                default:
                    guard let view = gesture.view, let renderer,
                          let ray = renderer.ray(at: gesture.location(in: view), viewSize: view.bounds.size) else { return }
                    updateGizmoDrag(ray: ray, renderer: renderer)
                }
                return
            }
            let p = gesture.translation(in: gesture.view)
            model.camera.yaw = orbitStart.yaw + Float(p.x) * 0.008
            model.camera.pitch = min(max(orbitStart.pitch + Float(p.y) * 0.008, -1.5), 1.5)
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                model.commitCameraChange(from: orbitStart)
            }
        }
        @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
            guard !isInputSuppressed, !model.isGizmoDragging else { return }
            if gesture.state == .began { zoomStart = model.camera.distance }
            let before = CameraState(yaw: model.camera.yaw, pitch: model.camera.pitch,
                                     distance: zoomStart, target: model.camera.target)
            model.camera.distance = min(max(zoomStart / Float(gesture.scale), 1.2), 20)
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                model.commitCameraChange(from: before)
            }
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard !isInputSuppressed, !model.isGizmoDragging else { return }
            if gesture.state == .began { panStart = model.camera }
            let p = gesture.translation(in: gesture.view)
            let scale = model.camera.distance * 0.0015
            let right = SIMD3<Float>(cos(model.camera.yaw), 0, -sin(model.camera.yaw))
            model.camera.target = panStart.target - right * Float(p.x) * scale + SIMD3<Float>(0, 1, 0) * Float(p.y) * scale
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                model.commitCameraChange(from: panStart)
            }
        }
    }
}

final class SculptMTKView: MTKView {
    var onPencilBegan: ((PencilSample) -> Void)?
    var onPencilMoved: ((PencilSample) -> Void)?
    var onPencilEnded: ((PencilSample?) -> Void)?
    var onPencilCancelled: (() -> Void)?
    var onHover: ((CGPoint?) -> Void)?

    override init(frame: CGRect, device: MTLDevice? = nil) {
        super.init(frame: frame, device: device)
        configureInput()
    }
    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureInput()
    }

    private func configureInput() {
        isMultipleTouchEnabled = true
        if #available(iOS 16.1, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue),
                                       NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            addGestureRecognizer(hover)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { emit(touches, event: event, began: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { emit(touches, event: event, began: false) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .pencil }) else { return }
        onPencilEnded?(pencilSample(from: touch))
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .pencil }) { onPencilCancelled?() }
    }

    private func emit(_ touches: Set<UITouch>, event: UIEvent?, began: Bool) {
        for touch in touches where touch.type == .pencil {
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            var isFirstSample = began
            for value in samples {
                let sample = PencilSample(location: value.location(in: self), force: value.force,
                                          maximumForce: value.maximumPossibleForce, altitude: value.altitudeAngle,
                                          azimuth: value.azimuthAngle(in: self), timestamp: value.timestamp)
                if isFirstSample {
                    onPencilBegan?(sample)
                    isFirstSample = false
                } else {
                    onPencilMoved?(sample)
                }
            }
        }
    }

    private func pencilSample(from touch: UITouch) -> PencilSample {
        PencilSample(location: touch.location(in: self), force: touch.force,
                     maximumForce: touch.maximumPossibleForce, altitude: touch.altitudeAngle,
                     azimuth: touch.azimuthAngle(in: self), timestamp: touch.timestamp)
    }
    @available(iOS 16.1, *) @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        onHover?(recognizer.state == .ended || recognizer.state == .cancelled ? nil : recognizer.location(in: self))
    }
}
