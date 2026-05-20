#!/usr/bin/env node
// Sidecar dispatcher for Clawdmeter Codex SDK mode.
//
// Spawned by `CodexSDKManager.swift` when the user toggles SDK mode ON
// in Settings → Codex → SDK mode. Receives the agent name on stdin's
// first JSON line, then forwards subsequent lines to the chosen
// subcommand.
//
// Subcommands (v0.7.1 fills in the real impl):
//   observer        — long-running observation bridge for the Sessions
//                     IDE chat pane + analytics. Wraps the SDK's
//                     `thread.runStreamed()` to emit `item.completed`
//                     + `turn.completed` events with token usage.
//   resume          — one-shot. `codex.resumeThread(threadId).run(prompt)`
//                     for iOS→Mac spawn-handoff scenarios.
//
// Protocol matches the Antigravity sidecar's shape so CodexSDKManager
// can reuse the AntigravitySidecarManager flow:
//   {"type": "ready", "version": "0.7.0-skeleton"}
//   {"type": "result", "data": {...}}
//   {"type": "event", "name": "item.completed", "data": {...}}
//   {"type": "event", "name": "turn.completed", "data": {...usage}}
//   {"type": "error", "code": "sdk_not_provisioned", "msg": "..."}
//
// The Swift side ships v0.7.0 with this as a SKELETON. Real provisioning
// (`npm install @openai/codex-sdk` into a managed node_modules) happens
// in v0.7.1; until then this script returns `sdk_not_provisioned` so
// the toggle's failure path exercises end-to-end.
//
// **Authentication contract** (verified against ~/.codex/auth.json on
// dev machine, 2026-05-20): when `auth_mode: "chatgpt"` and tokens are
// present, the SDK inherits them automatically — no API key required.
// The skeleton respects that contract by not reading any env vars
// itself; v0.7.1 will spawn the SDK as a child process that picks up
// auth.json on its own.

import { createInterface } from "node:readline";

/** Write one JSON-line to stdout. */
function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function main() {
  emit({ type: "ready", version: "0.7.0-skeleton" });

  const rl = createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  let firstLine = true;
  for await (const raw of rl) {
    const line = raw.trim();
    if (!line) continue;
    let cmd;
    try {
      cmd = JSON.parse(line);
    } catch (err) {
      emit({ type: "error", msg: `bad JSON: ${err.message}`, raw: line.slice(0, 200) });
      if (firstLine) process.exit(1);
      continue;
    }
    if (firstLine) {
      firstLine = false;
      const agent = cmd.agent ?? "(unspecified)";
      emit({
        type: "error",
        code: "sdk_not_provisioned",
        msg:
          "SDK mode skeleton — full impl ships in v0.7.1. Toggle SDK mode " +
          "off in Settings to dismiss this warning.",
        agent,
      });
      continue;
    }
    // v0.7.1 will dispatch on cmd.op to thread.run / runStreamed /
    // listConversations etc. For now: same skeleton error.
    emit({
      type: "error",
      code: "sdk_not_provisioned",
      msg: "Skeleton — full impl in v0.7.1.",
      echoed_op: cmd.op ?? null,
    });
  }
}

main().catch((err) => {
  emit({ type: "error", msg: `fatal: ${err?.message ?? String(err)}` });
  process.exit(2);
});
