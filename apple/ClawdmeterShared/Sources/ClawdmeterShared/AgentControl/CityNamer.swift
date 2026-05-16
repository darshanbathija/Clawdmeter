import Foundation

/// City-namer helper. Sessions v2 Phase 9. Maintains assigned-city state
/// so the UI shows stable, unique labels across sessions.
///
/// Backed by `~/Library/Application Support/Clawdmeter/city-assignments.json`
/// on macOS so cities survive app restarts; iOS uses UserDefaults under
/// `clawdmeter.cityAssignments` for the same purpose.
@MainActor
public final class CityNamer: ObservableObject {

    public static let shared = CityNamer()

    /// Session id → assigned city. Stable across runs.
    @Published public private(set) var assignments: [UUID: String] = [:]

    private let storeURL: URL?

    public init() {
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Clawdmeter", isDirectory: true) {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.storeURL = support.appendingPathComponent("city-assignments.json")
        } else {
            self.storeURL = nil
        }
        load()
    }

    public func cityName(for sessionId: UUID) -> String {
        if let existing = assignments[sessionId] {
            return existing
        }
        let taken = Set(assignments.values)
        let picked = CityPool.uniqueCityName(for: sessionId, taken: taken)
        assignments[sessionId] = picked
        save()
        return picked
    }

    public func release(_ sessionId: UUID) {
        if assignments.removeValue(forKey: sessionId) != nil {
            save()
        }
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var version: Int
        var assignments: [String: String]  // UUID.uuidString → city
    }

    private func load() {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(StoreFile.self, from: data) else {
            return
        }
        var loaded: [UUID: String] = [:]
        for (key, value) in file.assignments {
            if let uuid = UUID(uuidString: key) {
                loaded[uuid] = value
            }
        }
        self.assignments = loaded
    }

    private func save() {
        guard let storeURL else { return }
        let raw: [String: String] = assignments.reduce(into: [:]) { acc, pair in
            acc[pair.key.uuidString] = pair.value
        }
        let file = StoreFile(version: 1, assignments: raw)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}
