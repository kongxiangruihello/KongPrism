import AppKit
import SwiftUI
import KongPrismCore

/// 更新后的“新功能”: a line at the top of the menu until it is looked at; the window lists the
/// highlights with a button to the settings page where each one lives.
@MainActor
enum WhatsNewNotice {
    private static let seenKey = "lastSeenVersion"
    private(set) static var items: [WhatsNew.Item] = []
    private static var window: NSWindow?

    /// At launch. A fresh install sees nothing; an update shows what came after the version
    /// the user saw last (before 0.8 nothing recorded it: the installer's backup tells).
    static func check() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: seenKey)
            ?? AppUpdater.backupVersion.flatMap { $0 != AppUpdater.version ? $0 : nil }
        guard let previous else {
            defaults.set(AppUpdater.version, forKey: seenKey)
            return
        }
        items = WhatsNew.items(after: previous, upTo: AppUpdater.version)
        if items.isEmpty { defaults.set(AppUpdater.version, forKey: seenKey) }
    }

    static var menuTitle: String? { items.isEmpty ? nil : "✨ \(AppUpdater.version) 有哪些新功能" }

    static func markSeen() {
        UserDefaults.standard.set(AppUpdater.version, forKey: seenKey)
        items = []
    }

    static func show() {
        let list = items.isEmpty ? WhatsNew.items(after: "0.5.1", upTo: AppUpdater.version) : items
        let hosting = NSHostingController(rootView: WhatsNewView(items: list) {
            markSeen()
            window?.close()
        })
        if window == nil {
            let created = NSWindow(contentViewController: hosting)
            created.title = "KongPrism 新功能"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            window = created
        } else {
            window?.contentViewController = hosting
        }
        window?.setContentSize(NSSize(width: 520, height: min(520, 120 + list.count * 44)))
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WhatsNewView: View {
    let items: [WhatsNew.Item]
    let done: () -> Void

    private var versions: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.version) { seen.append(item.version) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(versions, id: \.self) { version in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(version).font(.headline)
                            ForEach(items.filter { $0.version == version }, id: \.text) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text("•")
                                    Text(item.text).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    if let tab = item.tab.flatMap(SettingsTab.init(rawValue:)) {
                                        Button("去看看") { URLActions.openSettings?(tab) }
                                            .controlSize(.small)
                                            .accessibilityLabel("打开 设置 › \(tab.title)")
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("完整更新记录在 GitHub 发布页。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("知道了", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 220)
    }
}
