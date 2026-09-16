import SwiftUI
import WatchKit

@main
struct HealthCoachWatchApp: App {
    @WKApplicationDelegateAdaptor private var appDelegate: WatchApplicationDelegate
    @StateObject private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            WatchWorkoutView(model: model)
                .task { appDelegate.attach(model: model) }
        }
    }
}
