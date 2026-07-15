import Foundation
import QuartzCore

enum PerformanceMetric: CaseIterable, Hashable {
    case picking
    case sculpt
    case normalRebuild
    case vertexUpload
    case indexUpload
    case subdivision
    case frameCPU
    case frameInterval
}

struct RollingAverage: Equatable {
    let capacity: Int
    private(set) var sampleCount = 0
    private(set) var latest = 0.0
    private var samples: [Double] = []
    private var nextIndex = 0
    private var total = 0.0

    init(capacity: Int = 60) {
        self.capacity = max(capacity, 1)
        samples.reserveCapacity(self.capacity)
    }

    mutating func append(_ value: Double) {
        guard value.isFinite else { return }
        latest = value
        if samples.count < capacity {
            samples.append(value)
            total += value
            sampleCount = samples.count
            return
        }
        total -= samples[nextIndex]
        samples[nextIndex] = value
        total += value
        nextIndex = (nextIndex + 1) % capacity
        sampleCount = capacity
    }

    var average: Double {
        guard sampleCount > 0 else { return 0 }
        let result = total / Double(sampleCount)
        return result.isFinite ? result : 0
    }

    var minimum: Double { samples.min() ?? 0 }
    var maximum: Double { samples.max() ?? 0 }
}

struct PerformanceSample: Equatable {
    var latestMilliseconds = 0.0
    var averageMilliseconds = 0.0
    var sampleCount = 0
    var minimumMilliseconds = 0.0
    var maximumMilliseconds = 0.0
}

struct PerformanceSnapshot: Equatable {
    var vertexCount = 0
    var triangleCount = 0
    var samples: [PerformanceMetric: PerformanceSample] = [:]

    subscript(metric: PerformanceMetric) -> PerformanceSample {
        samples[metric] ?? PerformanceSample()
    }

    var framesPerSecond: Double {
        let interval = self[.frameInterval].averageMilliseconds
        guard interval.isFinite, interval > 0 else { return 0 }
        return 1_000 / interval
    }
}

final class PerformanceProfiler {
    static let rollingSampleCapacity = 60

    static var isInstrumentationCompiled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    #if DEBUG
    private let lock = NSLock()
    private var metrics = PerformanceProfiler.emptyMetrics()
    private var vertexCount = 0
    private var triangleCount = 0
    private var previousFrameTimestamp: CFTimeInterval?

    private static func emptyMetrics() -> [PerformanceMetric: RollingAverage] {
        Dictionary(uniqueKeysWithValues: PerformanceMetric.allCases.map {
            ($0, RollingAverage(capacity: rollingSampleCapacity))
        })
    }
    #endif

    @inline(__always)
    static func measure<Result>(
        _ profiler: PerformanceProfiler?,
        metric: PerformanceMetric,
        operation: () throws -> Result
    ) rethrows -> Result {
        #if DEBUG
        guard let profiler else { return try operation() }
        let started = CACurrentMediaTime()
        defer { profiler.record(metric, milliseconds: (CACurrentMediaTime() - started) * 1_000) }
        return try operation()
        #else
        return try operation()
        #endif
    }

    func record(_ metric: PerformanceMetric, milliseconds: Double) {
        #if DEBUG
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        metrics[metric]?.append(milliseconds)
        lock.unlock()
        #endif
    }

    func recordFrameBoundary() {
        #if DEBUG
        let timestamp = CACurrentMediaTime()
        guard timestamp.isFinite else { return }
        lock.lock()
        if let previousFrameTimestamp {
            metrics[.frameInterval]?.append((timestamp - previousFrameTimestamp) * 1_000)
        }
        previousFrameTimestamp = timestamp
        lock.unlock()
        #endif
    }

    func updateMeshCounts(vertexCount: Int, triangleCount: Int) {
        #if DEBUG
        lock.lock()
        self.vertexCount = max(vertexCount, 0)
        self.triangleCount = max(triangleCount, 0)
        lock.unlock()
        #endif
    }

    func reset(vertexCount: Int, triangleCount: Int) {
        #if DEBUG
        lock.lock()
        metrics = Self.emptyMetrics()
        previousFrameTimestamp = nil
        self.vertexCount = max(vertexCount, 0)
        self.triangleCount = max(triangleCount, 0)
        lock.unlock()
        #endif
    }

    func reset(_ metric: PerformanceMetric) {
        #if DEBUG
        lock.lock()
        metrics[metric] = RollingAverage(capacity: Self.rollingSampleCapacity)
        lock.unlock()
        #endif
    }

    func sampleCount(for metric: PerformanceMetric) -> Int {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        return metrics[metric]?.sampleCount ?? 0
        #else
        return 0
        #endif
    }

    func snapshot() -> PerformanceSnapshot {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        let samples = metrics.mapValues {
            PerformanceSample(
                latestMilliseconds: $0.latest,
                averageMilliseconds: $0.average,
                sampleCount: $0.sampleCount,
                minimumMilliseconds: $0.minimum,
                maximumMilliseconds: $0.maximum
            )
        }
        return PerformanceSnapshot(vertexCount: vertexCount, triangleCount: triangleCount, samples: samples)
        #else
        return PerformanceSnapshot()
        #endif
    }
}
