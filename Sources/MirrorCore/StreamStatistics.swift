import Foundation

/// Running totals for a video stream, reported once per interval.
public struct StreamStatistics {
    public struct Report: Equatable, Sendable {
        public var framesPerSecond: Double
        public var kilobitsPerSecond: Double
        /// Time from the sender capturing a frame to this app having it ready to show, when known.
        public var meanAgeMilliseconds: Double?
        public var maxAgeMilliseconds: Double?

        public init(
            framesPerSecond: Double, kilobitsPerSecond: Double,
            meanAgeMilliseconds: Double?, maxAgeMilliseconds: Double?
        ) {
            self.framesPerSecond = framesPerSecond
            self.kilobitsPerSecond = kilobitsPerSecond
            self.meanAgeMilliseconds = meanAgeMilliseconds
            self.maxAgeMilliseconds = maxAgeMilliseconds
        }
    }

    private let interval: TimeInterval
    private var intervalStart: TimeInterval?
    private var frames = 0
    private var bytes = 0
    private var ageTotal: UInt64 = 0
    private var ageMaximum: UInt64 = 0
    private var agedFrames = 0

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    /// Forget everything; the next frame starts a new interval.
    public mutating func reset() {
        intervalStart = nil
        clearTotals()
    }

    /// Counts one frame at `time` (seconds on any steady clock). Returns a report when an interval has passed.
    /// The first frame only opens the interval, so rates cover exactly the time between two reports.
    public mutating func record(bytes frameBytes: Int, ageNanoseconds: UInt64?, at time: TimeInterval) -> Report? {
        guard let start = intervalStart else {
            intervalStart = time
            return nil
        }
        frames += 1
        bytes += frameBytes
        if let ageNanoseconds {
            ageTotal += ageNanoseconds
            ageMaximum = max(ageMaximum, ageNanoseconds)
            agedFrames += 1
        }
        let elapsed = time - start
        guard elapsed >= interval, elapsed > 0 else { return nil }
        let report = Report(
            framesPerSecond: Double(frames) / elapsed,
            kilobitsPerSecond: Double(bytes) * 8 / 1000 / elapsed,
            meanAgeMilliseconds: agedFrames > 0 ? Double(ageTotal) / Double(agedFrames) / 1_000_000 : nil,
            maxAgeMilliseconds: agedFrames > 0 ? Double(ageMaximum) / 1_000_000 : nil)
        intervalStart = time
        clearTotals()
        return report
    }

    private mutating func clearTotals() {
        frames = 0
        bytes = 0
        ageTotal = 0
        ageMaximum = 0
        agedFrames = 0
    }
}
