// One-per-client WS channel that pipes CodexSubscriptionRelay events to
// a paired iPhone using op `codex-stream-subscribe`. v0.7.3.

import Foundation
import Network
import OSLog
import Combine
import ClawdmeterShared

private let codexStreamLogger = Logger(subsystem: "com.clawdmeter.mac", category: "CodexStreamWS")

@MainActor
public final class CodexStreamWebSocketChannel: WSChannel {
    private let connection: NWConnection
    private let session: AgentSession
    private let relay: CodexSubscriptionRelay
    private var cancellable: AnyCancellable?

    public init(connection: NWConnection, session: AgentSession, relay: CodexSubscriptionRelay) {
        self.connection = connection
        self.session = session
        self.relay = relay
    }

    public func start() {
        codexStreamLogger.info("codex-stream-subscribe started session=\(self.session.id.uuidString, privacy: .public)")
        sendGreeting()
        cancellable = relay.subscribe(sessionId: session.id)
            .sink { [weak self] event in
                Task { @MainActor [weak self] in await self?.push(event: event) }
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
        connection.cancel()
    }

    private func sendGreeting() {
        send(jsonObject: [
            "type": "subscribed",
            "sessionId": session.id.uuidString,
            "sdkProvisioned": CodexSDKManager.shared.isProvisioned,
            "sdkModeActive": CodexSDKManager.shared.sdkModeActive,
        ])
    }

    private func push(event: CodexRelayEvent) async {
        var body: [String: Any] = [
            "type": "codex-relay-event",
            "kind": event.kind.rawValue,
            "receivedAt": ISO8601DateFormatter().string(from: event.receivedAt),
            "raw": event.rawDict(),
        ]
        if let sid = event.subscriptionId { body["subscriptionId"] = sid }
        if let tid = event.threadId { body["threadId"] = tid }
        send(jsonObject: body)
    }

    private func send(jsonObject: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "codex-stream-event", metadata: [meta])
        connection.send(content: data, contentContext: ctx, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}
