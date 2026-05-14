import Foundation

/// One snapshot of Claude Code usage across the session (5h) and weekly (7d) windows.
///
/// Carries `sessionEpoch` and `weeklyEpoch` per plan E14 (reset-boundary integrity).
/// Newer epoch always beats older epoch, regardless of `updatedAt` — this prevents
/// stale-pre-reset payloads from overriding fresh-post-reset payloads under clock drift.
public struct UsageData: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case allowed
        case limited
        case unknown
        /// No active session window — either the source hasn't been used
        /// recently, or the most recent recorded window has already reset
        /// without a fresh use to start a new one. Surfaced primarily for
        /// Codex, which can only observe state from CLI rollout files.
        case notStarted
    }

    public enum BindingWindow: String, Codable, Sendable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case unknown
    }

    public let sessionPct: Int           // 0...100
    public let sessionResetMins: Int     // minutes until session window reset
    public let sessionEpoch: Int         // epoch seconds of the current session-window reset (E14)
    public let weeklyPct: Int            // 0...100
    public let weeklyResetMins: Int
    public let weeklyEpoch: Int          // epoch seconds of the current weekly-window reset (E14)
    public let status: Status            // composite: "limited" if either window limited
    public let representativeClaim: BindingWindow
    public let updatedAt: Date           // server-time, parsed from API response `date:` header
    public let organizationID: String?   // surfaced for V2 multi-account (see plan roadmap)

    public init(
        sessionPct: Int,
        sessionResetMins: Int,
        sessionEpoch: Int,
        weeklyPct: Int,
        weeklyResetMins: Int,
        weeklyEpoch: Int,
        status: Status,
        representativeClaim: BindingWindow,
        updatedAt: Date,
        organizationID: String? = nil
    ) {
        self.sessionPct = sessionPct
        self.sessionResetMins = sessionResetMins
        self.sessionEpoch = sessionEpoch
        self.weeklyPct = weeklyPct
        self.weeklyResetMins = weeklyResetMins
        self.weeklyEpoch = weeklyEpoch
        self.status = status
        self.representativeClaim = representativeClaim
        self.updatedAt = updatedAt
        self.organizationID = organizationID
    }

    /// Mood derived from session usage. Drives gauge color and animation cadence.
    /// Mirrors firmware's idle/active/red-line mapping (plan: mood-state mapping).
    public enum Mood: String, Sendable {
        case idle
        case active
        case redLine
    }

    public var mood: Mood {
        switch sessionPct {
        case ..<30: return .idle
        case ..<75: return .active
        default: return .redLine
        }
    }

    /// Whether this snapshot is considered stale based on a wall-clock reference.
    /// Plan: stale when older than 90 seconds (visible-indicator threshold).
    public func isStale(referenceTime: Date, thresholdSeconds: TimeInterval = 90) -> Bool {
        referenceTime.timeIntervalSince(updatedAt) > thresholdSeconds
    }

    /// Plan E3 + E14: ordering uses `(epoch, updatedAt)` tuple.
    /// Returns true if `incoming` should replace `self`.
    public func shouldReplace(with incoming: UsageData) -> Bool {
        // New session window wins regardless of timestamp.
        if incoming.sessionEpoch != self.sessionEpoch {
            return incoming.sessionEpoch > self.sessionEpoch
        }
        // Same window: newer `updatedAt` wins.
        return incoming.updatedAt > self.updatedAt
    }
}
