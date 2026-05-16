import SwiftUI
import ClawdmeterShared

/// Third TabView tab on iOS. Mobile defaults to structured-card view per
/// D1; user can toggle to the terminal pane via the segmented control.
struct iOSSessionsView: View {
    @ObservedObject var client: AgentControlClient
    @State private var showingPairing: Bool = false
    @State private var showingNewSession: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if !client.isConfigured {
                    pairingPrompt
                } else if client.repos.isEmpty {
                    emptyState
                } else {
                    repoList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingNewSession = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(!client.isConfigured || client.repos.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Refresh") {
                            Task { await client.refreshAll() }
                        }
                        Button("Pair to Mac…") {
                            showingPairing = true
                        }
                        if client.isConfigured {
                            Button("Unpair", role: .destructive) {
                                client.clearPairing()
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable {
                await client.refreshAll()
            }
            .sheet(isPresented: $showingPairing) {
                PairingFlow(client: client, isPresented: $showingPairing)
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet(client: client, isPresented: $showingNewSession)
            }
            .task {
                await client.refreshAll()
            }
        }
    }

    // MARK: - States

    private var pairingPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(terraCotta)
            Text("Pair to Mac")
                .font(.title2.bold())
            Text("Open Clawdmeter on your Mac, click Settings → Sessions, and scan the QR.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                showingPairing = true
            } label: {
                Label("Scan QR", systemImage: "qrcode")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(terraCotta)
        }
        .padding(28)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "tray")
        } description: {
            Text("Tap ＋ to start one. Repos appear after you run Claude or Codex in them on your Mac.")
        }
    }

    private var repoList: some View {
        List {
            ForEach(client.repos, id: \.key) { repo in
                Section {
                    let sessions = client.sessions.filter { $0.repoKey == repo.key }
                    if sessions.isEmpty {
                        Text("No active sessions")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session, client: client)
                            } label: {
                                SessionRow(session: session)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(repo.displayName)
                        Spacer()
                        if repo.hasActiveSessions {
                            Circle().fill(terraCotta).frame(width: 6, height: 6)
                        }
                    }
                }
            }
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.agent.rawValue.capitalized)
                        .font(.subheadline.weight(.medium))
                    Text(session.status.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let goal = session.goal {
                    Text(goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if session.planText != nil {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
            }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .degraded: return .secondary
        }
    }
}

private struct SessionDetailView: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient
    @State private var viewMode: ViewMode = .structured

    enum ViewMode: String, CaseIterable { case structured = "Structured", terminal = "Terminal" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            switch viewMode {
            case .structured:
                structuredView
            case .terminal:
                terminalView
            }
        }
        .navigationTitle(session.repoDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete session", role: .destructive) {
                        Task { await client.deleteSession(id: session.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var structuredView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let planText = session.planText, !planText.isEmpty {
                    PlanCardView(
                        goal: session.goal,
                        planSummary: planText,
                        files: [],
                        onApprove: {
                            Task { await client.approvePlan(sessionId: session.id) }
                        }
                    )
                }
                StructuredEventList(items: [
                    // Placeholder: the WS event stream feeds this in v1.1.
                ])
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var terminalView: some View {
        if let host = client.host, let token = client.token {
            iOSTerminalView(
                sessionId: session.id,
                host: host,
                wsPort: client.wsPort,
                token: token
            )
        } else {
            ContentUnavailableView("Not paired", systemImage: "wifi.exclamationmark")
        }
    }
}

private struct PairingFlow: View {
    @ObservedObject var client: AgentControlClient
    @Binding var isPresented: Bool

    @State private var mode: PairingMode = .scan
    @State private var pastedURL: String = ""
    @State private var pasteError: String?

    enum PairingMode: String, CaseIterable {
        case scan = "Scan QR"
        case paste = "Paste URL"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(PairingMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(16)

                Divider()

                switch mode {
                case .scan:
                    PairingScannerView { challenge in
                        applyChallenge(challenge)
                    }
                case .paste:
                    pasteForm
                }
            }
            .navigationTitle("Pair to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Clawdmeter on your Mac → Settings → Sessions → Copy pairing URL. Then paste it below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("clawdmeter://host:21731?token=...&ws=21732", text: $pastedURL, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            if let error = pasteError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Button("Pair") {
                guard let challenge = PairingScannerView.parse(urlString: pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    pasteError = "Not a valid clawdmeter:// URL"
                    return
                }
                applyChallenge(challenge)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
            .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .padding(20)
    }

    private func applyChallenge(_ challenge: PairingChallenge) {
        client.setPairing(
            host: challenge.host,
            httpPort: challenge.port,
            wsPort: challenge.wsPort,
            token: challenge.token
        )
        Task { @MainActor in
            await client.refreshAll()
        }
        isPresented = false
    }
}

private struct NewSessionSheet: View {
    @ObservedObject var client: AgentControlClient
    @Binding var isPresented: Bool
    @State private var repoKey: String = ""
    @State private var agent: AgentKind = .claude
    @State private var goal: String = ""
    @State private var planMode: Bool = true
    @State private var useWorktree: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repo", selection: $repoKey) {
                    ForEach(client.repos, id: \.key) { repo in
                        Text(repo.displayName).tag(repo.key)
                    }
                }
                Picker("Agent", selection: $agent) {
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                }
                TextField("Goal (optional)", text: $goal)
                Toggle("Plan mode (Claude only)", isOn: $planMode)
                    .disabled(agent != .claude)
                Toggle("Branch off main (worktree)", isOn: $useWorktree)
            }
            .navigationTitle("New session")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start") {
                        Task {
                            _ = await client.createSession(NewSessionRequest(
                                repoKey: repoKey,
                                agent: agent,
                                model: nil,
                                planMode: agent == .claude && planMode,
                                goal: goal.isEmpty ? nil : goal,
                                useWorktree: useWorktree,
                                baseBranch: nil
                            ))
                            isPresented = false
                        }
                    }
                    .disabled(repoKey.isEmpty)
                }
            }
            .onAppear {
                if repoKey.isEmpty, let first = client.repos.first {
                    repoKey = first.key
                }
            }
        }
    }
}
