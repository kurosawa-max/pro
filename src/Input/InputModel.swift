import CoreGraphics

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

