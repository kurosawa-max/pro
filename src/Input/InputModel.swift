import Foundation
import CoreGraphics

enum InputDevice: Equatable { case finger, pencil, indirect }

enum CameraInputPolicy {
    static func permitsCameraGesture(from device: InputDevice) -> Bool { device == .finger }
}

struct PencilSample: Equatable {
    var location: CGPoint
    var pressure: Float
    var altitude: Float
    var azimuth: Float
    var timestamp: TimeInterval

    init(location: CGPoint, force: CGFloat, maximumForce: CGFloat, altitude: CGFloat, azimuth: CGFloat, timestamp: TimeInterval) {
        self.location = location
        pressure = maximumForce > 0 ? Float(min(max(force / maximumForce, 0), 1)) : 1
        self.altitude = Float(altitude)
        self.azimuth = Float(azimuth)
        self.timestamp = timestamp
    }
}

struct FaceSelectionTapConfiguration: Equatable {
    var maximumMovement: CGFloat = 12
    var maximumDuration: TimeInterval = 0.5
}

struct FaceSelectionTapTracker {
    private(set) var startLocation: CGPoint?
    private(set) var startTimestamp: TimeInterval?
    private(set) var maximumDistanceSquared: CGFloat = 0
    private(set) var isCancelled = false

    var isTracking: Bool { startLocation != nil && startTimestamp != nil && !isCancelled }

    mutating func begin(_ sample: PencilSample) {
        startLocation = sample.location
        startTimestamp = sample.timestamp
        maximumDistanceSquared = 0
        isCancelled = false
    }

    mutating func update(_ sample: PencilSample) {
        guard let startLocation, !isCancelled else { return }
        let dx = sample.location.x - startLocation.x
        let dy = sample.location.y - startLocation.y
        maximumDistanceSquared = max(maximumDistanceSquared, dx * dx + dy * dy)
    }

    mutating func finish(
        _ sample: PencilSample,
        viewport: CGRect,
        configuration: FaceSelectionTapConfiguration = FaceSelectionTapConfiguration()
    ) -> CGPoint? {
        defer { reset() }
        guard let startTimestamp, isTracking,
              configuration.maximumMovement.isFinite, configuration.maximumMovement >= 0,
              configuration.maximumDuration.isFinite, configuration.maximumDuration >= 0 else { return nil }
        update(sample)
        let duration = sample.timestamp - startTimestamp
        guard duration.isFinite, duration >= 0, duration <= configuration.maximumDuration,
              maximumDistanceSquared <= configuration.maximumMovement * configuration.maximumMovement,
              viewport.contains(sample.location) else { return nil }
        return sample.location
    }

    mutating func cancel() {
        isCancelled = true
        reset()
    }

    mutating func reset() {
        startLocation = nil
        startTimestamp = nil
        maximumDistanceSquared = 0
        isCancelled = false
    }
}
