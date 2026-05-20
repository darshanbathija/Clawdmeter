// v0.7.4: WebSocket bridge from CodexSubscriptionRelay → paired client.
// Op `codex-stream-subscribe` on the daemon dispatcher. Each SDK event the
// sidecar emits is forwarded as a JSON text frame so iOS / Watch can
// observe a Codex SDK session live.
//
// Multi-subscriber by construction: the relay's PassthroughSubject lets
// multiple WS channels (one per iOS client) AND the local
// `CodexSDKEventIngestor` subscribe to the same session without
// contending for the single AsyncStream slot the v0.7.2 relay had.
//
// Wire envelope:
//   { "kind": "<event-kind>",
//     "threadId": "...",
//     "subscriptionId": "...",
//     "receivedAt": "<iso8601>",
//     "raw": { ...sdk payload... } }

import Foundation
import Network
import OSLog
import Combine
import ClawdmeterShared

private let codexStreamLogger = Logger(
    subsystem: "com.clawdmeter.mac",
    category: "CodexStreamWS"
)

@MainActor
public final class CodexStreamWebSocketChannel: WSChannel {

    private let connection: NWConnection
    private let session: AgentSession
    private let relay: CodexSubscriptionRelay
    private var cancellable: AnyCancellable?

    public init(connection: NWConnection,
                session: AgentSession,
                relay: CodexSubscriptionRelay = .shared) {
        self.connection = connection
        self.session = session
        self.relay = relay
    }

    public func start() {
        codexStreamLogger.info("codex-stream-subscribe started session=\(self.session.id.uuidString, privacy: .public)")
        // Send a `subscribed` ack so the client knows the channel is live.
        sendJSON(["type": "subscribed", "sessionId": session.id.uuidString])
        cancellable = relay.subscribe(sessionId: session.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] _ in
                self?.sendJSON(["type": "stream_closed"])
            }, receiveValue: { [weak self] event in
                self?.send(event: event)
            })
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
        connection.cancel()
        codexStreamLogger.info("codex-stream-subscribe stopped session=\(self.session.id.uuidString, privacy: .public)")
    }

    // MARK: - Send

    private func send(event: CodexRelayEvent) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelope: [String: Any] = [
            "type": "event",
            "kind": event.kind.rawValue,
            "threadId": event.threadId as Any,
            "subscriptionId": event.subscriptionId as Any,
            "receivedAt": iso.string(from: event.receivedAt),
            "raw": event.rawDict(),
        ]
        sendJSON(envelope)
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.fragmentsAllowed]
        ) else {
            codexStreamLogger.warning("codex-stream-subscribe encode failed session=\(self.session.id.uuidString, privacy: .public)")
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "codex-stream", metadata: [meta])
        connection.send(
            content: body,
            contentContext: ctx,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    codexStreamLogger.debug("codex-stream send failed: \(error.localizedDescription)")
                }
            }
        )
    }
}
