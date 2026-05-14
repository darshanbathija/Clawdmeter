import XCTest
@testable import ClawdmeterShared

final class BurnRatePredictorTests: XCTestCase {

    private func usage(at: Int, pct: Int, epoch: Int = 10_000) -> UsageData {
        UsageData(
            sessionPct: pct,
            sessionResetMins: 60,
            sessionEpoch: epoch,
            weeklyPct: 0,
            weeklyResetMins: 600,
            weeklyEpoch: 100_000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(at))
        )
    }

    func test_belowMinSamples_returnsNilProjection() {
        let p = BurnRatePredictor()
        p.update(with: usage(at: 0, pct: 10))
        p.update(with: usage(at: 60, pct: 12))
        let proj = p.project()
        XCTAssertNil(proj.minutesRemaining)
        XCTAssertEqual(proj.sampleCount, 2)
    }

    func test_steadyLinearBurn_projectsCorrectly() {
        // 1% per minute starting at 50% → should hit 100% in ~50 minutes.
        let p = BurnRatePredictor()
        for i in 0...10 {
            p.update(with: usage(at: i * 60, pct: 50 + i))
        }
        let proj = p.project()
        XCTAssertNotNil(proj.minutesRemaining)
        // Last sample at i=10: 60% used at minute 10, so 40% remaining at 1%/min = ~40 min
        XCTAssertEqual(proj.minutesRemaining!, 40, accuracy: 2,
                       "Linear extrapolation should project ~40 min remaining within 2 min")
        XCTAssertEqual(proj.slopePctPerMinute, 1.0, accuracy: 0.05)
    }

    func test_flatBurn_returnsNoProjection() {
        // Same percent across all samples → slope ~0 → no projection.
        let p = BurnRatePredictor()
        for i in 0...10 {
            p.update(with: usage(at: i * 60, pct: 50))
        }
        let proj = p.project()
        XCTAssertNil(proj.minutesRemaining)
    }

    func test_sessionEpochChange_resetsWindow() {
        // First window (epoch 10000)
        let p = BurnRatePredictor()
        for i in 0...10 {
            p.update(with: usage(at: i * 60, pct: 80 + i, epoch: 10_000))
        }
        XCTAssertGreaterThan(p.sampleCount, 0, "Sanity: first window has samples")

        // New session starts (epoch 20000). First sample of new window should clear history.
        p.update(with: usage(at: 700, pct: 0, epoch: 20_000))
        XCTAssertEqual(p.sampleCount, 1,
                       "Plan E14: epoch change must reset rolling window to prevent reset-boundary nonsense")
    }

    func test_oldSamples_prunedAfterWindow() {
        let p = BurnRatePredictor()
        // Insert sample at t=0
        p.update(with: usage(at: 0, pct: 10))
        // Insert sample at t=31 min later — window is 30 min, so the t=0 should drop
        p.update(with: usage(at: 31 * 60, pct: 12))
        // 4 more recent ones to allow projection
        p.update(with: usage(at: 32 * 60, pct: 13))
        p.update(with: usage(at: 33 * 60, pct: 14))
        p.update(with: usage(at: 34 * 60, pct: 15))
        XCTAssertEqual(p.sampleCount, 4, "Sample older than window should be pruned")
    }

    // Plan E2 / Codex #9 + #18-19: hysteresis filters bursty usage.

    func test_warningGate_firesOnlyAfterThresholdConsecutivePolls() {
        var gate = BurnRatePredictor.WarningGate(level: .fiveMin)
        // First two hits: don't fire yet
        XCTAssertFalse(gate.evaluate(minutesRemaining: 4))
        XCTAssertFalse(gate.evaluate(minutesRemaining: 3))
        // Third consecutive hit: fire
        XCTAssertTrue(gate.evaluate(minutesRemaining: 2))
        // Subsequent hit at same level: do NOT re-fire
        XCTAssertFalse(gate.evaluate(minutesRemaining: 1))
    }

    func test_warningGate_resetsOnNonHit() {
        var gate = BurnRatePredictor.WarningGate(level: .fiveMin)
        XCTAssertFalse(gate.evaluate(minutesRemaining: 4))
        XCTAssertFalse(gate.evaluate(minutesRemaining: 3))
        // Non-hit (above threshold): resets counter
        XCTAssertFalse(gate.evaluate(minutesRemaining: 30))
        // Counter restarted: need 3 more hits to fire
        XCTAssertFalse(gate.evaluate(minutesRemaining: 4))
        XCTAssertFalse(gate.evaluate(minutesRemaining: 3))
        XCTAssertTrue(gate.evaluate(minutesRemaining: 2))
    }

    func test_warningGate_burstyUsage_doesNotProduceFalsePositive() {
        // Codex #9: bursty Claude usage (heavy 5min idle 25min) should NOT trigger.
        var gate = BurnRatePredictor.WarningGate(level: .fiveMin)
        XCTAssertFalse(gate.evaluate(minutesRemaining: 4)) // Burst
        XCTAssertFalse(gate.evaluate(minutesRemaining: nil)) // Idle gap — counter resets
        XCTAssertFalse(gate.evaluate(minutesRemaining: 4)) // Another burst
        XCTAssertFalse(gate.evaluate(minutesRemaining: nil)) // Another idle gap
        XCTAssertFalse(gate.evaluate(minutesRemaining: 4)) // Third burst alone is NOT enough
        // No fire happened across alternating bursts.
    }
}
