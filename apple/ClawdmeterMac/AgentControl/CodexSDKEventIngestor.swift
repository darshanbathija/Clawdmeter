// v0.7.3: subscribes to CodexSubscriptionRelay events and feeds them
// into SessionChatStore so the chat-subscribe WS pipeline carries
// Codex SDK observations to iOS without a separate channel.

import Foundation
import Combine
import OSLog
import ClawdmeterShared

private let ingestorLogger = Logger(subsystem: "com.clawdmeter.mac", category: "CodexSDKEventIngestor")

@MainActor
public final class CodexSDKEventIngestor {
    private let sessionId: UUID
    private weak var store: SessionChatStore?
    private let relay: CodexSubscriptionRelay
    private var cancellable: AnyCancellable?

    public init(sessionId: UUID, store: SessionChatStore, relay: CodexSubscriptionRelay = .shared) {
        self.sessionId = sessionId
        self.store = store
        self.relay = relay
    }

    public func start() {
        guard cancellable == nil else { return }
        ingestorLogger.info("CodexSDKEventIngestor.start session=\(self.sessionId.uuidString, privacy: .public)")
        cancellable = relay.subscribe(sessionId: sessionId)
            .sink { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event: event) }
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func handle(event: CodexRelayEvent) {
        guard let store = store else { return }
        switch event.kind {
        case .item:
            handleItem(rawDict: event.rawDict(), at: event.receivedAt, store: store)
        case .turnCompleted:
            handleTurnCompleted(rawDict: event.rawDict(), at: event.receivedAt, store: store)
        case .turnFailed:
            let raw = event.rawDict()
            let msg = (raw["error"] as? [String: Any])?["message"] as? String ?? "Turn failed"
            appendMeta(store: store,
                       id: "codex-sdk-turn-failed-\(event.receivedAt.timeIntervalSince1970)",
                       title: "Turn failed", body: msg, at: event.receivedAt, isError: true)
        case .error:
            let raw = event.rawDict()
            let msg = raw["message"] as? String ?? "Stream error"
            appendMeta(store: store,
                       id: "codex-sdk-error-\(event.receivedAt.timeIntervalSince1970)",
                       title: "Codex error", body: msg, at: event.receivedAt, isError: true)
        case .threadStarted, .turnStarted, .streamStarted, .streamDone,
             .streamError, .observerReady, .unknown:
            break
        }
    }

    private func handleItem(rawDict: [String: Any], at: Date, store: SessionChatStore) {
        guard let item = rawDict["item"] as? [String: Any],
              let itemType = item["type"] as? String,
              let itemId = item["id"] as? String
        else { return }
        // Only ingest on terminal state (.completed) — avoids double-
        // appending during item.started → item.updated streaming.
        let isCompleted: Bool = {
            if let status = item["status"] as? String { return status == "completed" }
            return true
        }()
        guard isCompleted else { return }

        switch itemType {
        case "agent_message":
            let text = item["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-msg-\(itemId)", kind: .assistantText,
                            title: "Codex", body: text, at: at)
            ], at: at)

        case "reasoning":
            let text = item["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-reasoning-\(itemId)", kind: .meta,
                            title: "thinking", body: text, at: at)
            ], at: at)

        case "command_execution":
            let command = item["command"] as? String ?? "(unknown)"
            let output = item["aggregated_output"] as? String ?? ""
            let exitCode = item["exit_code"] as? Int
            let isError = (item["status"] as? String) == "failed"
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-cmd-\(itemId)", kind: .toolCall,
                            title: "bash", body: command,
                            detail: output.isEmpty ? nil : output,
                            at: at, isError: isError),
                ChatMessage(id: "codex-sdk-cmd-result-\(itemId)", kind: .toolResult,
                            title: "bash",
                            body: exitCode == nil ? output : "exit=\(exitCode!)\n\(output)",
                            at: at, isError: isError)
            ], at: at)

        case "file_change":
            let changes = (item["changes"] as? [[String: Any]]) ?? []
            let body = changes.compactMap { c -> String? in
                guard let kind = c["kind"] as? String, let path = c["path"] as? String else { return nil }
                return "\(kind) \(path)"
            }.joined(separator: "\n")
            let isError = (item["status"] as? String) == "failed"
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-edit-\(itemId)", kind: .toolCall,
                            title: "edit",
                            body: body.isEmpty ? "(no changes)" : body,
                            at: at, isError: isError)
            ], at: at)

        case "mcp_tool_call":
            let server = item["server"] as? String ?? "?"
            let tool = item["tool"] as? String ?? "?"
            let args: String = {
                guard let dict = item["arguments"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let str = String(data: data, encoding: .utf8) else { return "" }
                return str
            }()
            let isError = (item["status"] as? String) == "failed"
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-mcp-\(itemId)", kind: .toolCall,
                            title: "\(server)/\(tool)", body: args, at: at, isError: isError)
            ], at: at)

        case "web_search":
            let query = item["query"] as? String ?? ""
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-search-\(itemId)", kind: .toolCall,
                            title: "web_search", body: query, at: at)
            ], at: at)

        case "todo_list":
            let items = (item["items"] as? [[String: Any]]) ?? []
            let body = items.compactMap { row -> String? in
                guard let text = row["text"] as? String else { return nil }
                let done = (row["completed"] as? Bool) ?? false
                return "\(done ? "[x]" : "[ ]") \(text)"
            }.joined(separator: "\n")
            store.appendSDKMessages([
                ChatMessage(id: "codex-sdk-todo-\(itemId)", kind: .meta,
                            title: "todo", body: body, at: at)
            ], at: at)

        case "error":
            let message = item["message"] as? String ?? "Codex item error"
            appendMeta(store: store, id: "codex-sdk-item-err-\(itemId)",
                       title: "Codex error", body: message, at: at, isError: true)

        default:
            ingestorLogger.debug("CodexSDKEventIngestor: unhandled item type \(itemType, privacy: .public)")
        }
    }

    private func handleTurnCompleted(rawDict: [String: Any], at: Date, store: SessionChatStore) {
        guard let usage = rawDict["usage"] as? [String: Any] else { return }
        let input = usage["input_tokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let output = (usage["output_tokens"] as? Int ?? 0)
            + (usage["reasoning_output_tokens"] as? Int ?? 0)
        store.appendSDKMessages([
            ChatMessage(id: "codex-sdk-usage-\(at.timeIntervalSince1970)", kind: .meta,
                        title: "tokens",
                        body: "input=\(input) cached=\(cached) output=\(output)",
                        at: at)
        ], at: at,
        deltaInputTokens: input, deltaOutputTokens: output,
        deltaCacheReadTokens: cached)
    }

    private func appendMeta(store: SessionChatStore, id: String, title: String,
                            body: String, at: Date, isError: Bool) {
        store.appendSDKMessages([
            ChatMessage(id: id, kind: .meta, title: title, body: body,
                        at: at, isError: isError)
        ], at: at)
    }
}
