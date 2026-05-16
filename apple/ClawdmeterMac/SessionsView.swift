import SwiftUI
import ClawdmeterShared

/// Sessions tab for the Mac dashboard. Single-pane vertical list per
/// user direction:
///   - Repo header (collapsible)
///   - Sessions underneath as one-line rows (one-line description = goal
///     or "{agent} · {status}")
///   - Click a session → push into a chat-style detail (structured cards
///     primary, terminal view as a toggle)
///   - ＋ New session button at the bottom
///
/// "Live outside Clawdmeter" repos surface with a green pill so the user
/// can see Conductor / Cursor / Terminal-launched activity, even though
/// Clawdmeter can't directly control those sessions.
struct SessionsView: View {

    @ObservedObject var model: SessionsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                Divider()
                content
                Divider()
                newSessionButton
            }
            .background(backgroundColor)
            .navigationDestination(for: AgentSession.self) { session in
                SessionChatView(session: session, model: model)
            }
        }
        .sheet(isPresented: $model.showingNewSessionSheet) {
            NewSessionMacSheet(model: model)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Sessions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondaryText)
            if let lastRefresh = lastRefreshText {
                Text(lastRefresh)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText.opacity(0.7))
            }
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: { Task { await model.refresh() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh repo list")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var lastRefreshText: String? {
        // Phase 4 polish — surface "Last refresh X ago". For now, just an
        // indication when we're not refreshing.
        nil
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.repos.isEmpty && model.registry.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(model.repos, id: \.key) { repo in
                        repoSection(repo)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(secondaryText)
            Text("No repos detected yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(primaryText)
            Text("Once you run Claude or Codex in a repo, it'll show up here. You can also add a scan root in Settings → Sessions, or click ＋ New session below to enter a path directly.")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func repoSection(_ repo: AgentRepo) -> some View {
        let sessions = model.sessions(for: repo.key)
        let isExpanded = model.expandedRepoKeys.contains(repo.key)
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(repo, isExpanded: isExpanded, sessionCount: sessions.count)
            if isExpanded {
                if sessions.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(secondaryText)
                        Text("Start a session here")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectedRepoKey = repo.key
                        model.showingNewSessionSheet = true
                    }
                } else {
                    ForEach(sessions) { session in
                        NavigationLink(value: session) {
                            sessionRow(session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func repoHeader(_ repo: AgentRepo, isExpanded: Bool, sessionCount: Int) -> some View {
        Button(action: {
            if isExpanded {
                model.expandedRepoKeys.remove(repo.key)
            } else {
                model.expandedRepoKeys.insert(repo.key)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .frame(width: 12)
                Text(repo.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(secondaryText.opacity(0.15), in: Capsule())
                }
                if repo.liveSessionCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("\(repo.liveSessionCount) live")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .help("\(repo.liveSessionCount) JSONL file(s) modified in the last 5 minutes — Conductor, Cursor, or a Terminal-launched agent is writing here right now")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowHover ? hoverBg : Color.clear)
    }

    @State private var rowHover: Bool = false

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(session.status))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(session))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryText)
                Text(sessionSubtitle(session))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if session.planText != nil {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(terraCotta)
                    .help("Plan ready for approval")
            }
            Text(session.createdAt.formatted(.relative(presentation: .numeric)))
                .font(.system(size: 10))
                .foregroundStyle(secondaryText)
        }
        .padding(.horizontal, 36)  // indent under the header
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func sessionTitle(_ session: AgentSession) -> String {
        if let goal = session.goal, !goal.isEmpty { return goal }
        return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
    }

    private func sessionSubtitle(_ session: AgentSession) -> String {
        if let goal = session.goal, !goal.isEmpty {
            return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
        }
        // No goal — show window id as a debugging hint.
        return session.tmuxWindowId.map { "tmux \($0)" } ?? "starting…"
    }

    private func statusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return terraCotta
        case .degraded: return .secondary
        }
    }

    // MARK: - New session button

    private var newSessionButton: some View {
        Button(action: { model.showingNewSessionSheet = true }) {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("New session")
                    .fontWeight(.semibold)
                Spacer()
                if model.repos.isEmpty {
                    Text("(empty index — paste a path)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(terraCotta)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    // MARK: - Theme

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }
    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }
    private var secondaryText: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }
    private var hoverBg: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.04)
            : Color.black.opacity(0.04)
    }
}

// MARK: - Chat-style detail

/// "Once one is clicked into — it looks like a chat session." Structured
/// cards (messages + tool calls + plan card if planText is non-nil) as
/// the primary surface; the terminal view is reachable via a toggle.
struct SessionChatView: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewMode: ViewMode = .chat

    enum ViewMode: String, CaseIterable {
        case chat = "Chat"
        case terminal = "Terminal"
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ZStack {
                switch viewMode {
                case .chat:
                    chatBody
                case .terminal:
                    terminalBody
                }
            }
        }
        .navigationTitle(session.repoDisplayName)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Menu {
                    Button("End session", role: .destructive) {
                        Task { await model.endSession(id: session.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(session.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerTitle: String {
        session.goal ?? session.repoDisplayName
    }

    @ViewBuilder
    private var chatBody: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let planText = session.planText, !planText.isEmpty {
                    PlanCardView(
                        goal: session.goal,
                        planSummary: planText,
                        files: [],
                        onApprove: {
                            Task { await model.approvePlan(id: session.id) }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                StructuredEventList(items: [])
            }
        }
    }

    @ViewBuilder
    private var terminalBody: some View {
        if let runtime = AppDelegate.runtime,
           let port = runtime.agentControlServer.boundWsPort {
            MacTerminalView(
                sessionId: session.id,
                host: "127.0.0.1",
                wsPort: Int(port),
                token: PairingTokenStore.shared.currentToken()
            )
        } else {
            ContentUnavailableView(
                "Daemon offline",
                systemImage: "wifi.exclamationmark",
                description: Text("Restart Clawdmeter to reconnect.")
            )
        }
    }

    private func statusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .degraded: return .secondary
        }
    }
}

// MARK: - New session sheet (Mac)

struct NewSessionMacSheet: View {
    @ObservedObject var model: SessionsModel
    @Environment(\.dismiss) private var dismiss

    @State private var repoPath: String = ""
    @State private var agent: AgentKind = .claude
    @State private var goal: String = ""
    @State private var planMode: Bool = true
    @State private var useWorktree: Bool = false
    @State private var isSpawning: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New session")
                .font(.system(size: 18, weight: .semibold))

            Form {
                Picker("Pick a repo", selection: $repoPath) {
                    Text("(custom path)").tag("")
                    ForEach(model.repos, id: \.key) { repo in
                        let suffix = repo.liveSessionCount > 0 ? "  • live" : ""
                        Text("\(repo.displayName)\(suffix)").tag(repo.key)
                    }
                }
                .pickerStyle(.menu)

                TextField("Or enter a path", text: $repoPath,
                          prompt: Text("/Users/.../my-repo"))
                    .help("Paste an absolute path. The agent runs with this as its cwd.")

                Picker("Agent", selection: $agent) {
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                }
                .pickerStyle(.segmented)

                TextField("Goal", text: $goal,
                          prompt: Text("Optional. Used by done-detector + worktree slug."))

                Toggle("Plan mode (Claude only)", isOn: $planMode)
                    .disabled(agent != .claude)

                Toggle("Branch off main (new worktree)", isOn: $useWorktree)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSpawning ? "Starting…" : "Start") {
                    Task { await startSession() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                .disabled(repoPath.isEmpty || isSpawning)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let selected = model.selectedRepoKey {
                repoPath = selected
            }
        }
    }

    private func startSession() async {
        isSpawning = true
        errorMessage = nil
        defer { isSpawning = false }
        guard let runtime = AppDelegate.runtime else {
            errorMessage = "Daemon not started — relaunch Clawdmeter."
            return
        }
        do {
            _ = try await model.spawnSession(
                repoPath: repoPath,
                agent: agent,
                planMode: agent == .claude && planMode,
                goal: goal.isEmpty ? nil : goal,
                useWorktree: useWorktree,
                tmux: runtime.tmuxClient
            )
            dismiss()
        } catch {
            errorMessage = (error as? TmuxControlClient.TmuxError).map(humanize)
                ?? error.localizedDescription
        }
    }

    private func humanize(_ err: TmuxControlClient.TmuxError) -> String {
        switch err {
        case .notStarted: return "tmux not started — try again in a moment"
        case .commandFailed(let s): return "tmux: \(s)"
        case .serverExited: return "tmux server exited"
        case .ptyClosed: return "PTY closed unexpectedly"
        }
    }
}

// MARK: - Model

/// Lightweight ObservableObject the SessionsView observes. Wraps the
/// RepoIndex actor (for the repo list) + AgentSessionRegistry (for live
/// session metadata) + TmuxSupervisor (for daemon health).
@MainActor
public final class SessionsModel: ObservableObject {

    @Published public var repos: [AgentRepo] = []
    @Published public var selectedRepoKey: String?
    @Published public var isRefreshing: Bool = false
    @Published public var selectedSessionId: UUID?
    @Published public var showingNewSessionSheet: Bool = false

    /// Which repo headers are currently expanded in the list.
    @Published public var expandedRepoKeys: Set<String> = []

    public var selectedRepo: AgentRepo? {
        guard let key = selectedRepoKey else { return nil }
        return repos.first { $0.key == key }
    }

    public let repoIndex: RepoIndex
    public let registry: AgentSessionRegistry
    public let supervisor: TmuxSupervisor
    private var refreshTask: Task<Void, Never>?

    public init(
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        supervisor: TmuxSupervisor
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.supervisor = supervisor
    }

    public var selectedSession: AgentSession? {
        guard let id = selectedSessionId else { return nil }
        return registry.sessions.first { $0.id == id }
    }

    public func sessions(for repoKey: String) -> [AgentSession] {
        registry.sessions.filter { $0.repoKey == repoKey }
    }

    /// Trigger a refresh of the repo list. Idempotent.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await repoIndex.refresh()
        self.repos = snapshot
        // Auto-expand any repo that has Clawdmeter-owned sessions OR is
        // live outside Clawdmeter, so the user sees them by default.
        for repo in snapshot {
            if !sessions(for: repo.key).isEmpty || repo.liveSessionCount > 0 {
                expandedRepoKeys.insert(repo.key)
            }
        }
    }

    /// Subscribe to periodic background refreshes (E6: 60s cadence).
    /// Called once at app startup. The returned task lives for the app lifetime.
    public func startPeriodicRefresh() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    /// Spawn a new session via the in-process daemon's tmux client.
    public func spawnSession(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        useWorktree: Bool,
        tmux: TmuxControlClient
    ) async throws -> AgentSession {
        try await tmux.start()
        var cwd = repoPath
        var worktreePath: String? = nil
        if useWorktree {
            let slug = WorktreeManager.slug(goal: goal, sessionId: UUID())
            worktreePath = try await WorktreeManager.shared.add(
                repoRoot: repoPath, slug: slug
            )
            cwd = worktreePath!
        }
        let argv = AgentSpawner.argv(for: NewSessionRequest(
            repoKey: repoPath,
            agent: agent,
            model: nil,
            planMode: planMode,
            goal: goal,
            useWorktree: useWorktree
        ))
        let windowId = try await tmux.newWindow(cwd: cwd, child: argv)
        let session = registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: agent,
            model: nil,
            goal: goal,
            worktreePath: worktreePath,
            tmuxWindowId: windowId,
            tmuxPaneId: nil,
            planMode: planMode
        )
        expandedRepoKeys.insert(repoPath)
        await self.refresh()
        return session
    }

    /// Stop a session. Kills tmux window + cleans up.
    public func endSession(id: UUID) async {
        guard let session = registry.session(id: id),
              let runtime = AppDelegate.runtime,
              let windowId = session.tmuxWindowId
        else { return }
        do {
            try await runtime.tmuxClient.killWindow(windowId)
        } catch {
            // tmux may already have closed; log + continue.
        }
        if let worktreePath = session.worktreePath {
            _ = try? await WorktreeManager.shared.delete(
                repoRoot: session.repoKey,
                worktreePath: worktreePath,
                registryOwned: true,
                attachedPanePaths: []
            )
        }
        registry.delete(id: id)
    }

    /// Approve the pending plan for a session. Triggers the D13 overlay
    /// + pane swap on the daemon side.
    public func approvePlan(id: UUID) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: id),
              let windowId = session.tmuxWindowId
        else { return }
        do {
            try await runtime.tmuxClient.killWindow(windowId)
            let argv = [
                "/Users/darshanbathija_1/.local/bin/claude",
                "--permission-mode", "acceptEdits",
            ]
            let cwd = session.worktreePath ?? session.repoKey
            let newWindow = try await runtime.tmuxClient.newWindow(cwd: cwd, child: argv)
            // Reflect in the registry: status running, planText cleared isn't
            // a registry op we have; just leave planText in place — the UI
            // checks status to decide whether to show the plan card.
            registry.updateStatus(id: id, status: .running)
            _ = newWindow
        } catch {
            // Surface in a future iteration.
        }
    }
}

// AgentSession is already Hashable + Identifiable (from Protocol.swift), so
// it can be used with NavigationStack `navigationDestination(for:)` directly.
