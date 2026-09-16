import SwiftUI
import AppKit

@main
struct HealthCoachMacApp: App {
    @StateObject private var model = MacAppModel()

    var body: some Scene {
        MenuBarExtra("HealthCoach", systemImage: "heart.text.square") {
            MacMenuView(model: model)
        }
        WindowGroup("HealthCoach", id: "dashboard") {
            MacDashboardView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }
    }
}
