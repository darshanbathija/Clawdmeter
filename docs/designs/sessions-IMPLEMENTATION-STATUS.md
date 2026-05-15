# Sessions feature — implementation status

This is the running status of the Sessions feature build. The full plan
lives at [`use-tailscale-ssh-for-modular-fern.md`](/Users/darshanbathija_1/.claude/plans/use-tailscale-ssh-for-modular-fern.md);
the CEO scope decisions live at [`sessions-control-plane.md`](./sessions-control-plane.md).
This file maps tasks to commits + tracks done vs left.

## Status: Phase 0–5 + T17 + T23 complete. T24 deferred (design API rate-limited).

All three platform schemes (Mac / iOS / Watch) build clean.
**90 / 90 tests pass** (71 ClawdmeterShared + 19 tmux-cc-probe).

## Done ✅

### Phase 0 — tmux-cc-probe (commit `47be37b`)
- T1: `tools/tmux-cc-probe/` Swift package with control-mode parser + PTY helper.
- 19/19 parser unit tests + 6/6 live integration against `tmux 3.6a`.

### Phase 1 — daemon scaffolding (commit `3819a21`)
- T2: `ClawdmeterShared/AgentControl/Protocol.swift` — all Codable DTOs
  including E8 eventSeq cursor.
- T3: `AgentControlServer.swift` — Network.framework HTTP/1.1 on 21731
  + WS listener on 21732. Accept-handler peer filter
  (`127/8`, `::1`, `100.64/10` Tailscale CGNAT, `fd7a:115c:a1e0::/48`).
- T5: `RepoIndex.swift` — background refresh actor; default-empty scan roots.
- T6: `NotificationDispatcher.swift` — pending-event queue with ack semantics.
- T20: `ShellRunner.swift` — argv-only subprocess wrapper (E4 fix for
  space-in-path).

### Phase 2 — tmux integration + session lifecycle (commit `9666173`)
- T7: `TmuxControlClient.swift` — actor with PTY spawn, command dispatch,
  per-pane AsyncStream fan-out, lifecycle events.
- T8: `AgentSessionRegistry.swift` — `@MainActor`, atomic sessions.json
  schema v1, per-session eventSeq.
- T9: `AgentSpawner.swift` + `WorktreeManager.swift` — argv builders +
  D12 multi-gate worktree GC.
- POST/GET/DELETE `/sessions` endpoints.

### T19 — CEO plan promoted to repo (commit `7ead39b`)
- `docs/designs/sessions-control-plane.md` — full CEO plan with all 17
  scope decisions.

### Phase 3 + 4 + T17 + T23 (commit `<latest>`)
- T10 `TerminalWebSocketChannel.swift` — WS bridge with byte-safe input
  transport (`send-keys -l` for short / `paste-buffer -d` for >256B per
  Codex Round 2 #1).
- T11 `PlanCardView` + `StructuredEventList` — cross-platform SwiftUI in
  ClawdmeterShared per P2 = C.
- T22 `AgentEventStream` — E8 cursor contract: per-session eventSeq, retention
  ring (1024 events / 1hr), snapshot frame when cursor is stale.
- T12 `JSONLTail` — line-buffered FileHandle + DispatchSourceVnode with
  rotation / delete / delayed-creation recovery (Codex Round 2 #2).
- T13 `DoneDetector` — three-signal heuristic gated on end-of-turn boundary.
- T14 `PlanModeWatcher` — ExitPlanMode detection + plan-files parsing.
- T14 `POST /sessions/<id>/approve-plan` — kills plan-mode pane, spawns
  fresh `claude --permission-mode acceptEdits` in same tmux window cwd.
- T17 `PairingSettingsView.swift` — Mac Settings tab "Sessions" with
  Core Image QR code, host/ports/token display, regenerate + revoke
  buttons, supervisor health, scan-roots editor.
- T23 `TmuxSupervisor.swift` — consumes lifecycle AsyncStream from
  TmuxControlClient; on `%exit` marks sessions degraded, attempts 3
  exponential-backoff restarts (1s/3s/9s), surfaces "tmux unrecoverable"
  banner in Settings.
- `MacTerminalView.swift` — NSViewRepresentable wrapping `SwiftTerm.TerminalView`,
  URLSession WS client.

### Phase 5 — iOS + Watch (commit `<latest>`)
- T15 `AgentControlClient.swift` (iOS) — REST/WS client with UserDefaults
  config; all daemon endpoints exposed.
- T15 `iOSSessionsView.swift` — third TabView tab with pairing prompt,
  repo list, session detail (Structured ↔ Terminal segmented control).
- T15 `PairingScannerView.swift` — AVCaptureSession QR scanner parsing
  `clawdmeter://` URLs.
- `iOSTerminalView.swift` — SwiftTerm UIView + keyboard accessory bar
  (Esc / Ctrl-latch / Tab / 4 arrows at 44pt each).
- `iOSNotificationManager.swift` — D15 fallback: `UNUserNotificationCenter`
  + `BGAppRefreshTask` registered in `ClawdmeteriOSApp` (com.clawdmeter.ios.refresh).
- T16 `PlanWaitingComplication.swift` — `.accessoryCircular` only (v1 cut
  per D10). Reads from App Group UserDefaults; deep links to `clawdmeter://approve`.
- `WatchPlanBridge.swift` (Watch) + `WatchPlanBridgeIOS.swift` (iPhone) —
  WCSession bridge with `applicationContext` (latest-wins) +
  `transferUserInfo` (queued) delivery. Watch approve sends
  `{op:"approvePlan",sessionId}` back; iPhone forwards to daemon.
- `PlanApprovalView.swift` (Watch) — modal sheet with goal + plan
  summary + terra-cotta Approve button.

### Build matrix
```
xcodebuild -scheme "Clawdmeter (Mac)"   build  → BUILD SUCCEEDED
xcodebuild -scheme "Clawdmeter (iOS)"   build  → BUILD SUCCEEDED
xcodebuild -scheme "Clawdmeter (Watch)" build  → BUILD SUCCEEDED
swift test (ClawdmeterShared)                  → 71/71
swift test (tools/tmux-cc-probe)               → 19/19
```

## Deferred ⏳

- **T24** — Visual mockups for the 4 priority surfaces. The design API
  returned 429 (rate limited) on every attempt during this build. Retry
  whenever the quota refreshes: `$D variants --brief "..." --count 2
  --output-dir ~/.gstack/projects/darshanbathija-Clawdmeter/designs/sessions-feature-20260516/<surface>/`.
  The 8.5/10 design score after Pass 1-7 review still stands; mockups
  push to 9.5/10 by making the visual taste concrete.
- **Real-corpus DoneDetector benchmark (T21)** — the detector + synthetic
  fixtures are in place. The CI-hermetic anonymized-corpus job is one
  more morning of work (snapshot ~10 real sessions, anonymize, add the
  precision/recall threshold test). Not blocking.
- **AgentEventStream live broadcast on `recordEvent`** — the global event
  log accumulates correctly, and the snapshot/replay path works on
  reconnect. The "live push to active subscribers" hop is currently
  driven by the `registry.$sessions` Combine subscription; for finer-
  grained live updates, a `NotificationCenter`-style fanout from
  `recordEvent` is the polish.

## Architectural notes

- **Single Mac, dual-port listener** (HTTP 21731 + WS 21732) — Apple
  `NWProtocolWebSocket` makes the WS upgrade native; HTTP-on-same-port
  WS upgrade would have required hand-rolled WS framing. Two listeners
  is the cleaner architecture for our personal-use scope.
- **Auth = bearer token + Tailscale whois** for non-loopback peers.
  Loopback still requires token (defense-in-depth against local processes).
- **No APNS** — D15 cleared this path. `BGAppRefreshTask` polls
  `/sessions/needs-attention` every ~15-30 min when iOS schedules it;
  foreground uses the WS event stream for live notifications.
- **Plan→impl swap is robust**, not brittle — no keystroke injection into
  Claude's TUI. The daemon kills the plan-mode window and spawns
  `claude --resume <id> --permission-mode acceptEdits` in the same cwd
  (worktree, if used). UI overlay covers the visual gap per D13.

## Commits on this branch

```
git log --oneline main..feat/sessions-control-plane
```

(Run that command for the live list.)
