// Daemon-side relay that ingests the Codex SDK observer sidecar's
// stdout (JSON-lines stream_event payloads) and republishes them as a
// Combine PassthroughSubject that multiple subscribers can attach to
// concurrently. Bridges between `tools/clawdmeter-codex-sdk/main.mjs`
// running in observer mode and the rest of the Mac daemon (chat-
// subscribe ingest via CodexSDKEventIngestor, WS clients via
// CodexStreamWebSocketChannel, audit log, etc.).
//
// v0.7.3 refactor: AsyncStream → multi-subscriber PassthroughSubject.
// One sidecar process per active session, but the EVENT stream is
// fan-out so multiple consumers observe the same flow without
// duplicating the sidecar.
//
// Lifecycle:
//   1. `subscribe(sessionId:)` returns a Publisher; multi-subscribe.
//      Subscribing does NOT start the sidecar.
//   2. `ensureRunning(session:workingDirectory:initialPrompt:)` spawns
//      the sidecar (or no-ops + forwards prompt when already running).
//      Promotes any pending subject from `subscribe`-before-running.
//   3. `forwardPrompt(sessionId:prompt:)` push a new turn.
//   4. `stop(sessionId:)` graceful shutdown + subject completion.

import Foundation
import Combine
import OSLog
import ClawdmeterShared

private let relayLogger = Logger(subsystem: "com.clawdmeter.mac", category: "CodexSubscriptionRelay")

public struct CodexRelayEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case threadStarted = "thread.started"
        case turnStarted = "turn.started"
        case item
        case turnCompleted = "turn.completed"
        case turnFailed = "turn.failed"
        case error
        case streamStarted = "stream_started"
        case streamDone = "stream_done"
        case streamError = "stream_error"
        case observerReady = "observer_ready"
        case unknown
    }

    public let kind: Kind
    public let subscriptionId: String?
    public let threadId: String?
    /// Raw event JSON as a string. Sendable-friendly.
    public let rawJSON: String
    public let receivedAt: Date

    public init(kind: Kind, subscriptionId: String?, threadId: String?,
                rawJSON: String, receivedAt: Date = Date()) {
        self.kind = kind
        self.subscriptionId = subscriptionId
        self.threadId = threadId
        self.rawJSON = rawJSON
        self.receivedAt = receivedAt
    }

    /// Decodes `rawJSON` back to `[String: Any]` for caller inspection.
    public func rawDict() -> [String: Any] {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

fileprivate final class ProcessHandle: @unchecked Sendable {
    let process: Process
    let stdinPipe: Pipe
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let subject: PassthroughSubject<CodexRelayEvent, Never>
    var lastThreadId: String?
    var lastSubscriptionId: String?

    init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe,
         subject: PassthroughSubject<CodexRelayEvent, Never>) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.subject = subject
    }
}

@MainActor
public final class CodexSubscriptionRelay {

    public static let shared = CodexSubscriptionRelay()

    private var active: [UUID: ProcessHandle] = [:]
    /// Subjects callers subscribed to BEFORE ensureRunning. Promoted to
    /// the sidecar's subject once it starts so early subscribers see
    /// events without a race.
    private var pendingSubjects: [UUID: PassthroughSubject<CodexRelayEvent, Never>] = [:]

    public init() {}

    public func subscribe(sessionId: UUID) -> AnyPublisher<CodexRelayEvent, Never> {
        if let handle = active[sessionId] {
            return handle.subject.eraseToAnyPublisher()
        }
        if let pending = pendingSubjects[sessionId] {
            return pending.eraseToAnyPublisher()
        }
        let subject = PassthroughSubject<CodexRelayEvent, Never>()
        pendingSubjects[sessionId] = subject
        return subject.eraseToAnyPublisher()
    }

    public func ensureRunning(
        session: AgentSession,
        workingDirectory: String,
        initialPrompt: String,
        threadId: String? = nil,
        model: String? = nil,
        sandboxMode: String? = nil,
        modelReasoningEffort: String? = nil
    ) throws {
        if let existing = active[session.id] {
            try forwardPrompt(handle: existing,
                              op: threadId == nil ? "start" : "resume",
                              workingDirectory: workingDirectory,
                              prompt: initialPrompt,
                              threadId: threadId,
                              model: model,
                              sandboxMode: sandboxMode,
                              modelReasoningEffort: modelReasoningEffort)
            return
        }
        guard CodexSDKManager.shared.isProvisioned else { throw RelayError.sdkNotProvisioned }
        guard let nodeBinary = CodexSDKManager.shared.locateNode() else { throw RelayError.nodeBinaryMissing }
        let mainJS = CodexSDKManager.shared.appSupportDir().appendingPathComponent("main.mjs")
        guard FileManager.default.fileExists(atPath: mainJS.path) else { throw RelayError.sidecarScriptMissing }

        let process = Process()
        process.executableURL = nodeBinary
        process.arguments = [mainJS.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let subject = pendingSubjects.removeValue(forKey: session.id)
            ?? PassthroughSubject<CodexRelayEvent, Never>()
        let handle = ProcessHandle(process: process, stdinPipe: stdin,
                                   stdoutPipe: stdout, stderrPipe: stderr,
                                   subject: subject)
        try process.run()
        relayLogger.info("Codex relay spawned pid=\(process.processIdentifier) session=\(session.id.uuidString, privacy: .public)")
        attachStdoutReader(handle: handle, sessionId: session.id)
        try writeLine(to: stdin, ["agent": "observer"])
        try forwardPrompt(handle: handle,
                          op: threadId == nil ? "start" : "resume",
                          workingDirectory: workingDirectory,
                          prompt: initialPrompt,
                          threadId: threadId,
                          model: model,
                          sandboxMode: sandboxMode,
                          modelReasoningEffort: modelReasoningEffort)
        active[session.id] = handle
    }

    public func forwardPrompt(sessionId: UUID, workingDirectory: String, prompt: String, threadId: String? = nil) throws {
        guard let handle = active[sessionId] else { throw RelayError.notSubscribed }
        try forwardPrompt(handle: handle,
                          op: threadId == nil ? "start" : "resume",
                          workingDirectory: workingDirectory,
                          prompt: prompt, threadId: threadId,
                          model: nil, sandboxMode: nil, modelReasoningEffort: nil)
    }

    public func stop(sessionId: UUID) async {
        guard let handle = active.removeValue(forKey: sessionId) else { return }
        do { try writeLine(to: handle.stdinPipe, ["op": "shutdown"]) } catch {}
        let exited = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if !handle.process.isRunning { cont.resume(returning: true); return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                cont.resume(returning: false)
            }
        }
        if !exited { handle.process.terminate() }
        handle.subject.send(completion: .finished)
    }

    public func stopAll() async {
        let ids = Array(active.keys)
        for id in ids { await stop(sessionId: id) }
        for (_, s) in pendingSubjects { s.send(completion: .finished) }
        pendingSubjects.removeAll()
    }

    public func isActive(sessionId: UUID) -> Bool { active[sessionId] != nil }

    // MARK: - Internals

    private func forwardPrompt(handle: ProcessHandle, op: String, workingDirectory: String,
                               prompt: String, threadId: String?, model: String?,
                               sandboxMode: String?, modelReasoningEffort: String?) throws {
        var payload: [String: Any] = ["op": op, "workingDirectory": workingDirectory, "prompt": prompt]
        if let threadId { payload["threadId"] = threadId }
        if let model { payload["model"] = model }
        if let sandboxMode { payload["sandboxMode"] = sandboxMode }
        if let modelReasoningEffort { payload["modelReasoningEffort"] = modelReasoningEffort }
        try writeLine(to: handle.stdinPipe, payload)
    }

    private func writeLine(to stdin: Pipe, _ payload: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { throw RelayError.encodeFailed }
        var withNewline = data
        withNewline.append(0x0a)
        try stdin.fileHandleForWriting.write(contentsOf: withNewline)
    }

    private func attachStdoutReader(handle: ProcessHandle, sessionId: UUID) {
        var buffer = Data()
        handle.stdoutPipe.fileHandleForReading.readabilityHandler = { [weak handle] fileHandle in
            guard let handle else { return }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                Task { @MainActor [weak handle] in handle?.subject.send(completion: .finished) }
                fileHandle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0a) {
                let bytes = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !bytes.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                else { continue }
                if let event = Self.classify(json: json, handle: handle) {
                    Task { @MainActor [weak handle] in handle?.subject.send(event) }
                }
            }
        }
    }

    nonisolated private static func classify(json: [String: Any], handle: ProcessHandle) -> CodexRelayEvent? {
        let outerType = json["type"] as? String ?? ""
        var subscriptionId = json["subscriptionId"] as? String
        var threadId = json["threadId"] as? String
        var raw = json
        var innerType = outerType
        if outerType == "stream_event", let event = json["event"] as? [String: Any] {
            raw = event
            innerType = event["type"] as? String ?? ""
            if let tid = event["thread_id"] as? String { threadId = tid }
        }
        if let sid = subscriptionId { handle.lastSubscriptionId = sid }
        if let tid = threadId { handle.lastThreadId = tid }
        subscriptionId = subscriptionId ?? handle.lastSubscriptionId
        threadId = threadId ?? handle.lastThreadId
        let kind: CodexRelayEvent.Kind
        switch innerType {
        case "thread.started": kind = .threadStarted
        case "turn.started": kind = .turnStarted
        case "item.started", "item.updated", "item.completed": kind = .item
        case "turn.completed": kind = .turnCompleted
        case "turn.failed": kind = .turnFailed
        case "error": kind = .error
        case "stream_started": kind = .streamStarted
        case "stream_done": kind = .streamDone
        case "stream_error": kind = .streamError
        case "observer_ready": kind = .observerReady
        default: kind = .unknown
        }
        guard let rawData = try? JSONSerialization.data(withJSONObject: raw),
              let rawStr = String(data: rawData, encoding: .utf8) else { return nil }
        return CodexRelayEvent(kind: kind, subscriptionId: subscriptionId,
                               threadId: threadId, rawJSON: rawStr, receivedAt: Date())
    }

    public enum RelayError: Error, LocalizedError {
        case sdkNotProvisioned, nodeBinaryMissing, sidecarScriptMissing, notSubscribed, encodeFailed
        public var errorDescription: String? {
            switch self {
            case .sdkNotProvisioned: return "Codex SDK not provisioned. Toggle SDK mode in Settings → Codex SDK."
            case .nodeBinaryMissing: return "Node binary not found. Install Node 18+ or run tools/download-bundled-node.sh."
            case .sidecarScriptMissing: return "Codex SDK sidecar script missing — re-toggle SDK mode."
            case .notSubscribed: return "No Codex relay subscription active for this session."
            case .encodeFailed: return "Failed to encode relay command JSON."
            }
        }
    }
}
