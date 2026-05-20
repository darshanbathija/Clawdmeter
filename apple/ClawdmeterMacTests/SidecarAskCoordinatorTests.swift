import XCTest
@testable import Clawdmeter

/// v0.7.7 regression suite for `SidecarAskCoordinator` (T3 from the
/// v0.6.0 plan). The cross-surface ask_user(...) race needs three
/// invariants:
///   1. First decision wins, sidecar's `awaitDecision` resumes once.
///   2. Second decision returns `.lost(prior, priorSource)`.
///   3. 60s timeout (compressed to ~50ms in tests) defaults to
///      `.deny` with source `.timeout`.
final class SidecarAskCoordinatorTests: XCTestCase {

    func test_firstDecideWins() async {
        let coordinator = SidecarAskCoordinator(timeout: 30.0)
        let promptUUID = UUID()

        // Fire the sidecar's awaitDecision concurrently.
        async let awaited: (SidecarAskCoordinator.Decision,
                            SidecarAskCoordinator.Source) =
            coordinator.awaitDecision(
                promptUUID: promptUUID,
                question: "Confirm cost watcher threshold?"
            )

        // Give the actor a tick to register the prompt before we decide.
        try? await Task.sleep(nanoseconds: 10_000_000)

        let mac = await coordinator.decide(
            promptUUID: promptUUID,
            decision: .approve,
            source: .mac
        )
        guard case .won(let decision) = mac else {
            XCTFail("expected first decide to win, got \(mac)"); return
        }
        XCTAssertEqual(decision, .approve)

        let (resolved, source) = await awaited
        XCTAssertEqual(resolved, .approve)
        XCTAssertEqual(source, .mac)
    }

    func test_secondDecideLoses() async {
        let coordinator = SidecarAskCoordinator(timeout: 30.0)
        let promptUUID = UUID()

        async let awaited: (SidecarAskCoordinator.Decision,
                            SidecarAskCoordinator.Source) =
            coordinator.awaitDecision(
                promptUUID: promptUUID,
                question: "ok?"
            )
        try? await Task.sleep(nanoseconds: 10_000_000)

        let first = await coordinator.decide(
            promptUUID: promptUUID,
            decision: .approve,
            source: .ios
        )
        guard case .won = first else {
            XCTFail("expected first to win, got \(first)"); return
        }
        let second = await coordinator.decide(
            promptUUID: promptUUID,
            decision: .deny,
            source: .mac
        )
        guard case .lost(let prior, let priorSource) = second else {
            XCTFail("expected second to lose, got \(second)"); return
        }
        XCTAssertEqual(prior, .approve)
        XCTAssertEqual(priorSource, .ios)

        // Sidecar still resumed with the first decision.
        let (resolved, source) = await awaited
        XCTAssertEqual(resolved, .approve)
        XCTAssertEqual(source, .ios)
    }

    func test_unknownPromptReturnsUnknown() async {
        let coordinator = SidecarAskCoordinator(timeout: 30.0)
        let result = await coordinator.decide(
            promptUUID: UUID(),  // never registered
            decision: .approve,
            source: .mac
        )
        XCTAssertEqual(result, .unknownPrompt)
    }

    func test_timeoutDefaultsToDeny() async {
        // 50ms timeout for a snappy test; the production default is 60s.
        let coordinator = SidecarAskCoordinator(timeout: 0.05)
        let promptUUID = UUID()

        let (decision, source) = await coordinator.awaitDecision(
            promptUUID: promptUUID,
            question: "no one will answer"
        )
        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(source, .timeout)
    }

    func test_lateDecideAfterTimeoutLoses() async {
        let coordinator = SidecarAskCoordinator(timeout: 0.05)
        let promptUUID = UUID()

        // Let the timeout fire.
        _ = await coordinator.awaitDecision(
            promptUUID: promptUUID,
            question: "slow surface"
        )

        // Decision arriving after the timeout should `.lost` against
        // the timeout marker, not silently override.
        let late = await coordinator.decide(
            promptUUID: promptUUID,
            decision: .approve,
            source: .mac
        )
        guard case .lost(let prior, let priorSource) = late else {
            XCTFail("expected late decide to lose, got \(late)"); return
        }
        XCTAssertEqual(prior, .deny)
        XCTAssertEqual(priorSource, .timeout)
    }
}
