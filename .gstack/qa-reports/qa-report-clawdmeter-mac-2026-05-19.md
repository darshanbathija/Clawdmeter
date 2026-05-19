# QA Report — Clawdmeter (Mac + iOS), 2026-05-19

**Branch:** `main` at commit `5e4e72c`
**Mode:** Diff-aware (Gemini provider work, committed in `8cfb2c6`)
**Tier:** Standard (critical + high + medium fixed)
**Surface:** Native Mac app + iPhone 17 simulator (not a web app — adapted /qa to use computer-use MCP instead of browse)

PR Summary line:
> /qa found 4 issues, fixed 2 (medium), deferred 2 (low). Mac dashboard now drops the phantom Gemini Weekly limits card; D7 stale badge fires on cached fallback. 333 → 335 tests passing.

---

## Health score

| Category       | Before | After |
|----------------|-------:|------:|
| Visual         | 84     | 100   |
| Functional     | 80     | 92    |
| UX             | 88     | 96    |
| Console        | 100    | 100   |
| Performance    | 100    | 100   |
| Accessibility  | 90     | 90    |
| **Weighted**   | **88** | **96** |

(+8 from fixing the two medium issues. Two low-severity items deferred to TODOS.md.)

---

## Top 3 things to fix (sorted)

1. **ISSUE-001 (M, FIXED)** — D7 stale-data badge never rendered on the Mac Gemini column because UsagePoller dropped cached emissions
2. **ISSUE-002 (M, FIXED)** — Mac dashboard rendered a phantom "Weekly limits" card under Gemini that doesn't exist upstream
3. **ISSUE-003 (L, DEFERRED)** — Toggling Codex/Gemini menu-bar checkbox doesn't materialize the status item (multi-instance race)

---

## Pages / surfaces tested

| Surface | Result |
|---|---|
| Mac dashboard → Usage tab | 3 columns rendering correctly (Claude/Codex/Gemini) |
| Mac dashboard → analytics row | "$X / N tok" for Claude+Codex, "N reqs" for Gemini ✅ (X3-C schema split working) |
| Mac dashboard → Daily spend chart | Claude (orange) + Codex (blue) stacked, footnote "Gemini — token cost unavailable from CLI logs" ✅ |
| Mac dashboard → Daily requests chart | Separate panel for Gemini, one bar on 2026-05-19 ✅ |
| Mac dashboard → By-repo list | glide.co/axtior-neobank/axtior-platform/Clawdmeter/Defx V3/Other — no "+N gem" pill (ISSUE-004) |
| Mac Settings → Providers | Claude/Codex/Gemini sections — Gemini labeled "5h refresh" (correct), all Connected ✅ |
| Mac menu-bar gauge | "2% 47m ✻ 93% 13h 57m" Claude gauge visible — Codex/Gemini items missing (ISSUE-003) |
| iOS Live tab (unpaired) | Gemini logo correctly HIDDEN when wire version unknown (X3-A gating working) ✅ |
| iOS Settings | Anthropic token + Codex section + Gemini section with new "Gemini requires the Mac app" copy ✅ |

---

## ISSUE-001 — D7 stale badge never fires (MEDIUM, FIXED)

**Status:** verified — commit `2b74bb1`

**Symptom:** Mac dashboard Gemini column footer reads "Last updated 7 hrs, 45 min ago" but no orange ⚠ triangle, no "Stale" wording. Plan D7 contract says cached-fallback should fire the badge.

**Root cause:** `GeminiSource.cachedFallbackOrThrow` emitted UsageData with `updatedAt: lastUpdatedAt` (the last-success timestamp, often hours old). `UsagePoller.shouldReplace` (UsageData.swift:85-92) implements E3 ordering — `incoming.updatedAt > self.updatedAt` — so the cached emission tied with the prior `.allowed` snapshot and was dropped. `.unknown` status never reached `AppModel.usage`; the dashboard kept rendering the last live snapshot indefinitely.

**Fix:** `GeminiSource.swift:329` — set `updatedAt: now` (was `lastUpdatedAt`). The cached emission now strictly exceeds the prior snapshot's `updatedAt`, the poller forwards it, and the dashboard's `model.usage?.status == .unknown` gate at `DashboardView.swift:393` flips on.

**UX after fix:** Footer reads "Stale · updated 5 secs ago" with orange triangle. `sessionEpoch` still points at the cached reset target so the countdown stays honest.

**Regression test:** `GeminiProviderLaneATests.test_cachedFallbackEmission_replacesPriorAllowed_soUnknownStatusPropagates` + counterfactual `test_cachedFallback_withStaleUpdatedAt_correctlyDropped`. Locks the `UsageData.shouldReplace` contract at the model layer so future refactors don't regress.

**Files changed:**
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/GeminiSource.swift`
- `apple/ClawdmeterShared/Tests/ClawdmeterSharedTests/GeminiProviderLaneATests.swift`

---

## ISSUE-002 — Phantom "Weekly limits" card on Gemini Mac column (MEDIUM, FIXED)

**Status:** verified — commit `24a9f2a`

**Symptom:** Mac dashboard Gemini column rendered "Weekly limits · All models · 0% used · Resets 6 days, 16 hrs" — a card that lied about a quota window that doesn't exist upstream. Settings → Providers already correctly labeled Gemini as "5h refresh"; iOS GeminiSection already dropped its WeeklyCard. Mac was the parity gap.

**Root cause:** `DashboardView.ProviderColumn.body` rendered the Weekly limits VStack unconditionally for all providers. cloudcode-pa returns a single `refreshTime` per model — no weekly bucket.

**Fix:** New `ProviderConfig.hasWeeklyWindow: Bool = true` flag, set to `false` for `.gemini`. `DashboardView.swift:350` gates the Weekly limits section on `model.config.hasWeeklyWindow`.

**Files changed:**
- `apple/ClawdmeterMac/ProviderConfig.swift`
- `apple/ClawdmeterMac/DashboardView.swift`

**Evidence:**
- Before: 3-column layout, all three columns showed Weekly limits (Gemini had "0% used · Resets 6 days, 16 hrs" — invented).
- After: `.gstack/qa-reports/screenshots/issue-002-after.png` — Gemini column shows Current session → Advanced → footer only. Claude/Codex unchanged.

---

## ISSUE-003 — Codex/Gemini menu-bar items don't appear after toggle (LOW, DEFERRED)

**Status:** deferred to TODOS.md (v0.7 follow-ups section)

Toggling the "Menu bar Codex" / "Menu bar Gemini" checkbox in the dashboard header flipped the AppStorage key but no new NSStatusItem materialized — only the Claude burst gauge stayed visible. Reproducible only when an older Clawdmeter instance is running alongside (the user's pre-existing menu-bar app); multi-instance race for AppStorage + NSStatusBar registration.

Cosmetic — quota numbers still surface in the dashboard window. Not blocking ship.

Hypothesis + hook documented in `TODOS.md` under "v0.7 — Gemini provider follow-ups → ISSUE-003".

---

## ISSUE-004 — AnalyticsRepoList missing "+N gem" pills (LOW, DEFERRED)

**Status:** deferred to TODOS.md

The Token-usage row correctly shows "4 reqs · All time" for Gemini, and the Daily-requests chart renders a bar on 2026-05-19. But the By-repo list shows zero "+N gem" pills across glide.co/axtior-neobank/axtior-platform/Clawdmeter/Defx V3/Other. The X3-C trunk refactor in `AnalyticsRepoList.swift` is wired to `geminiRequests` per row, so the upstream feed (`GeminiUsageParser` → `UsageHistoryLoader` byRepo) is the suspect.

Hypothesis + hook documented in `TODOS.md` under "v0.7 — Gemini provider follow-ups → ISSUE-004".

---

## Tests

```
$ swift test
Test Suite 'ClawdmeterSharedPackageTests.xctest' passed
Executed 335 tests, with 0 failures (0 unexpected) in 160.836 (160.852) seconds
```

Baseline 333 → 335 (added 2 regression tests for ISSUE-001).

Build matrix:
- Mac scheme: BUILD SUCCEEDED (with both fixes)
- iOS scheme: BUILD SUCCEEDED (not modified this QA pass)
- Watch scheme: BUILD SUCCEEDED (not modified this QA pass)

---

## Commits added by /qa

```
5e4e72c docs: defer ISSUE-003 + ISSUE-004 to TODOS.md (from /qa 2026-05-19)
2b74bb1 fix(qa): ISSUE-001 — D7 stale badge fires when Gemini falls back to cache
24a9f2a fix(qa): ISSUE-002 — hide Weekly limits card on Gemini dashboard column
```

---

## Notes on QA adaptation

This is a native macOS/iOS/watchOS app — no web URLs to crawl. The /qa skill's browse-server path doesn't apply. Adapted via:
- **Mac:** `xcodebuild -derivedDataPath /tmp/clawdmeter-qa-build`, `open -n`, computer-use MCP for screenshots/clicks
- **iOS:** `xcrun simctl install + launch` on booted iPhone 17 sim, `xcrun simctl io booted screenshot` for direct sim screenshots
- **Watch:** skipped (not in this QA pass's scope; verified via `xcodebuild build` only)

One QA pitfall worth recording: a stale pre-rebuild Clawdmeter instance was running alongside my fresh build (`/Users/.../Xcode/DerivedData/`). `open_application com.clawdmeter.mac` brought the older window forward by default. I had to `kill -9` the stale PID before my fix was visible in screenshots. **For future QA on native Mac apps: `pgrep -lf "<bundle-id>" | grep -v <new-build-path>` and kill stale instances first.**
