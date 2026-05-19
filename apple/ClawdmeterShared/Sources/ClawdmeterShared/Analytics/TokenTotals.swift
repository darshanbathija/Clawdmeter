import Foundation

/// Aggregated token counts + computed cost, summable across records / files /
/// time windows.
///
/// Per plan A5 + A16: dollars are the primary surface number with adaptive
/// precision (2 decimals when ≥ $0.01, 4 decimals when < $0.01). Cost is
/// stored as `Decimal` to avoid binary-float drift when accumulating many
/// small currency values.
///
/// `requestCount` is the heterogeneous-metric companion to token counts.
/// Providers whose telemetry exposes per-request counts but not per-request
/// tokens (Gemini via cloudcode-pa today) carry their activity here while
/// leaving `inputTokens`/`outputTokens`/`costUSD` at zero. AnalyticsTotalsGrid's
/// cell renderer decides per-cell whether to display "$X.YZ" (cost-bearing)
/// or "N reqs" (count-bearing) — see plan §Analytics schema split.
///
/// Codable note (X2 fix): swift's synthesized Codable does NOT honor property
/// initializers during decode — a missing JSON key throws `keyNotFound`.
/// We therefore ship a custom `init(from:)` using `decodeIfPresent ?? 0` so
/// the existing on-disk `analytics-cache.json` + iCloud-KV snapshots (written
/// before `requestCount` existed) decode cleanly to `requestCount = 0`.
///
/// `+` and `+=` make window aggregation a one-liner:
///   `byDay.values.reduce(.zero, +)`
public struct TokenTotals: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var reasoningTokens: Int
    public var costUSD: Decimal
    /// Per-request count for providers that expose request volume but not
    /// per-request token counts (Gemini). Zero for Claude/Codex records.
    /// X2 fix: custom Codable below ensures missing JSON keys decode to 0.
    public var requestCount: Int

    public static let zero = TokenTotals(
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        reasoningTokens: 0,
        costUSD: 0,
        requestCount: 0
    )

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        costUSD: Decimal = 0,
        requestCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
        self.requestCount = requestCount
    }

    /// Sum of all token kinds. Used as the "headline" tokens number in the UI.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
    }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            costUSD: lhs.costUSD + rhs.costUSD,
            requestCount: lhs.requestCount + rhs.requestCount
        )
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs = lhs + rhs
    }

    // MARK: - Codable (X2 fix)

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, reasoningTokens, costUSD, requestCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        self.cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        self.reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        self.costUSD = try c.decodeIfPresent(Decimal.self, forKey: .costUSD) ?? 0
        // New field added 2026-05-19 (Gemini provider). Missing key in older
        // analytics-cache.json / iCloud snapshots decodes to 0 — not a default
        // applied at init, but an explicit decode-time fallback.
        self.requestCount = try c.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(reasoningTokens, forKey: .reasoningTokens)
        try c.encode(costUSD, forKey: .costUSD)
        try c.encode(requestCount, forKey: .requestCount)
    }
}
