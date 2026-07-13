import SwiftUI
import MetalKit

struct MetalCanvas: UIViewRepresentable {
    @ObservedObject var model: WorkspaceModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> SculptMTKView {
        let view = SculptMTKView(frame: .zero)
        guard let renderer = MetalRenderer(view: view, profiler: model.profiler) else { return view }
        context.coordinator.renderer = renderer
        renderer.objectTransform = model.objectTransform
        renderer.gizmoState = model.translationGizmoState
        renderer.showsTranslationGizmo = model.showsTranslationGizmo
        view.delegate = renderer; view.preferredFramesPerSecond = 60; view.isPaused = false
        view.onPencilBegan = { [weak coordinator = context.coordinator] sample in coordinator?.pencilBegan(sample, in: view) }
        view.onPencilMoved = { [weak coordinator = context.coordinator] sample in coordinator?.pencilMoved(sample, in: view) }
        view.onPencilEnded = { [weak coordinator = context.coordinator] in coordinator?.inputEnded() }
        view.onPencilCancelled = { [weak coordinator = context.coordinator] in coordinator?.inputCancelled() }
        view.onHover = { [weak coordinator = context.coordinator] point in coordinator?.hover(point, in: view) }
        context.coordinator.installGestures(on: view)
        renderer.update(mesh: model.mesh)
        return view
    }

    func updateUIView(_ view: SculptMTKView, context: Context) {
        context.coordinator.model = model
        context.coordinator.renderer?.camera = model.camera
        context.coordinator.renderer?.objectTransform = model.objectTransform
        context.coordinator.renderer?.gizmoState = model.translationGizmoState
        #if DEBUG
        context.coordinator.renderer?.showsTranslationGizmo = model.showsTranslationGizmo && !model.isBenchmarkRunning
        #else
        context.coordinator.renderer?.showsTranslationGizmo = model.showsTranslationGizmo
        #endif
        context.coordinator.renderer?.update(mesh: model.mesh)
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var model: WorkspaceModel
        var renderer: MetalRenderer?
        private var orbitStart = CameraState(), panStart = CameraState(), zoomStart: Float = 0
        init(model: WorkspaceModel) { self.model = model }

        func pencilBegan(_ sample: PencilSample, in view: UIView) {
            guard let renderer, let ray = renderer.ray(at: sample.location, viewSize: view.bounds.size) else { return }
            if let hit = model.translationGizmoHit(ray: ray, scale: renderer.gizmoWorldScale),
               model.beginTranslationGizmoDrag(handle: hit.handle, ray: ray,
                                                cameraDirection: renderer.cameraViewDirection) { return }
            model.beginStroke()
            model.updateStroke(sample: sample, ray: ray)
        }
        func pencilMoved(_ sample: PencilSample, in view: UIView) {
            guard let ray = renderer?.ray(at: sample.location, viewSize: view.bounds.size) else { return }
            if model.translationGizmoState.isDragging, let renderer {
                model.updateTranslationGizmoDrag(ray: ray, cameraDirection: renderer.cameraViewDirection)
            } else { model.updateStroke(sample: sample, ray: ray) }
        }

        func inputEnded() {
            if model.translationGizmoState.isDragging { model.endTranslationGizmoDrag() }
            else { model.endStroke() }
        }

        func inputCancelled() {
            if model.translationGizmoState.isDragging { model.cancelTranslationGizmoDrag() }
            else { model.cancelStroke() }
        }

        func hover(_ point: CGPoint?, in view: UIView) {
            guard let point, let renderer, let ray = renderer.ray(at: point, viewSize: view.bounds.size) else {
                model.hoverLocation = nil
                model.updateTranslationGizmoHover(ray: nil, scale: 1)
                return
            }
            model.updateTranslationGizmoHover(ray: ray, scale: renderer.gizmoWorldScale)
            model.hoverLocation = model.translationGizmoState.hoverHandle == nil ? point : nil
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
            !model.translationGizmoState.isDragging
        }

        @objc private func orbit(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                if let view = gesture.view, let renderer,
                   let ray = renderer.ray(at: gesture.location(in: view), viewSize: view.bounds.size),
                   let hit = model.translationGizmoHit(ray: ray, scale: renderer.gizmoWorldScale),
                   model.beginTranslationGizmoDrag(handle: hit.handle, ray: ray,
                                                    cameraDirection: renderer.cameraViewDirection) { return }
                orbitStart = model.camera
            }
            if model.translationGizmoState.isDragging {
                guard let view = gesture.view, let renderer,
                      let ray = renderer.ray(at: gesture.location(in: view), viewSize: view.bounds.size) else { return }
                switch gesture.state {
                case .ended: model.updateTranslationGizmoDrag(ray: ray, cameraDirection: renderer.cameraViewDirection); model.endTranslationGizmoDrag()
                case .cancelled, .failed: model.cancelTranslationGizmoDrag()
                default: model.updateTranslationGizmoDrag(ray: ray, cameraDirection: renderer.cameraViewDirection)
                }
                return
            }
            let p = gesture.translation(in: gesture.view)
            model.camera.yaw = orbitStart.yaw + Float(p.x) * 0.008
            model.camera.pitch = min(max(orbitStart.pitch + Float(p.y) * 0.008, -1.5), 1.5)
        }
        @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { zoomStart = model.camera.distance }
            model.camera.distance = min(max(zoomStart / Float(gesture.scale), 1.2), 20)
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { panStart = model.camera }
            let p = gesture.translation(in: gesture.view)
            let scale = model.camera.distance * 0.0015
            let right = SIMD3<Float>(cos(model.camera.yaw), 0, -sin(model.camera.yaw))
            model.camera.target = panStart.target - right * Float(p.x) * scale + SIMD3<Float>(0, 1, 0) * Float(p.y) * scale
        }
    }
}

final class SculptMTKView: MTKView {
    var onPencilBegan: ((PencilSample) -> Void)?
    var onPencilMoved: ((PencilSample) -> Void)?
    var onPencilEnded: (() -> Void)?
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
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if touches.contains(where: { $0.type == .pencil }) { onPencilEnded?() } }
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
    @available(iOS 16.1, *) @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        onHover?(recognizer.state == .ended || recognizer.state == .cancelled ? nil : recognizer.location(in: self))
    }
}
