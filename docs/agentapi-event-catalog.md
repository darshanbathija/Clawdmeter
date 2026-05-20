# agentapi event "catalog" — Phase 0 verification spike (COMPLETE)

## Architectural correction

Phase 0 confirmed there is **no JSON-line event stream** from agentapi. `new-conversation` and `send-message` return immediately as one-shot HTTP-RPC calls. Agent turns happen server-side inside Antigravity's `language_server` and the output goes into a **SQLite database**.

To "observe" a conversation, Clawdmeter needs ONE of:

1. **SQLite WAL polling** (recommended) — open `~/.gemini/antigravity/conversations/<id>.db` read-only, poll the `steps` table for new rows. WAL mode lets reads see latest writes without blocking the writer.
2. **gRPC streaming** — language_server exposes streaming endpoints (`/v1internal:streamGenerateChat`, `/v1internal:tabChat`). Requires CSRF + gRPC client. Higher fidelity but more code.
3. **Brain dir tail** (lowest-fidelity, no-new-code) — v0.7's `BrainPlanParser` + vnode watcher already work. Sufficient for Plan pane; insufficient for streaming chat bubbles.

## SQLite schema (`<conversation_id>.db`)

Captured from a real conversation (4d67b68a-…, "Print: pong", 10 steps).

```
CREATE TABLE `trajectory_meta` (
    `trajectory_id`   text,                       -- unique per trajectory
    `cascade_id`      text,                       -- our conversation_id
    `trajectory_type` integer,                    -- enum
    `source`          integer,                    -- enum
    PRIMARY KEY (`trajectory_id`)
);

CREATE TABLE `steps` (
    `idx`              integer,                   -- 0-based step index
    `step_type`        integer NOT NULL DEFAULT 0,-- enum: see below
    `status`           integer NOT NULL DEFAULT 0,-- enum: in_progress, complete, failed, …
    `has_subtrajectory` numeric NOT NULL DEFAULT false,
    `metadata`         blob,                      -- protobuf metadata
    `error_details`    blob,                      -- protobuf error
    `permissions`      blob,                      -- protobuf permissions
    `task_details`     blob,                      -- protobuf task spec
    `render_info`      blob,                      -- protobuf render hints
    `step_payload`     blob,                      -- protobuf message content (USER_TURN / AGENT_TURN / TOOL_CALL / etc.)
    `step_format`      integer NOT NULL DEFAULT 0,-- payload schema version
    PRIMARY KEY (`idx`)
);

CREATE INDEX `idx_steps_status`    ON `steps`(`status`);
CREATE INDEX `idx_steps_step_type` ON `steps`(`step_type`);

CREATE TABLE `gen_metadata`             (`idx` integer, `data` blob, `size` integer NOT NULL DEFAULT 0, PRIMARY KEY (`idx`));
CREATE TABLE `executor_metadata`        (`idx` integer, `data` blob, PRIMARY KEY (`idx`));
CREATE TABLE `parent_references`        (`idx` integer, `data` blob, PRIMARY KEY (`idx`));
CREATE TABLE `trajectory_metadata_blob` (`id`  text DEFAULT "main", `data` blob, PRIMARY KEY (`id`));
CREATE TABLE `battle_mode_infos`        (`idx` integer, `data` blob, PRIMARY KEY (`idx`));
```

## `step_type` enum (preliminary)

Inferred from binary strings (`CORTEX_STEP_*` enum names). Confirmed values need protobuf-schema extraction from `app.asar` per the `tools/extract-antigravity-proto.sh` work scoped in the original plan.

Expected step_types (best-guess, prioritize confirmation in v0.8.0 commit 3):
- `USER_REQUEST` — user's input prompt
- `PLAN` — model's planning output
- `EXECUTE` — model's execution turn (tool calls)
- `TOOL_CALL` — individual tool invocation
- `TOOL_RESULT` — tool output
- `AGENT_MESSAGE` — agent's response text
- `REASONING` — chain-of-thought traces
- `ERROR` — turn-failed
- `FINISH` — turn-complete signal

The protobuf schema files are inside `/Applications/Antigravity.app/Contents/Resources/app.asar`; extract via `npx asar extract` per v0.6.0 plan section "tools/extract-antigravity-proto.sh".

## Implementation approach for v0.8.0

### `AntigravityConversationDB` (new shared module)

```swift
public actor AntigravityConversationDB {
    /// Open SQLite read-only. WAL mode allows concurrent reads while LS writes.
    public init(dbURL: URL) throws

    /// Snapshot of all steps. Re-query after each WAL change.
    public func steps() async throws -> [Step]

    /// Subscribe to new steps via FSEvents on the `.db-wal` file.
    public func subscribe() -> AsyncSequence<Step>
}

public struct Step: Sendable {
    public let idx: Int
    public let stepType: StepType  // enum
    public let status: StepStatus  // enum
    public let payload: Data       // decoded with ConversationProtoParser
    public let metadata: Data
}
```

### Maps to existing `SessionChatStore.ChatItem`

Each `Step` row decodes to a ChatItem via the existing `appendSDKMessages` path:
- `USER_REQUEST` → `.userText`
- `AGENT_MESSAGE` → `.assistantText`
- `TOOL_CALL` → `.toolCall`
- `TOOL_RESULT` → `.toolResult`
- `REASONING` → `.meta(title: "Reasoning")`
- `ERROR` → `.meta(title: "Error", isError: true)`

### Token usage extraction

`gen_metadata` table likely contains token counts per generation. Need protobuf decode to confirm. Once mapped, drives the cost-ticker via `appendSDKMessages([], deltaInput, deltaOutput, deltaCache)`.

## Multiplex confirmed

Two concurrent `new-conversation` calls against the same running language_server returned distinct conversation IDs without state collision. Each got its own `<id>.db` file. **D12 spirit holds, but the architecture is "use Antigravity.app's LS" rather than "Clawdmeter spawns a shared LS".**

## Approval-mode / thinking-mode — NOT exposed via agentapi argv

```
flag provided but not defined: -approval-mode
flag provided but not defined: -thinking-budget
Usage of new-conversation:
  -model string
    	Model tier to use (flash_lite, flash, pro). (default "flash")
```

Documented as a known limitation. Potential workarounds (untested):
- `SetUserSettings` gRPC — visible in binary strings; may allow per-conversation settings
- `staticConfig.codingAgent.{googleMode, agenticMode}` — visible in metadata; may be set via different gRPC

These need a Phase 0.5 spike before v0.8.0 commits assume any approval-mode behavior. For v0.8.0 ship, accept "no approval modes for agentapi sessions" as a documented limitation. v0.42 fallback still has them.

## Quota endpoint untested

`/v1internal:fetchUserInfo` and `/v1internal:listModelConfigs` exist per binary strings + LS log lines (`Failed to poll FetchAvailableModels`). Untested in Phase 0 because we focused on argv + DB shape. v0.8.1's `AntigravitySource` rewrite tests this directly.
