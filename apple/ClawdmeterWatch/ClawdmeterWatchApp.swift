import SwiftUI
import ClawdmeterShared

@main
struct ClawdmeterWatchApp: App {
    @StateObject private var model = WatchUsageModel()
    @StateObject private var planBridge = WatchPlanBridge.shared

    @State private var showingApproval = false

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: planBridge.planWaitingCount) { _, newCount in
                    if newCount > 0 { showingApproval = true }
                }
                .onOpenURL { url in
                    // `clawdmeter://approve` from the complication tap.
                    if url.host == "approve" || url.path.contains("approve") {
                        if planBridge.planWaitingCount > 0 { showingApproval = true }
                    }
                }
                .sheet(isPresented: $showingApproval) {
                    PlanApprovalView(bridge: planBridge)
                }
        }
    }
}
