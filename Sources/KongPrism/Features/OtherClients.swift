import AppKit
import Carbon
import KongPrismCore

// MARK: - 其他代理软件

enum OtherClients {
    static let markers = ["kongbabel", "kong.networkconsole", "clash", "verge", "mihomo", "v2ray", "shadowrocket", "surge", "hiddify",
                          "sing-box", "singbox", "stash", "quantumult", "loon", "flclash", "nekoray", "clashx"]

    static func running() -> [NSRunningApplication] {
        let own = Bundle.main.bundleIdentifier?.lowercased()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier?.lowercased(), id != own else { return false }
            return markers.contains { id.contains($0) }
        }
    }

    /// Asks the user (they started connecting) whether to quit the other clients first.
    /// Returns false when they cancel.
    @MainActor
    static func resolveBeforeConnecting() async -> Bool {
        let others = running()
        guard !others.isEmpty else { return true }
        let names = others.map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }.joined(separator: "、")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(names) 正在运行"
        alert.informativeText = "两个代理软件同时开启，会互相改写系统代理或抢占网络，常常导致上不了网。建议先退出它。"
        alert.addButton(withTitle: "退出它并继续")
        alert.addButton(withTitle: "仍然继续")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for app in others { app.terminate() }
            // Give them time to put their system proxy back.
            for _ in 0..<30 where others.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            for app in others where !app.isTerminated { app.forceTerminate() }
            AppLog.write("已退出 \(names)")
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}
