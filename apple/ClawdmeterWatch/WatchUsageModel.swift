import Foundation
import Combine
import OSLog
import WatchKit
import ClawdmeterShared

/// watchOS view-model. Same shape as iOS's `UsageModel` but smaller:
///   - No "force poll on app foreground" via UIApplication notifications
///     (we use `WKExtension.applicationDidBecomeActiveNotification` instead).
///   - No background polling for now — we rely on the user opening the app
///     or on widget complications timeline-refreshing.
@MainActor
public final class WatchUsageModel: ObservableObject {

    public let tokenProvider: PastedAnthropicTokenProvider
    private let logger = Logger(subsystem: "com.clawdmeter.watch", category: "WatchUsageModel")

    @Published public private(set) var usage: UsageData?
    @Published public private(set) var lastError: AISourceError?
    @Published public private(set) var needsReauth: Bool = false

    private var poller: UsagePoller?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        self.tokenProvider = PastedAnthropicTokenProvider.shared()
        configurePollerIfTokenPresent()
        observeLifecycle()
    }

    public func forcePoll() {
        guard let poller else { return }
        Task { _ = await poller.forcePoll() }
    }

    private func configurePollerIfTokenPresent() {
        guard tokenProvider.hasToken else {
            poller?.stop()
            poller = nil
            return
        }
        if poller != nil { return }

        let source = AnthropicSource(tokenProvider: tokenProvider)
        let p = UsagePoller(source: source)
        p.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.consume(event) }
        }
        p.start()
        poller = p
        logger.info("Poller started")
    }

    private func consume(_ event: UsagePoller.Event) {
        switch event {
        case .usage(let u):
            usage = u
            lastError = nil
            needsReauth = false
            UsageStore.write(u, providerID: "claude", displayName: "Claude")
            UsageStore.reloadWidgets(providerID: "claude")
        case .error(let err):
            lastError = err
            logger.error("Poller error: \(String(describing: err))")
        case .unauthenticatedNeedsReauth:
            needsReauth = true
        case .predictorWarning:
            break
        }
    }

    private func observeLifecycle() {
        NotificationCenter.default.publisher(for: WKApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                // Re-check Keychain (iCloud Keychain may have synced) and
                // poll fresh data when the watch face is brought back.
                self?.configurePollerIfTokenPresent()
                self?.forcePoll()
            }
            .store(in: &cancellables)
    }
}
