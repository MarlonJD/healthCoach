import SwiftUI

@main
struct HealthCoachApp: App {
    @StateObject private var model = iOSAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            iOSRootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.syncNow() }
        }
    }
}
