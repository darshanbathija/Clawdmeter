import Foundation

/// Parser for the Gemini CLI's per-repo `logs.json` files at
/// `~/.gemini/tmp/<repo-slug>/logs.json`.
///
/// Format (observed on Gemini CLI 0.42.0):
/// ```json
/// [
///   {
///     "sessionId": "<uuid>",
///     "messageId": <int>,
///     "type": "user" | ...,
///     "message": "<string>",
///     "timestamp": "<ISO 8601>"
///   },
///   ...
/// ]
/// ```
///
/// **Analytics schema split** (per plan §Analytics schema split): the
/// cloudcode-pa quota endpoint that backs the Gemini live gauge does not
/// expose per-request token counts. Without tokens, `costUSD` is uncomputable.
/// `GeminiUsageParser` emits `UsageRecord` with `tokens.requestCount = 1`
/// and zero token fields; `AnalyticsTotalsGrid`'s cell renderer surfaces
/// "N reqs" instead of "$X.YZ" for Gemini cells. If Google later publishes
/// per-request token telemetry we plumb it through here and the analytics
/// rows light up with $ values automatically (see TODOS.md v0.7 — per-request
/// token estimation for Gemini cost).
///
/// `nonisolated` static so `UsageHistoryLoader.actor`'s TaskGroup can call
/// this in parallel without re-entering the actor.
public enum GeminiUsageParser {

    /// Parse one `logs.json` file. Returns every user-typed turn as a
    /// `UsageRecord` (skip the synthetic `/quit`, `/model manage`, etc. CLI
    /// commands that start with `/`).
    public static func parse(file url: URL) throws -> [UsageRecord] {
        let data = try Data(contentsOf: url)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        // Resolve the repo key from the parent dir name. Gemini CLI slugs
        // the cwd to a short identifier (`darshanbathija-1`, `defx-v3`,
        // etc.) — RepoIdentity.normalize won't recognize these as git
        // paths, so we surface them under the slug name directly. The
        // analytics By-Repo list shows them as `<slug>` rows.
        let repoSlug = url.deletingLastPathComponent().lastPathComponent

        var out: [UsageRecord] = []
        for entry in array {
            // Only count user-typed prompts. Filter out slash-commands
            // ("/quit", "/model manage", "/clear") since those don't drive
            // model quota consumption.
            guard let type = entry["type"] as? String, type == "user" else { continue }
            guard let message = entry["message"] as? String, !message.isEmpty else { continue }
            if message.hasPrefix("/") { continue }

            let timestamp: Date = {
                if let raw = entry["timestamp"] as? String {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = iso.date(from: raw) { return d }
                    let iso2 = ISO8601DateFormatter()
                    iso2.formatOptions = [.withInternetDateTime]
                    if let d = iso2.date(from: raw) { return d }
                }
                return Date()
            }()

            let model = (entry["model"] as? String) ?? "gemini-3.1-pro"

            // Each user turn is one request from the quota's perspective.
            // tokens.requestCount = 1, all other fields zero. costUSD = 0
            // because Google does not publish per-request token counts —
            // analytics surfaces this via the "N reqs" cell renderer.
            let tokens = TokenTotals(requestCount: 1)

            out.append(UsageRecord(
                provider: .gemini,
                timestamp: timestamp,
                model: model,
                tokens: tokens,
                repo: repoSlug,
                dedupKey: (entry["sessionId"] as? String).map { "\($0):\(entry["messageId"] ?? 0)" }
            ))
        }
        return out
    }
}
