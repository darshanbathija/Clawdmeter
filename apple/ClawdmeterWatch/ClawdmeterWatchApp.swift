import SwiftUI
import ClawdmeterShared

@main
struct ClawdmeterWatchApp: App {
    @StateObject private var model = WatchUsageModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
