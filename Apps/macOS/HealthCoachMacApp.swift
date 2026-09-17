import SwiftUI
import AppKit

@MainActor
final class HealthCoachMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar extra can still be the primary entry point, but the
        // companion also owns a real dashboard window. Make that window
        // activatable and visible when the user chooses Open HealthCoach.
        NSApp.setActivationPolicy(.regular)
    }
}

@MainActor
final class MacDashboardWindowController: NSObject, ObservableObject {
    private var window: NSWindow?

    func show(model: MacAppModel) {
        if let window {
            activate(window)
            return
        }

        let content = NSHostingController(
            rootView: MacDashboardView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        )
        let window = NSWindow(contentViewController: content)
        window.title = "HealthCoach"
        window.identifier = NSUserInterfaceItemIdentifier("dashboard")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 680))
        window.setFrameAutosaveName("HealthCoachDashboard")
        self.window = window
        activate(window)
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct HealthCoachMacApp: App {
    @NSApplicationDelegateAdaptor(HealthCoachMacAppDelegate.self) private var appDelegate
    @StateObject private var model = MacAppModel()
    @StateObject private var dashboardWindow = MacDashboardWindowController()

    var body: some Scene {
        MenuBarExtra("HealthCoach", systemImage: "heart.text.square") {
            MacMenuView(model: model, dashboardWindow: dashboardWindow)
        }
    }
}
