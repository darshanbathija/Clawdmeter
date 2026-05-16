import Foundation
import Combine
import ClawdmeterShared
import OSLog

private let chatStoreLogger = Logger(subsystem: "com.clawdmeter.ios", category: "ChatStore")

/// iOS-side mirror of the Mac's `SessionChatStore`. Subscribes to the
/// daemon's `GET /sessions/:id/chat-snapshot` REST endpoint at refresh
/// intervals; future WS-push wiring will plug into the same publisher.
///
/// Sessions v2 Phase 4 / T40. The Mac maintains the canonical `ChatSnapshot`
/// (via StagingParser + reverse-tail prefetch); iOS just receives it.
///
/// Memory: bounded to LRU-2 stores via `iOSChatStoreCache` (T42).
@MainActor
public final class iOSChatStore: ObservableObject {
    @Published public private(set) var snapshot: WireChatSnapshot
    public let sessionId: UUID

    private weak var client: AgentControlClient?
    private var pollTask: Task<Void, Never>?

    public init(sessionId: UUID, client: AgentControlClient) {
        self.sessionId = sessionId
        self.client = client
        self.snapshot = WireChatSnapshot(
            sessionId: sessionId,
            items: [],
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: nil,
            updateCounter: 0
        )
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s poll until WS push is wired
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    @MainActor
    public func refresh() async {
        guard let client else { return }
        if let fetched = await client.fetchChatSnapshot(sessionId: sessionId),
           fetched.updateCounter > snapshot.updateCounter || fetched.items != snapshot.items {
            self.snapshot = fetched
        }
    }
}

/// LRU-2 cache so the iPhone doesn't keep N chat stores alive when the
/// user opens many session detail views. Protected sessions (foregrounded
/// + Live-Activity-pinned) bypass eviction.
///
/// Sessions v2 T42 (mirrors Mac LRU-3 from `SessionsView.protectedSessionIds`).
@MainActor
public final class iOSChatStoreCache {
    public static let shared = iOSChatStoreCache()
    public static let maxStores: Int = 2

    private var stores: [UUID: iOSChatStore] = [:]
    private var accessOrder: [UUID] = []   // LRU; most-recent at end
    private(set) var protectedSessions: Set<UUID> = []

    public init() {}

    public func store(for sessionId: UUID, client: AgentControlClient) -> iOSChatStore {
        if let existing = stores[sessionId] {
            touch(sessionId)
            return existing
        }
        let new = iOSChatStore(sessionId: sessionId, client: client)
        new.start()
        stores[sessionId] = new
        accessOrder.append(sessionId)
        evictIfNeeded()
        return new
    }

    /// Pin a session so it's never evicted by LRU. Used for foregrounded
    /// SessionDetailView + any session referenced by an active Live Activity.
    public func protectSession(_ sessionId: UUID) {
        protectedSessions.insert(sessionId)
    }

    public func unprotectSession(_ sessionId: UUID) {
        protectedSessions.remove(sessionId)
        evictIfNeeded()
    }

    public func close(sessionId: UUID) {
        stores[sessionId]?.stop()
        stores.removeValue(forKey: sessionId)
        accessOrder.removeAll { $0 == sessionId }
    }

    private func touch(_ sessionId: UUID) {
        accessOrder.removeAll { $0 == sessionId }
        accessOrder.append(sessionId)
    }

    private func evictIfNeeded() {
        let evictable = accessOrder.filter { !protectedSessions.contains($0) }
        let excess = (stores.count - protectedSessions.count) - Self.maxStores
        guard excess > 0 else { return }
        for id in evictable.prefix(excess) {
            chatStoreLogger.debug("LRU evict chat store \(id.uuidString, privacy: .public)")
            close(sessionId: id)
        }
    }
}

extension AgentControlClient {
    /// Fetch a chat snapshot for a session. Phase 0 returns an empty
    /// snapshot (sentinel `updateCounter == 0`); Phase 4 populates fully.
    @MainActor
    public func fetchChatSnapshot(sessionId: UUID) async -> WireChatSnapshot? {
        guard let host, let token else { return nil }
        guard let url = URL(string: "http://\(host):\(httpPort)/sessions/\(sessionId.uuidString)/chat-snapshot") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WireChatSnapshot.self, from: data)
        } catch {
            return nil
        }
    }
}
