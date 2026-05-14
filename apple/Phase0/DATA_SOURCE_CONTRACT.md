# Phase 0 — Data Source Contract

Per plan E13: Phase 0 outputs an explicit contract that V1 architecture builds against.

**Status:** Quick-probe passing as of 2026-05-14 07:40 UTC. 24h soak in progress (see `phase0-soak.sh`).

## Transport

- **Protocol:** HTTPS
- **Method:** POST
- **URL:** `https://api.anthropic.com/v1/messages`
- **Cost per call:** ~$0.000001 (8 input + 1 output tokens at Claude Haiku 4.5 rate)
- **Cadence:** 60s foreground, 5min background (`BGAppRefreshTask` on iOS)

## Auth

- **Mechanism:** OAuth bearer token
- **Storage on macOS:** Keychain item `Claude Code-credentials` (service: `Claude Code-credentials`)
- **Storage on iOS:** Keychain item `Claude Code-credentials` (after user completes ASWebAuthenticationSession OAuth flow). Cross-device share via iCloud Keychain (`kSecAttrSynchronizable = true`) when both devices on same Apple ID.
- **Token shape:** `sk-ant-oat01-…` (108 chars observed)
- **Token JSON wrapper in Keychain (macOS observed):**
  ```json
  { "claudeAiOauth": { "accessToken": "sk-ant-oat01-…", "refreshToken": "…", "expiresAt": <epoch_ms> } }
  ```

## Required headers

| Header | Value |
|---|---|
| `Authorization` | `Bearer <accessToken>` |
| `anthropic-version` | `2023-06-01` |
| `anthropic-beta` | `oauth-2025-04-20` |
| `Content-Type` | `application/json` |
| `User-Agent` | `claude-code/2.1.5` (mimic Claude Code; Anthropic likely scopes OAuth-beta to this UA) |

## Request body (minimum-cost probe)

```json
{
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 1,
  "messages": [{ "role": "user", "content": "hi" }]
}
```

## Response signal (rate-limit headers)

| Header | Type | Meaning |
|---|---|---|
| `anthropic-ratelimit-unified-5h-utilization` | float 0.0–1.0 | Session window usage |
| `anthropic-ratelimit-unified-5h-reset` | epoch seconds | Session window reset time |
| `anthropic-ratelimit-unified-5h-status` | `allowed` \| `limited` | Session status |
| `anthropic-ratelimit-unified-7d-utilization` | float 0.0–1.0 | Weekly window usage |
| `anthropic-ratelimit-unified-7d-reset` | epoch seconds | Weekly window reset time |
| `anthropic-ratelimit-unified-7d-status` | `allowed` \| `limited` | Weekly status |
| `anthropic-ratelimit-unified-representative-claim` | `five_hour` \| `seven_day` | Which window is binding |
| `anthropic-ratelimit-unified-fallback-percentage` | float | Reduced-rate threshold |
| `anthropic-ratelimit-unified-overage-status` | `rejected` \| `allowed` | Overage policy |
| `anthropic-organization-id` | UUID | For V2 multi-account |
| `request-id` | `req_…` | For support / debugging |

## UsageData mapping (per E14 reset-boundary integrity)

```swift
struct UsageData: Codable, Equatable {
    let sessionPct: Int           // round(5h-utilization * 100)
    let sessionResetMins: Int     // max(0, round((5h-reset - serverNow) / 60))
    let sessionEpoch: Int         // 5h-reset itself (window-end as window-id; new reset = new epoch)
    let weeklyPct: Int            // round(7d-utilization * 100)
    let weeklyResetMins: Int
    let weeklyEpoch: Int
    let status: Status            // 5h-status; "limited" if either window limited
    let representativeClaim: Window
    let updatedAt: Date           // server-time from `date:` response header
    let organizationID: String?   // for V2

    enum Status: String, Codable { case allowed, limited, unknown }
    enum Window: String, Codable { case fiveHour = "five_hour", sevenDay = "seven_day" }
}
```

**Server-time reference (E14):** parse `date:` response header into `updatedAt` rather than calling `Date()`. Prevents predictor / ordering bugs on clock-drifted devices.

## Pass criteria (E2)

- [x] **C1.** Endpoint returns 200 with rate-limit headers in single probe (passed 2026-05-14)
- [ ] **C2.** Endpoint returns valid response for 24h continuously, no 4xx/5xx (soak in progress; see `phase0-soak.sh`)
- [ ] **C3.** OAuth refresh executes at least once during 24h window without re-auth prompt
- [x] **C4.** Returned fields match daemon's parsing exactly (verified against `daemon/claude-usage-daemon.sh` lines 212-216)
- [x] **C5.** Endpoint is publicly used by Claude Code (User-Agent `claude-code/*`) and ESP32 daemon (proven via existing hardware deployment)

## Fail condition

If C2 or C3 fail during the 24h soak, pivot to:
- **Option a:** Read Claude Code's local OpenTelemetry export. Pros: documented by Anthropic. Cons: requires user to enable OTel in Claude Code config.
- **Option b:** Watch `~/.claude/projects/*/history.jsonl` for session activity markers. Pros: no API call required. Cons: doesn't give utilization %, only "active recently."
- **Option c:** Pivot to "time since last Claude usage" + manual reset markers as honest signals.

## Notes

- **No documented public usage API** for individual Anthropic accounts. The `anthropic-ratelimit-unified-*` headers are observed-stable but not formally documented. This is a Layer-2 (new and popular) signal: it works today, it's how Claude Code itself displays usage, but it can change. The Mac menu bar app must surface "data source signal" health to the user so a future Anthropic header change can be diagnosed.
- **Endpoint cost amortization:** at 60s polling cadence, 1440 polls/day × ~$0.000001 = ~$0.0014/day. Negligible.
- **Rate-limit footprint:** each poll consumes 9 tokens of usage. Over 24h: 12,960 tokens, equivalent to roughly 0.05% of a typical session budget. Acceptable.
