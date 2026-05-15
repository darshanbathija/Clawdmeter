import Foundation
import WatchConnectivity
import ClawdmeterShared
import OSLog

private let bridgeLogger = Logger(subsystem: "com.clawdmeter.ios", category: "WatchPlanBridge")

/// iPhone-side WCSession bridge: pushes plan-waiting state to the paired
/// Watch and accepts approve-plan messages back. Mirrors the existing
/// `WatchTokenBridge` shape.
///
/// Per D10: when the iPhone's notification manager processes a plan-ready
/// event, we update the count + push a fresh applicationContext to the
/// Watch. The Watch's `.accessoryCircular` complication reads from the
/// App Group UserDefaults and updates its badge on next timeline reload.
public final class WatchPlanBridgeIOS: NSObject, WCSessionDelegate {

    public static let shared = WatchPlanBridgeIOS()

    public let client: AgentControlClient

    public override init() {
        self.client = AgentControlClient()
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    public init(client: AgentControlClient) {
        self.client = client
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Push the latest pending-plan count + previewing fields to the Watch.
    public func updateContext(count: Int, latestGoal: String?, latestPlanSummary: String?, latestSessionId: UUID?) {
        var context: [String: Any] = ["planWaitingCount": count]
        if let latestGoal { context["latestGoal"] = latestGoal }
        if let latestPlanSummary { context["latestPlanSummary"] = latestPlanSummary }
        if let id = latestSessionId { context["latestSessionId"] = id.uuidString }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            bridgeLogger.debug("updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        Task { @MainActor in
            await handle(message: message)
            replyHandler(["ok": true])
        }
    }
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in
            await handle(message: message)
        }
    }
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        Task { @MainActor in
            await handle(message: userInfo)
        }
    }

    @MainActor
    private func handle(message: [String: Any]) async {
        guard let op = message["op"] as? String else { return }
        switch op {
        case "approvePlan":
            if let raw = message["sessionId"] as? String, let id = UUID(uuidString: raw) {
                await client.approvePlan(sessionId: id)
                bridgeLogger.info("Approved plan from Watch for session \(id.uuidString, privacy: .public)")
            }
        default:
            bridgeLogger.debug("Unknown WCSession op: \(op, privacy: .public)")
        }
    }
}
