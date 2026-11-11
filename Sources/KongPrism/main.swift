import AppKit

// Not @MainActor itself (main.swift creates it synchronously); its NSApplicationDelegate
// methods run on the main actor, and the main-actor objects are created there.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: StatusMenu?
    private var settingsWindow: SettingsWindowController?

    @MainActor private var settings: SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let created = SettingsWindowController()
        settingsWindow = created
        return created
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one KongPrism at a time: two would fight over the ports and the system proxy.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }
        AppLog.write("KongPrism \(AppUpdater.version)（\(AppUpdater.build)）启动")
        let menu = StatusMenu()
        menu.openSettings = { [weak self] tab in self?.settings.show(tab) }
        self.menu = menu
        let controller = AppController.shared
        controller.launch()
        if controller.profiles.isEmpty { settings.show(.profiles) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.shutdown()
    }

    /// clash:// sing-box:// kongprism:// links, and files opened with KongPrism.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Importer.open(url, controller: AppController.shared) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(.general)
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
