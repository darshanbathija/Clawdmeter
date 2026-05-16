import SwiftUI
import ClawdmeterShared

/// watchOS sessions list — Crown-scrollable, taps into session detail.
/// Reads `WatchPlanBridge.sessionsSummary` (populated from iPhone via
/// WCSession). Sessions v2 Phase 6.
struct SessionsListView: View {
    @ObservedObject var bridge: WatchPlanBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if bridge.sessionsSummary.isEmpty {
                    Text("No active sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else {
                    ForEach(bridge.sessionsSummary) { summary in
                        NavigationLink(value: summary) {
                            sessionRow(summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: WatchSessionSummary.self) { summary in
            WatchSessionDetailView(summary: summary, bridge: bridge)
        }
    }

    @ViewBuilder
    private func sessionRow(_ summary: WatchSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                statusDot(summary)
                Text(summary.repoDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if summary.needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(SessionsV2Theme.accent)
                        .font(.caption2)
                }
            }
            HStack(spacing: 4) {
                Text(summary.agent.rawValue.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(summary.agent == .claude ? SessionsV2Theme.accent : SessionsV2Theme.codexBlue)
                if let model = summary.modelDisplay {
                    Text("· \(model)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let goal = summary.goalSnippet {
                Text(goal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statusDot(_ summary: WatchSessionSummary) -> some View {
        Circle().fill(statusColor(summary.status)).frame(width: 6, height: 6)
    }

    private func statusColor(_ raw: String) -> Color {
        switch raw {
        case "running":  return .green
        case "planning": return .gray
        case "paused":   return SessionsV2Theme.warn
        case "done":     return SessionsV2Theme.accent
        case "degraded": return .red
        default:         return .secondary
        }
    }
}

/// Per-session detail view on watchOS — agent + model + status + actions
/// (Approve plan / Interrupt / Send voice reply). Sessions v2 Phase 6.
struct WatchSessionDetailView: View {
    let summary: WatchSessionSummary
    @ObservedObject var bridge: WatchPlanBridge
    @State private var dictation: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                actionButtons
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle(summary.repoDisplayName)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(summary.agent.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.agent == .claude ? SessionsV2Theme.accent : SessionsV2Theme.codexBlue)
                if let model = summary.modelDisplay {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary.status.capitalized)
                    .font(.caption2.weight(.medium))
            }
            if let goal = summary.goalSnippet {
                Text(goal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 6) {
            if summary.needsAttention {
                Button {
                    bridge.approve(sessionId: summary.id)
                } label: {
                    Label("Approve plan", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SessionsV2Theme.accent)
            }
            Button(role: .destructive) {
                bridge.interrupt(sessionId: summary.id)
            } label: {
                Label("Interrupt", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                bridge.requestVoiceReply(sessionId: summary.id)
            } label: {
                Label("Voice reply", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(SessionsV2Theme.codexBlue)
        }
    }
}
