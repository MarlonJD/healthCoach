import SwiftUI

@main
struct HealthCoachWatchApp: App {
    @StateObject private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            WatchWorkoutView(model: model)
        }
    }
}
