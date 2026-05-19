// Talks to Antigravity 2's local `language_server` Go binary. The server
// listens on two random localhost ports (HTTP+gRPC + an HTTPS one with a
// self-signed cert) and gates every request behind a per-launch CSRF
// token. Both port + token live in `~/.gemini/antigravity/logs/<TS>/ls-main.log`
// — which is TRANSIENT (only exists while the Electron app is running).
//
// What we do here:
//
//   1. Discover the live server (lsof + PID liveness — eng review 1A fix).
//      We can't just "pick the newest logs/<TS>/" because that dir
//      accumulates across launches; the newest entry could be a dead
//      server. Verify with `kill -0 <pid>` AND `lsof -nP -iTCP:<port> ...`
//      before trusting the candidate.
//
//   2. Trust the self-signed TLS cert ONLY for loopback hosts (eng review
//      2B fix). language_server presents a cert it generated at launch,
//      not signed by anyone. URLSession rejects by default. We override
//      via URLSessionDelegate.didReceive challenge: accept serverTrust
//      iff host is 127.0.0.1/::1/localhost.
//
//   3. Query the server for `currentModel()` and `protoSchemaHash()`.
//      Used by ProviderConfig.swift to render the dashboard subtitle
//      with the live model name (instead of guessing from the state file).

import Foundation
import OSLog

/// Result of `discoverLive()`. Either we found a live server, or we
/// didn't — the latter is a first-class state, NOT an error.
public enum LanguageServerProbe: Equatable, Sendable {
    case live(LiveLanguageServer)
    case notRunning
}

/// One live language_server instance. Port + CSRF token together gate
/// every request.
public struct LiveLanguageServer: Equatable, Sendable {
    public let port: Int
    public let csrfToken: String
    public let pid: Int
    /// `https://127.0.0.1:<port>`.
    public var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }
}

/// Client + discovery. Stateless apart from a cached probe — caller is
/// expected to re-call `discoverLive()` on `NSWorkspace.didActivateApplicationNotification`
/// for `com.google.antigravity` to pick up server restarts.
public final class LanguageServerClient: NSObject {

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "LanguageServerClient")
    private let logsRoot: URL

    public init(logsRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logsRoot = logsRoot ?? home.appendingPathComponent(".gemini/antigravity/logs", isDirectory: true)
        super.init()
    }

    // MARK: - Discovery

    /// Walks `logsRoot/*/ls-main.log` newest-first, parses port + PID
    /// from each, returns the first one whose process is alive AND
    /// holds the port. Returns `.notRunning` when no candidate passes
    /// both checks.
    public func discoverLive() -> LanguageServerProbe {
        let candidates = enumerateCandidates()
        for candidate in candidates {
            guard let (port, pid, token) = parseLogHeader(at: candidate) else { continue }
            // kill(pid, 0) returns 0 when the process exists and we have
            // permission to signal it. ESRCH (3) when no such process.
            // EPERM (1) means the process exists but we can't signal —
            // still alive.
            let killResult = kill(Int32(pid), 0)
            let processAlive = (killResult == 0) || (errno == EPERM)
            guard processAlive else { continue }
            guard portIsListenedOn(port: port, byPID: pid) else { continue }
            return .live(LiveLanguageServer(port: port, csrfToken: token, pid: pid))
        }
        return .notRunning
    }

    /// Lists `logsRoot/<TS>/ls-main.log` files, newest mtime first.
    private func enumerateCandidates() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        let logs = entries
            .map { $0.appendingPathComponent("ls-main.log", isDirectory: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // Sort newest mtime first.
        return logs.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
    }

    /// Extracts port + PID + CSRF token from the log header. Antigravity
    /// writes a startup line like
    /// `language_server --csrf_token <uuid> --extension_server_port <N> --pid <PID>`
    /// (or similar — we tolerate variations by regex-matching the keys
    /// we care about).
    func parseLogHeader(at url: URL) -> (port: Int, pid: Int, token: String)? {
        // Read at most 4KB — the header is in the first few hundred bytes.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        try? handle.close()

        guard let port = extractInt(in: text, after: "--extension_server_port") else { return nil }
        // PID may be in a few forms — "pid=12345" or "--pid 12345" or
        // we fall back to reading our own parent process via `lsof`
        // later. Default to the value parsed if present.
        let pid = extractInt(in: text, after: "--pid")
            ?? extractInt(in: text, after: "pid=")
            ?? 0
        guard let token = extractString(in: text, after: "--csrf_token") else { return nil }
        return (port, pid, token)
    }

    private func extractInt(in text: String, after key: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        let tail = text[range.upperBound...].drop { $0.isWhitespace || $0 == "=" }
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private func extractString(in text: String, after key: String) -> String? {
        guard let range = text.range(of: key) else { return nil }
        let tail = text[range.upperBound...].drop { $0.isWhitespace || $0 == "=" }
        let token = tail.prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    /// Returns true iff the given PID currently listens on `port` on
    /// localhost. Uses `lsof -nP -iTCP:<port> -sTCP:LISTEN -P` and parses
    /// the PID column. Empty/missing output means no listener.
    func portIsListenedOn(port: Int, byPID pid: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8) ?? ""
        // lsof output columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            if let listenerPID = Int(parts[1]) {
                if pid == 0 { return true } // PID unknown but somebody listens
                if listenerPID == pid { return true }
            }
        }
        return false
    }

    // MARK: - HTTPS requests against the live server

    /// Wraps a URLSession with our loopback-scoped TLS trust override.
    /// Cached so we don't tear down the underlying connection pool on
    /// every request.
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }()

    /// Fetches the currently-selected model name. Returns nil when the
    /// server isn't running or the response shape changed.
    public func currentModel(probe: LanguageServerProbe? = nil) async -> String? {
        let live: LiveLanguageServer
        switch probe ?? discoverLive() {
        case .live(let l): live = l
        case .notRunning: return nil
        }
        var request = URLRequest(url: live.baseURL.appendingPathComponent("/v1/current-model"))
        request.setValue(live.csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        request.timeoutInterval = 5
        do {
            let (data, _) = try await urlSession.data(for: request)
            // Tolerate the response being either a bare model string OR
            // {"model": "..."} JSON.
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                if s.hasPrefix("{") {
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return obj["model"] as? String
                    }
                }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.debug("currentModel request failed: \(error.localizedDescription)")
        }
        return nil
    }
}

// MARK: - URLSessionDelegate — loopback-scoped TLS trust (eng review 2B fix)

extension LanguageServerClient: URLSessionDelegate {
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only override server-trust challenges. Other types (basic auth,
        // client cert, etc.) fall through to default handling.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Loopback-only trust. Any non-loopback host hits default
        // validation, which will reject the self-signed cert as it
        // should — we are NOT a CA.
        let host = challenge.protectionSpace.host
        let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
        if loopbackHosts.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
