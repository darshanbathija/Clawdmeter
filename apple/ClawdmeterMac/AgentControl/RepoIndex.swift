import Foundation
import ClawdmeterShared
import OSLog

private let repoIndexLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RepoIndex")

/// Builds and maintains the repo list shown in the Sessions tab.
///
/// Per E6 (Phase 4 review decision): this is a background refresh actor
/// with 60s automatic refresh + pull-to-refresh + bounded depth on scan
/// roots. Tab activation is INSTANT — reads `latestSnapshot` from cache.
///
/// Sources unioned:
/// 1. Every directory under `~/.claude/projects/` (decoded → cwd → normalized)
/// 2. First-line cwd of every `*.jsonl` under `~/.codex/sessions/`
/// 3. Configured scan roots: `UserDefaults.clawdmeter.sessions.scanRoots`
///    (default EMPTY per Codex eng-round Round 1; user opts in)
///
/// Per Codex Round 1 concern #5: default scan roots are empty. Users add
/// `~/Downloads`, `~/Desktop`, etc. via the Settings UI. Depth bounded to
/// 4 levels so pathological roots don't hang the UI thread.
public actor RepoIndex {

    /// Current cached snapshot. The view layer reads this synchronously.
    public private(set) var latestSnapshot: [AgentRepo] = []

    /// UserDefaults key for configured scan roots.
    public static let scanRootsKey = "clawdmeter.sessions.scanRoots"

    /// Bounded depth for `.git` discovery. Codex review concern #5: deep
    /// roots like `~/` would otherwise traverse thousands of directories.
    public static let maxScanDepth = 4

    /// Track the most-recent refresh task so callers can `await` it.
    private var refreshTask: Task<[AgentRepo], Never>?

    public init() {}

    // MARK: - Public API

    /// Returns the current snapshot. Always cheap (in-memory).
    public func snapshot() -> [AgentRepo] {
        latestSnapshot
    }

    /// Trigger a background refresh. If one is already in flight, returns
    /// the existing task's result (debounces concurrent refresh requests).
    @discardableResult
    public func refresh() async -> [AgentRepo] {
        if let task = refreshTask, !task.isCancelled {
            return await task.value
        }
        let task = Task<[AgentRepo], Never> { @Sendable in
            await self.buildSnapshot()
        }
        refreshTask = task
        let result = await task.value
        // Self-reference is fine here — we're inside the actor.
        latestSnapshot = result
        refreshTask = nil
        return result
    }

    /// Start a periodic refresh loop. Every `interval` seconds, rebuild
    /// the snapshot. Caller is responsible for managing the returned Task
    /// (cancel on shutdown).
    public func startPeriodicRefresh(interval: TimeInterval = 60) -> Task<Void, Never> {
        Task { [weak self] in
            // Initial refresh immediately on launch.
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - Snapshot build

    /// JSONL files modified within this window count as "live" — an agent
    /// is actively writing to them right now (regardless of whether
    /// Clawdmeter spawned the process). 5 minutes catches typical agent
    /// pause-between-turns without flickering off.
    public static let liveActivityWindow: TimeInterval = 5 * 60

    private nonisolated func buildSnapshot() async -> [AgentRepo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var keysSeen = Set<String>()
        var displayNames: [String: String] = [:]
        /// Per repo: how many JSONL files have been touched in the last
        /// `liveActivityWindow`. Non-zero = at least one agent actively
        /// writing.
        var liveCounts: [String: Int] = [:]
        let liveCutoff = Date().addingTimeInterval(-Self.liveActivityWindow)

        // Source 1: ~/.claude/projects/ directory names (encoded cwds)
        let claudeProjects = home.appendingPathComponent(".claude/projects")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for entry in entries where entry.hasDirectoryPath {
                if let cwd = readCwdFromClaudeProject(at: entry) {
                    let key = RepoIdentity.normalize(cwd)
                    if !keysSeen.contains(key) {
                        keysSeen.insert(key)
                        displayNames[key] = RepoIdentity.displayName(for: key)
                    }
                    // Count "live" JSONLs under this project dir.
                    if let jsonls = try? FileManager.default.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: [.contentModificationDateKey]
                    ) {
                        for jsonl in jsonls where jsonl.pathExtension == "jsonl" {
                            if let mtime = try? jsonl.resourceValues(
                                forKeys: [.contentModificationDateKey]
                            ).contentModificationDate, mtime > liveCutoff {
                                liveCounts[key, default: 0] += 1
                            }
                        }
                    }
                }
            }
        }

        // Source 2: ~/.codex/sessions/**/*.jsonl
        let codexSessions = home.appendingPathComponent(".codex/sessions")
        let codexCwds = await readCwdsFromCodexSessions(at: codexSessions)
        for cwd in codexCwds {
            let key = RepoIdentity.normalize(cwd)
            if !keysSeen.contains(key) {
                keysSeen.insert(key)
                displayNames[key] = RepoIdentity.displayName(for: key)
            }
        }

        // Source 3: configured scan roots (default empty)
        let scanRoots = UserDefaults.standard.stringArray(forKey: RepoIndex.scanRootsKey) ?? []
        for rootRaw in scanRoots {
            let root = (rootRaw as NSString).expandingTildeInPath
            for repoPath in findGitRepos(under: root, maxDepth: RepoIndex.maxScanDepth) {
                let key = RepoIdentity.normalize(repoPath)
                if !keysSeen.contains(key) {
                    keysSeen.insert(key)
                    displayNames[key] = RepoIdentity.displayName(for: key)
                }
            }
        }

        // Sort alphabetically by display name, with "Other" last.
        let sortedKeys = keysSeen.sorted { a, b in
            let da = displayNames[a] ?? a
            let db = displayNames[b] ?? b
            if a == RepoKey.other { return false }
            if b == RepoKey.other { return true }
            return da.localizedCaseInsensitiveCompare(db) == .orderedAscending
        }

        let repos = sortedKeys.map { key in
            AgentRepo(
                key: key,
                displayName: displayNames[key] ?? key,
                hasActiveSessions: false,  // Phase 2 fills this in from registry
                liveSessionCount: liveCounts[key, default: 0]
            )
        }
        let liveTotal = liveCounts.values.reduce(0, +)
        repoIndexLogger.info("Snapshot built: \(repos.count) repos, \(liveTotal) live sessions across all repos")
        return repos
    }

    /// Read the cwd from the first JSONL entry under a Claude project dir.
    /// Falls back to decoding the directory name itself if no cwd is found
    /// (Claude encodes the cwd in the dir name with `/` and ` ` replaced by `-`).
    private nonisolated func readCwdFromClaudeProject(at dir: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        for entry in entries where entry.pathExtension == "jsonl" {
            if let cwd = readFirstCwd(from: entry) {
                return cwd
            }
        }
        // Fallback: decode the dir name. Claude's encoding replaces `/` AND
        // ` ` with `-`. Reversal is lossy (we can't tell underscores or real
        // hyphens apart from path-separator hyphens), but for cases where
        // the JSONL parse fails we'd rather show *something* than nothing.
        return Self.decodeClaudeDirName(dir.lastPathComponent)
    }

    /// Best-effort: turn `-Users-darshanbathija-1-Downloads-CC-Watch` into
    /// `/Users/darshanbathija_1/Downloads/CC Watch` by probing the filesystem.
    /// If a guess doesn't exist on disk we keep going; the first guess that
    /// matches a real directory wins. Falls back to the naive `-` → `/`
    /// substitution when nothing matches.
    static func decodeClaudeDirName(_ name: String) -> String? {
        // Strip leading `-` (it represents the leading `/`).
        guard name.hasPrefix("-") else { return nil }
        let trimmed = String(name.dropFirst())
        let segments = trimmed.split(separator: "-").map(String.init)
        guard !segments.isEmpty else { return nil }

        let fm = FileManager.default
        // Walk segments greedily: at each step, try the longest run that
        // matches an actual filesystem entry. If `Users-darshanbathija-1`
        // exists as `darshanbathija_1`, accept it.
        var currentPath = "/" + segments[0]
        var i = 1
        while i < segments.count {
            var matched = false
            // Try combining 1..5 remaining segments (handles `CC Watch`
            // which is 2 segments, and `darshanbathija_1` 2 segments).
            for combineCount in stride(from: 5, through: 1, by: -1) {
                let endIdx = min(i + combineCount, segments.count)
                let raw = segments[i..<endIdx].joined(separator: "-")
                // Try the literal version first, then with `-` → `_`, then ` ` → `-`.
                let candidates = [
                    raw,
                    raw.replacingOccurrences(of: "-", with: "_"),
                    raw.replacingOccurrences(of: "-", with: " "),
                ]
                for candidate in candidates {
                    let trial = (currentPath as NSString).appendingPathComponent(candidate)
                    if fm.fileExists(atPath: trial) {
                        currentPath = trial
                        i = endIdx
                        matched = true
                        break
                    }
                }
                if matched { break }
            }
            if !matched {
                // Nothing on disk matches — fall back to joining all remaining
                // with `-`. The repo display name will still look right.
                let rest = segments[i...].joined(separator: "-")
                currentPath = (currentPath as NSString).appendingPathComponent(rest)
                break
            }
        }
        return currentPath
    }

    /// Walk a tmux/codex sessions directory recursively for `*.jsonl` and
    /// extract the cwd from the first line of each.
    private nonisolated func readCwdsFromCodexSessions(at root: URL) async -> [String] {
        var found: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        // Bound the walk so a corrupted ~/.codex/ doesn't hang us.
        var inspected = 0
        for case let entry as URL in enumerator {
            inspected += 1
            if inspected > 5000 { break }
            guard entry.pathExtension == "jsonl" else { continue }
            if let cwd = readFirstCwd(from: entry) {
                found.insert(cwd)
            }
        }
        return Array(found)
    }

    /// Scan the first ~64KB of a JSONL file looking for the first line with
    /// a `cwd` field. Claude wraps the actual user/assistant events in a
    /// `queue-operation` preamble that doesn't have `cwd` — we have to read
    /// past it. Codex's first line typically does have cwd.
    private nonisolated func readFirstCwd(from url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // Read up to 256KB — single lines can be ~10KB (queue-operation with
        // a big content blob), so we need enough for a handful of lines.
        guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty else { return nil }
        var lineStart = chunk.startIndex
        while lineStart < chunk.endIndex {
            let newlineIdx = chunk[lineStart...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let lineBytes = chunk[lineStart..<newlineIdx]
            lineStart = (newlineIdx < chunk.endIndex)
                ? chunk.index(after: newlineIdx)
                : chunk.endIndex
            guard !lineBytes.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any]
            else { continue }
            if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    /// BFS under `root` for `.git` directories or files (worktree markers).
    /// Bounded by `maxDepth` so pathological roots like `~/` can't hang.
    private nonisolated func findGitRepos(under root: String, maxDepth: Int) -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty {
            let (path, depth) = queue.removeFirst()
            visited += 1
            // Hard cap on directories visited to bound worst case.
            if visited > 10_000 { break }
            // Does this dir contain a `.git`?
            let gitPath = (path as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                result.append(path)
                continue  // don't recurse into a repo (no nested repos in scope)
            }
            if depth >= maxDepth { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries {
                if entry.hasPrefix(".") { continue }  // skip hidden
                let child = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    queue.append((child, depth + 1))
                }
            }
        }
        return result
    }
}
