import SwiftUI
import BackgroundTasks
import ClawdmeterShared

@main
struct ClawdmeteriOSApp: App {
    @StateObject private var model = UsageModel()

    init() {
        // Register the BGAppRefreshTask handler at launch (D15 fallback for
        // APNS). The actual scheduling + ack/send happens inside
        // iOSNotificationManager; this just plants the dispatch handler.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: iOSNotificationManager.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            // Use a transient client for the refresh; the persistent
            // instance in ContentView shares UserDefaults state.
            let client = AgentControlClient()
            let manager = iOSNotificationManager(client: client)
            Task { @MainActor in
                let ok = await manager.performRefresh()
                manager.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: ok)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(nil) // honor system theme by default
        }
    }
}
