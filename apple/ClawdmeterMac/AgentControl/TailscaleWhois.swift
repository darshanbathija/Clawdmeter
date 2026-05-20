import Foundation
import OSLog

private let whoisLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TailscaleWhois")

/// Tailscale identity gating for non-loopback peers.
///
/// Shells out to `/opt/homebrew/bin/tailscale whois --json <peer-ip:port>`
/// (E4 path fix from Codex eng-round Round 1 — original plan had
/// `/usr/local/bin/tailscale` which is wrong on Apple Silicon Homebrew).
///
/// Per Codex eng-round Medium: whois failure or unknown peer = DENY
/// (fail closed), not unknown-allow. The accept-handler that calls this
/// rejects any connection where `userLoginName(for:)` returns nil.
///
/// Per E6: results are cached by IP for 60s — tailscale CLI startup is
/// ~50ms; uncached every-request would compound on busy iPhone polling.
public actor TailscaleWhois {

    public static let shared = TailscaleWhois()

    private struct CacheEntry {
        let loginName: String?  // nil = whois failed (deny)
        let cachedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 60

    /// Cached tailscale binary path (resolved at first use; we don't
    /// re-probe per call).
    private var tailscaleBinary: String?

    public init() {}

    /// Returns the Tailscale login (e.g. `"darshan.bathija@gmail.com"`) for
    /// a peer's IP, or `nil` if the peer is unknown / whois failed.
    ///
    /// - Parameter peerAddress: the connection's remote endpoint string
    ///   (`"100.91.212.32:53412"` or just `"100.91.212.32"`).
    public func userLoginName(for peerAddress: String) async -> String? {
        // Strip port if present — whois only takes an IP. Preserve raw IPv6
        // literals, whose colons are part of the address.
        let ip = Self.ipOnly(peerAddress)

        if let cached = cache[ip], Date().timeIntervalSince(cached.cachedAt) < cacheTTL {
            return cached.loginName
        }

        let login = await performWhois(ip: ip)
        cache[ip] = CacheEntry(loginName: login, cachedAt: Date())
        return login
    }

    /// Strip the port from an NWEndpoint string and return just the IP.
    /// Handles three shapes:
    /// - bracketed IPv6:  `[fd7a::1]:443`  → `fd7a::1`
    /// - IPv4 + port:     `100.64.0.1:443` → `100.64.0.1`
    /// - bare host:       `fd7a::1`        → `fd7a::1`
    ///
    /// P2-Mac-4: previously, an unbracketed IPv6 endpoint with a port
    /// (e.g., `fd7a::1:443` — emitted by some NWEndpoint string
    /// formatters) fell through both branches and returned the raw
    /// string with the trailing `:443` still attached. `tailscale whois`
    /// then 404'd. Detect the colon-rich IPv6 shape explicitly: if the
    /// string contains 3+ colons it's IPv6, and the final colon is the
    /// port boundary IFF the segment after it parses as a port.
    static func ipOnly(_ peerAddress: String) -> String {
        if peerAddress.hasPrefix("["),
           let end = peerAddress.firstIndex(of: "]") {
            return String(peerAddress[peerAddress.index(after: peerAddress.startIndex)..<end])
        }
        let colonCount = peerAddress.filter { $0 == ":" }.count
        if colonCount == 1 {
            return peerAddress.split(separator: ":").first.map(String.init) ?? peerAddress
        }
        // 3+ colons → IPv6. The trailing `:NNNN` (numeric, ≤ 5 digits) is a
        // port. Anything else is part of the address.
        if colonCount >= 3,
           let lastColon = peerAddress.lastIndex(of: ":") {
            let tail = peerAddress[peerAddress.index(after: lastColon)...]
            if !tail.isEmpty, tail.count <= 5, tail.allSatisfy({ $0.isNumber }) {
                return String(peerAddress[..<lastColon])
            }
        }
        return peerAddress
    }

    /// Force-invalidate the cache. Useful when the daemon detects a network
    /// change (sleep/wake, Tailscale restart).
    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Whois shell-out

    private func performWhois(ip: String) async -> String? {
        if tailscaleBinary == nil {
            tailscaleBinary = ShellRunner.locateBinary("tailscale")
        }
        guard let binary = tailscaleBinary else {
            whoisLogger.error("tailscale binary not found on PATH; whois fails closed (DENY)")
            return nil
        }

        do {
            let result = try await ShellRunner.shared.run(
                executable: binary,
                arguments: ["whois", "--json", ip],
                timeout: 5
            )
            guard result.exitStatus == 0 else {
                whoisLogger.debug("whois \(ip, privacy: .public) exit=\(result.exitStatus): \(result.stderrString, privacy: .public)")
                return nil
            }
            return Self.parseLoginName(from: result.stdout)
        } catch {
            whoisLogger.warning("whois \(ip, privacy: .public) shell failed: \(error.localizedDescription, privacy: .public); fail closed")
            return nil
        }
    }

    /// Parse `tailscale whois --json` output for the user's login name.
    /// Format (as of Tailscale 1.98.x):
    /// ```
    /// {
    ///   "Node": { "Name": "darshans-macbook-pro.tail87a721.ts.net.", ... },
    ///   "UserProfile": {
    ///     "ID": 300036349076449,
    ///     "LoginName": "darshan.bathija@gmail.com",
    ///     "DisplayName": "Darshan Bathija",
    ///     ...
    ///   }
    /// }
    /// ```
    static func parseLoginName(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let userProfile = json["UserProfile"] as? [String: Any] else {
            return nil
        }
        return userProfile["LoginName"] as? String
    }
}
