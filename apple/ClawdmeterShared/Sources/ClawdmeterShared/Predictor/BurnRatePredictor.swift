import Foundation

/// Rolling-window predictor for "minutes until session limit hit at current burn rate."
///
/// Plan E4: lives in `ClawdmeterShared`; each platform's poller owns an instance.
/// Plan E14: resets window when `sessionEpoch` changes (window-boundary correctness).
/// Plan D7: V1 surface is in-app visualization only; notifications deferred to V1.5.
/// Codex #9 + #18-19 addressed: hysteresis filters bursty-usage noise; explicit
/// window reset on epoch change prevents nonsense projections across reset boundaries.
public final class BurnRatePredictor: @unchecked Sendable {

    public struct Sample: Equatable, Sendable {
        public let serverTime: Date
        public let sessionPct: Int
        public let sessionEpoch: Int
    }

    public struct Projection: Equatable, Sendable {
        /// Estimated wall-clock time when session usage hits 100%, or `nil` if
        /// burn rate is non-positive (idle / declining).
        public let estimatedHitAt: Date?
        /// Minutes until projected hit, or `nil` for non-positive burn rate.
        public let minutesRemaining: Int?
        /// Sample count behind the projection. Below `minSamples` the projection is suppressed.
        public let sampleCount: Int
        /// Slope of the linear regression, in percent-per-minute. Zero for flat usage.
        public let slopePctPerMinute: Double
    }

    /// Window length in seconds. Plan: 30-minute rolling window.
    public let windowSeconds: TimeInterval = 30 * 60
    /// Minimum samples required before producing a projection (avoids 2-point hallucinations).
    public let minSamples = 4

    private var samples: [Sample] = []

    public init() {}

    public var sampleCount: Int { samples.count }

    /// Drop the rolling window. Called externally on session-epoch change (E14)
    /// or when the user explicitly resets.
    public func reset() {
        samples.removeAll()
    }

    /// Ingest a new `UsageData` snapshot. Auto-resets the window on session-epoch change.
    public func update(with usage: UsageData) {
        let incomingSample = Sample(
            serverTime: usage.updatedAt,
            sessionPct: usage.sessionPct,
            sessionEpoch: usage.sessionEpoch
        )

        // Epoch change = new session window started. Clear history (E14).
        if let last = samples.last, last.sessionEpoch != incomingSample.sessionEpoch {
            samples.removeAll()
        }

        samples.append(incomingSample)
        prune(referenceTime: incomingSample.serverTime)
    }

    /// Drop samples older than `windowSeconds` relative to `referenceTime`.
    private func prune(referenceTime: Date) {
        let cutoff = referenceTime.addingTimeInterval(-windowSeconds)
        samples.removeAll { $0.serverTime < cutoff }
    }

    /// Compute the current projection.
    public func project() -> Projection {
        guard samples.count >= minSamples else {
            return Projection(
                estimatedHitAt: nil,
                minutesRemaining: nil,
                sampleCount: samples.count,
                slopePctPerMinute: 0
            )
        }

        // Linear regression: x = minutes since first sample, y = sessionPct
        let t0 = samples[0].serverTime
        let xs = samples.map { $0.serverTime.timeIntervalSince(t0) / 60.0 }
        let ys = samples.map { Double($0.sessionPct) }

        let n = Double(samples.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map(*).reduce(0, +)
        let sumXX = xs.map { $0 * $0 }.reduce(0, +)

        let denom = n * sumXX - sumX * sumX
        guard denom > 0.0001 else {
            return Projection(estimatedHitAt: nil, minutesRemaining: nil, sampleCount: samples.count, slopePctPerMinute: 0)
        }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        guard slope > 0.01 else {
            return Projection(estimatedHitAt: nil, minutesRemaining: nil, sampleCount: samples.count, slopePctPerMinute: slope)
        }

        let nowMinutes = xs.last ?? 0
        let nowPct = intercept + slope * nowMinutes
        let remainingPct = 100.0 - nowPct
        guard remainingPct > 0 else {
            return Projection(estimatedHitAt: samples.last?.serverTime, minutesRemaining: 0, sampleCount: samples.count, slopePctPerMinute: slope)
        }

        let minutesRemaining = Int((remainingPct / slope).rounded())
        let estimatedHitAt = (samples.last?.serverTime ?? Date()).addingTimeInterval(Double(minutesRemaining) * 60)

        return Projection(
            estimatedHitAt: estimatedHitAt,
            minutesRemaining: minutesRemaining,
            sampleCount: samples.count,
            slopePctPerMinute: slope
        )
    }

    /// V1.5 notification gating helper.
    /// Plan: fire `.timeSensitive` for 5-min warning ONLY when projection < 5 min for 3 consecutive polls.
    public struct WarningGate: Sendable {
        public enum Level: Int, Sendable, Comparable {
            case thirtyMin = 30
            case fifteenMin = 15
            case fiveMin = 5

            public static func < (lhs: Level, rhs: Level) -> Bool {
                lhs.rawValue > rhs.rawValue  // 5 < 15 < 30 in terms of urgency ordering
            }
        }

        public let level: Level
        public let consecutivePollsThreshold: Int = 3
        private(set) var consecutiveHits = 0

        public init(level: Level) {
            self.level = level
        }

        /// Returns true exactly once when threshold first met. Caller should debounce
        /// repeat fires within the same window.
        public mutating func evaluate(minutesRemaining: Int?) -> Bool {
            guard let minutes = minutesRemaining, minutes <= level.rawValue, minutes >= 0 else {
                consecutiveHits = 0
                return false
            }
            consecutiveHits += 1
            return consecutiveHits == consecutivePollsThreshold
        }
    }
}
