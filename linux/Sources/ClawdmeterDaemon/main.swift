// Clawdmeter Linux headless daemon entry point.
//
// P1-Linux-4: previously this main just printed "Phase 0 skeleton" and
// exited 0, so the installed systemd service started, immediately
// exited successfully, and stayed in "active (exited)" state forever —
// no HTTP listener, no pairing, no /health. Wire the HummingbirdTransport
// entrypoint here so when the Phase 3 implementation lands, the daemon
// genuinely runs. Today the transport itself is still a Phase 3 stub
// (its start() body sleeps then returns); pairing it with the daemon
// loop means flipping a single TODO inside HummingbirdTransport will
// make the whole binary functional with no extra changes here.

import Foundation
import ClawdmeterShared
import ClawdmeterLinux

@main
struct ClawdmeterDaemon {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("clawdmeterd 0.7.0 (Phase 0 skeleton)")
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            clawdmeterd — Clawdmeter Linux daemon

            Usage: clawdmeterd [options]

            Options:
              --version       Print version and exit
              --headless      Run without tray (default in server installs)
              --with-tray     Run with system tray (default in desktop AppImage)
              -h, --help      Show this help

            Daemon transport: HummingbirdTransport (HTTP 21731 / WS 21732,
            bearer-auth + peer-filter middleware). See
            linux/Sources/ClawdmeterLinux/Transport/HummingbirdTransport.swift.
            """)
            return
        }

        // Construct the bearer-token store + transport. Headless and
        // with-tray differ only in whether the tray poll loop runs alongside
        // the listener; both modes need the HTTP/WS server.
        let bearerStore = LinuxPairingTokenStore.shared
        let transport = HummingbirdTransport(
            configuration: HummingbirdTransport.Configuration(),
            bearerStore: bearerStore
        )

        do {
            try await transport.start()
        } catch {
            FileHandle.standardError.write(Data("clawdmeterd: transport start failed: \(error)\n".utf8))
            exit(1)
        }
        // Codex follow-up to P1-Linux-4: HummingbirdTransport.start() is
        // still a Phase 3 stub that returns immediately on Linux (its
        // body is a `TODO(Phase 3)` block — no actual server). Falling
        // through to a clean exit puts the systemd service back into
        // "active (exited)" state with no listener.
        //
        // Until the real implementation lands, fail loud so systemd's
        // `Restart=on-failure` actually restarts and the operator sees
        // the dependency gap. Set CLAWDMETER_DAEMON_ALLOW_STUB=1 to
        // keep the legacy exit-0 behaviour during local development.
        if ProcessInfo.processInfo.environment["CLAWDMETER_DAEMON_ALLOW_STUB"] != "1" {
            FileHandle.standardError.write(Data("clawdmeterd: HummingbirdTransport.start() returned without serving. Phase 3 transport implementation is not wired. Exiting non-zero so systemd restarts.\n".utf8))
            exit(2)
        }
    }
}
