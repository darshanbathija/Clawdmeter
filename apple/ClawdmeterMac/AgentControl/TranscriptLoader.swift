import Foundation
import ClawdmeterShared

/// One-shot reader that turns a JSONL on disk into a chronological list of
/// `ChatMessage` values for the `/transcript` HTTP endpoint to ship to
/// iOS. Re-uses `ParsedLine.from(json:)` (the same path
/// `SessionChatStore.StagingParser` uses live) so the iOS chat view
/// renders identically to the Mac one — same kinds, same titles, same
/// tool_use/tool_result pairing.
///
/// We tail-read by default: the last `maxMessages` entries chronologically.
/// Cap is enforced AFTER sorting because lines can arrive out of order in
/// long sessions (cache-replay events with old timestamps). 500 messages
/// is enough to cover most chat scrollback while keeping the response
/// under ~500 KB even for token-heavy assistant turns.
enum TranscriptLoader {

    static func load(from url: URL, maxMessages: Int) -> [ChatMessage] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return [] }

        var collected: [ChatMessage] = []
        var seenIds = Set<String>()

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let nl = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let lineBytes = data[lineStart..<nl]
            lineStart = (nl < data.endIndex) ? data.index(after: nl) : data.endIndex
            guard !lineBytes.isEmpty else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: lineBytes))
                  as? [String: Any] else { continue }
            guard let parsed = ParsedLine.from(json: json) else { continue }
            for msg in parsed.messages {
                if seenIds.contains(msg.id) { continue }
                seenIds.insert(msg.id)
                collected.append(msg)
            }
        }

        // Sort by (at, kindRank, id) — matches StagingParser's invariant
        // so tool_use lines always sort before their matching tool_result.
        collected.sort { ChatMessageOrdering.precedes($0, $1) }

        // Tail-cap to keep the response small. The iPhone wants the most
        // recent N messages, not the first N.
        if collected.count > maxMessages {
            collected = Array(collected.suffix(maxMessages))
        }
        return collected
    }
}
