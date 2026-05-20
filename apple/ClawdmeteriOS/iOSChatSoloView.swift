import SwiftUI
import ClawdmeterShared

/// Solo chat surface — one chat session, full-height thread + composer.
/// Reuses `iOSChatStore` for the chat-subscribe WS subscription (SDK
/// chat populates the store via `CodexSDKEventIngestor.appendSDKMessages`
/// on the Mac side, so the wire shape is identical to CLI chat).
///
/// v0.8 minimum-viable: plain thread + composer. ModelPicker mid-conv
/// swap (D7) is wired via the existing iOSComposerBar `.live` mode chips.
/// Plan-mode is enforced server-side for chat sessions (Phase 3), so the
/// composer's PermissionMode chip — which v0.7.18 added — is not exposed
/// here for chat (REV-Composer-mode: force `.plan`, hide picker).
@available(iOS 16, *)
struct iOSChatSoloView: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    @StateObject private var store: iOSChatStore

    init(session: AgentSession, client: AgentControlClient) {
        self.session = session
        self.client = client
        _store = StateObject(wrappedValue: iOSChatStore(sessionId: session.id, client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            thread
            Divider()
            iOSComposerBar(mode: .live(session: session), client: client)
        }
        .navigationTitle(session.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive, action: {
                        Task { await client.deleteSession(id: session.id) }
                    }) {
                        Label("End chat", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    @ViewBuilder
    private var thread: some View {
        if store.snapshot.items.isEmpty {
            ContentUnavailableView {
                Label("Say something", systemImage: "bubble.left")
            } description: {
                emptyStateDescription
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.snapshot.items) { item in
                            messageRow(item)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.snapshot.updateCounter) { _, _ in
                    if let last = store.snapshot.items.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateDescription: Text {
        if session.agent == .codex, session.codexChatBackend == .sdk {
            return Text("Codex SDK chat — your first message starts a server-side thread that survives across devices.")
        }
        switch session.agent {
        case .claude: return Text("Claude is running in plan-mode. Reads + proposes, no writes.")
        case .codex:  return Text("Codex is running in --sandbox read-only. Reads + proposes, no writes.")
        case .gemini: return Text("Gemini chat is coming in v0.9.")
        }
    }

    @ViewBuilder
    private func messageRow(_ item: ChatItem) -> some View {
        switch item {
        case .message(let m):
            chatMessageRow(m)
        case .toolRun(_, let pairs):
            toolRunRow(pairs)
        }
    }

    @ViewBuilder
    private func chatMessageRow(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .userText:
            HStack {
                Spacer(minLength: 36)
                Text(m.body)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistantText:
            HStack(alignment: .top, spacing: 8) {
                providerInitial
                Text(m.body)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        case .toolCall, .toolResult:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if !m.title.isEmpty {
                        Text(m.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(m.body)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        case .meta:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(m.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func toolRunRow(_ pairs: [ToolPair]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var providerInitial: some View {
        let letter: String = {
            switch session.agent {
            case .claude: return "C"
            case .codex:  return "X"
            case .gemini: return "G"
            }
        }()
        return Text(letter)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 20, height: 20)
            .background(Color.secondary.opacity(0.2), in: Circle())
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}
