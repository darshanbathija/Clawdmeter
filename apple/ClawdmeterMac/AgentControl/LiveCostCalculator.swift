import Foundation
import ClawdmeterShared
import OSLog

private let costLogger = Logger(subsystem: "com.clawdmeter.mac", category: "LiveCostCalculator")

/// Pre-flight cost estimate for the new-session sheet (D3 / Phase 8).
///
/// Sessions v2 Phase 0 ships this as a stub returning nil — UI shows
/// "no estimate yet." Phase 8 wires the real LiteLLM-pricing + per-repo
/// historical-average estimate using the existing analytics layer.
@MainActor
public final class LiveCostCalculator {
    public static let shared = LiveCostCalculator()

    /// Best-effort estimate. Returns nil until Phase 8 lands the proper
    /// (repo, model)-bucket lookup.
    public func estimate(
        repoKey: String,
        model: String,
        effort: ReasoningEffort?,
        goalLength: Int
    ) -> Double? {
        // Phase 8 wiring will:
        // 1. Look up per-repo per-model historical TokenTotals from
        //    `UsageHistorySnapshot.totals(for: .anthropic)`.
        // 2. Compute average tokens-per-session × `effortMultiplier`.
        // 3. Apply `Pricing.shared.cost(for: model, tokens: scaled)`.
        // For now: nil (UI shows "no estimate yet").
        nil
    }
}

/// Rate-limit cap projection. Sessions v2 Phase 8.
///
/// Tunable assumption: 1% weekly utilization ≈ 50k tokens on Anthropic Max.
/// Real per-account ratios come from the analytics layer in Phase 8.
@MainActor
public final class RateLimitChecker {
    public static let shared = RateLimitChecker()

    public func projectedWeeklyCap(
        currentWeeklyPct: Int,
        estimatedTokens: Int
    ) -> Double {
        let baseline = Double(currentWeeklyPct) / 100.0
        let added = Double(estimatedTokens) / 5_000_000.0  // 50k tokens × 100% = 5M tokens
        return min(1.0, baseline + added)
    }

    public func suggestedSwap(currentModel: String) -> String? {
        switch currentModel {
        case let m where m.contains("opus"):
            return "claude-sonnet-4-6"
        case let m where m.contains("sonnet"):
            return "claude-haiku-4-5-20251001"
        default:
            return nil
        }
    }
}
