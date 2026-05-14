# Clawdmeter for Apple

Native ports of [Clawdmeter](../) to watchOS / iOS / macOS — the "Anthropic Ambient" vision from the reviewed plan at `~/.claude/plans/clone-this-https-github-com-darshanbathi-delegated-storm.md`.

## What's here

```
apple/
├── README.md                          this file
├── project.yml                        xcodegen spec — generates Clawdmeter.xcodeproj
├── Phase0/                            data-source validation gate (E13)
│   ├── DATA_SOURCE_CONTRACT.md        validated contract V1 builds against
│   ├── phase0-soak.sh                 24h soak harness (running now)
│   └── phase0-summarize.sh            post-soak pass/fail report
├── ClawdmeterShared/                  Swift Package, cross-platform
│   ├── Package.swift
│   ├── Sources/ClawdmeterShared/
│   │   ├── Model/UsageData.swift             session/weekly + epoch ordering (E14)
│   │   ├── Sources/AISource.swift            protocol; AnthropicSource is V1 impl
│   │   ├── Sources/AnthropicSource.swift     rate-limit-header parser, bounded refresh (E7)
│   │   ├── Sources/KeychainTokenProvider.swift  reads Claude Code OAuth token
│   │   ├── Sources/UsagePoller.swift         orchestrator: retry, backoff, epoch merge
│   │   ├── Sources/ESP32BLEDriver.swift      BLE state machine (E5+E9) + CoreBluetooth wrapper
│   │   ├── Predictor/BurnRatePredictor.swift rolling window + hysteresis WarningGate
│   │   ├── Theme/Theme.swift                 colors, typography, layout, motion tokens
│   │   └── Render/MeterRenderer.swift        Ring, Arc, BigNumeral, StaleBadge, AODStyle (E6)
│   └── Tests/ClawdmeterSharedTests/          XCTest, 38 tests, all passing
└── ClawdmeterMac/                     macOS menu bar app (Plan D5)
    ├── ClawdmeterMacApp.swift                @main, MenuBarExtra + Settings scene
    ├── AppModel.swift                        ObservableObject wraps UsagePoller + ESP32BLEDriver
    ├── MenuBarGaugeView.swift                16pt menu-bar gauge
    ├── PopoverView.swift                     one-composition popover (Plan D2)
    ├── Info.plist                            LSUIElement, BLE usage description
    └── ClawdmeterMac.entitlements            sandbox, BLE, network client
```

## Status

- **Phase 0 quick probe:** PASSING. Anthropic `/v1/messages` returns `anthropic-ratelimit-unified-*` headers.
- **Phase 0 24h soak:** Running in background (PID 67314). Currently 11/11 polls successful, 0 errors. Check with `tail -f apple/Phase0/soak.log`.
- **ClawdmeterShared:** builds clean, **38/38 XCTest tests passing** (`swift test`).
- **ClawdmeterMac:** source written, needs Xcode (or xcodegen → Xcode) to build.

## Setup workflow (for next session in Xcode)

```bash
brew install xcodegen          # one-time
cd apple/
xcodegen                       # generates Clawdmeter.xcodeproj
open Clawdmeter.xcodeproj
```

In Xcode:
1. Open `Clawdmeter (Mac)` scheme.
2. Set the Development Team in target settings (`ClawdmeterMac` → Signing & Capabilities).
3. Run. The menu bar app appears in the top-right; no Dock icon (LSUIElement).
4. Settings (⌘,) lets you toggle hardware-link and force a poll.

For iOS / watchOS targets: source directories are referenced but empty (`optional: true` in project.yml). Create `ClawdmeteriOS/`, `ClawdmeterWatch/`, etc. with sources, then re-run `xcodegen`.

## Plan mapping

Every `E#` / `D#` reference in code comments maps to a decision in the plan file (`~/.claude/plans/clone-this-https-github-com-darshanbathi-delegated-storm.md`).

Key implementations:
- **E5** (BLE state machine) — [ESP32BLEDriver.swift](ClawdmeterShared/Sources/ClawdmeterShared/Sources/ESP32BLEDriver.swift): 8 states, exponential backoff schedule `[1,2,4,8,16,32,60]`, max 5 reconnect attempts, auto-recover from `poweredOff` (codex #11), `unauthorized` requires user reset.
- **E7** (bounded OAuth refresh) — [AnthropicSource.swift](ClawdmeterShared/Sources/ClawdmeterShared/Sources/AnthropicSource.swift): 2 attempts per 10-min window → `AISourceError.authExpired`.
- **E14** (reset-boundary epochs) — [UsageData.swift](ClawdmeterShared/Sources/ClawdmeterShared/Model/UsageData.swift) `shouldReplace(with:)`: `(epoch, updatedAt)` tuple ordering; predictor resets window on `sessionEpoch` change.
- **D5** (Mac replaces daemon + drives BLE) — [AppModel.swift](ClawdmeterMac/AppModel.swift): `UsagePoller` events fan out to BLE driver via `writeUsage()` matching firmware GATT shape (`{"s":N,"sr":M,"w":N,"wr":M,"st":"…","ok":true}`).
- **D2** (Mac popover one-composition) — [PopoverView.swift](ClawdmeterMac/PopoverView.swift): 320×320, gauge dominant top, sparkline middle, status row bottom. No cards.

## Local build verification

```bash
cd apple/ClawdmeterShared
swift build       # ~2 min cold, ~2s warm
swift test        # 38 tests, ~0.02s
```

## Phase 0 monitoring

```bash
tail -f apple/Phase0/soak.log              # live progress
wc -l apple/Phase0/soak.jsonl              # poll count so far
apple/Phase0/phase0-summarize.sh apple/Phase0/soak.jsonl   # after 24h
```

Soak target: 1440 polls over 24h. Pass criteria documented in `apple/Phase0/DATA_SOURCE_CONTRACT.md`.

## What still needs Xcode

The ClawdmeterShared package is fully self-contained — build and test from CLI today. The Mac app, iOS app, watchOS app, and widget extensions require Xcode (or `xcodegen → Xcode`) because they need:
- App bundles with Info.plist + entitlements
- Code signing
- Widget extension embedding
- ASWebAuthenticationSession (iOS OAuth flow)
- WCSession entitlement
- iCloud Keychain capability for cross-device token sharing (Mac/iOS, per E12)

## Bash commands cheat sheet

```bash
# Re-test shared package
( cd apple/ClawdmeterShared && swift test )

# Restart Phase 0 soak (kills old + starts new)
pkill -f phase0-soak.sh; ( cd apple/Phase0 && nohup ./phase0-soak.sh > soak.log 2>&1 & )

# Summarize Phase 0 soak (after 24h)
apple/Phase0/phase0-summarize.sh apple/Phase0/soak.jsonl

# Generate Xcode project from project.yml
( cd apple && xcodegen )
```
