import Foundation
import WatchConnectivity
import Combine

/// Receives plan-ready state from the paired iPhone via `WCSession`
/// `applicationContext` (latest-wins) + `userInfo` (queued delivery).
///
/// Mirrors the shape of `WatchTokenBridge` (from the existing analytics
/// feature) so the Watch app's wiring is consistent.
///
/// Wire shape: a dictionary in the App Group UserDefaults under
/// `clawdmeter.watch.planWaitingCount`, `clawdmeter.watch.latestGoal`,
/// `clawdmeter.watch.latestPlanSummary`, `clawdmeter.watch.latestSessionId`.
public final class WatchPlanBridge: NSObject, ObservableObject, WCSessionDelegate {

    public static let shared = WatchPlanBridge()

    @Published public private(set) var planWaitingCount: Int = 0
    @Published public private(set) var latestGoal: String?
    @Published public private(set) var latestPlanSummary: String?
    @Published public private(set) var latestSessionId: String?

    private let defaultsSuiteName = "group.76S62SDSD3.com.clawdmeter"
    private lazy var defaults = UserDefaults(suiteName: defaultsSuiteName)

    public override init() {
        super.init()
        loadFromDefaults()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            // Process whatever context is already there.
            apply(context: session.receivedApplicationContext)
        }
    }

    // MARK: - State

    private func loadFromDefaults() {
        planWaitingCount = defaults?.integer(forKey: "clawdmeter.watch.planWaitingCount") ?? 0
        latestGoal = defaults?.string(forKey: "clawdmeter.watch.latestGoal")
        latestPlanSummary = defaults?.string(forKey: "clawdmeter.watch.latestPlanSummary")
        latestSessionId = defaults?.string(forKey: "clawdmeter.watch.latestSessionId")
    }

    private func apply(context: [String: Any]) {
        if let count = context["planWaitingCount"] as? Int {
            planWaitingCount = count
            defaults?.set(count, forKey: "clawdmeter.watch.planWaitingCount")
        }
        if let goal = context["latestGoal"] as? String {
            latestGoal = goal
            defaults?.set(goal, forKey: "clawdmeter.watch.latestGoal")
        }
        if let summary = context["latestPlanSummary"] as? String {
            latestPlanSummary = summary
            defaults?.set(summary, forKey: "clawdmeter.watch.latestPlanSummary")
        }
        if let id = context["latestSessionId"] as? String {
            latestSessionId = id
            defaults?.set(id, forKey: "clawdmeter.watch.latestSessionId")
        }
    }

    // MARK: - Approve

    public func approve() {
        guard let sessionId = latestSessionId else { return }
        let message: [String: Any] = [
            "op": "approvePlan",
            "sessionId": sessionId,
        ]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in }
        } else {
            // Queue via transferUserInfo if not reachable.
            WCSession.default.transferUserInfo(message)
        }
        // Clear local state optimistically; iPhone will push a fresh
        // context when the approval lands.
        planWaitingCount = max(0, planWaitingCount - 1)
        defaults?.set(planWaitingCount, forKey: "clawdmeter.watch.planWaitingCount")
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            self.apply(context: applicationContext)
        }
    }
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        DispatchQueue.main.async {
            self.apply(context: userInfo)
        }
    }
}
