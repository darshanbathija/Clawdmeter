import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// Compact pairing UI used by the dashboard's "Sync with iPhone"
/// toolbar button. Shows the QR code + a Copy URL CTA so users don't
/// have to dig into Settings → Sessions to pair a phone.
///
/// Mirrors the host/port/token wiring in `PairingSettingsView` but
/// strips the supervisor / security / scan-roots / plugins panes so
/// the popover stays the right size for a chrome dropdown. The
/// regenerate + revoke controls still live in Settings — keeping the
/// dashboard popover focused on the happy path makes "first-time
/// pair" feel like a one-click action.
struct PairingQRPopoverContent: View {

    @ObservedObject var runtime: AppRuntime
    @State private var qrImage: NSImage?
    @State private var tokenForDisplay: String = ""
    @State private var didCopy: Bool = false
    @State private var hostName: String = "127.0.0.1"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair iPhone")
                .font(.system(size: 15, weight: .semibold))

            if let httpPort = runtime.agentControlServer.boundPort,
               let wsPort = runtime.agentControlServer.boundWsPort {
                VStack(spacing: 12) {
                    qrTile
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan with Clawdmeter on your iPhone")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("or paste the URL after copying.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button(action: copyPairingURL) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                Text(didCopy ? "Copied ✓" : "Copy URL")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(terraCotta)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        labelRow("Host", value: hostName)
                        labelRow("Ports", value: "\(httpPort) / \(wsPort)")
                        labelRow("Token", value: String(tokenForDisplay.prefix(8)) + "…")
                    }
                    .padding(.top, 4)
                }
            } else {
                Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { refresh() }
    }

    // MARK: - Subviews

    private var qrTile: some View {
        Group {
            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 200, height: 200)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func labelRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    // MARK: - Actions

    private func copyPairingURL() {
        guard let url = pairingURLString() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            didCopy = false
        }
    }

    // MARK: - Helpers

    private func refresh() {
        tokenForDisplay = PairingTokenStore.shared.currentToken()
        hostName = macHost()
        qrImage = pairingURLString().flatMap { generateQR(from: $0) }
    }

    private func pairingURLString() -> String? {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort else { return nil }
        return "clawdmeter://\(hostName):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
    }

    /// Best-effort: read the Tailscale MagicDNS name from `tailscale status`.
    /// Falls back to `127.0.0.1` (works from iOS Simulator on the same Mac;
    /// real iPhones reach the Mac via the MagicDNS name over Tailscale).
    private func macHost() -> String {
        if let result = try? Process.runAndCaptureForPairing(
            "/opt/homebrew/bin/tailscale", ["status", "--json"]
        ),
           let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
           let selfNode = json["Self"] as? [String: Any],
           let dnsName = selfNode["DNSName"] as? String,
           !dnsName.isEmpty {
            return dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return "127.0.0.1"
    }

    private func generateQR(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaleFactor: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
    }
}

/// Local `Process` helper kept fileprivate so it doesn't collide with the
/// identically named extension in `PairingSettingsView`.
fileprivate extension Process {
    static func runAndCaptureForPairing(_ executable: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}
