import AppKit
import ServiceManagement
import KongPrismCore

/// 完全卸载: put the system back the way it was before KongPrism, then quit. The app itself goes
/// to the Trash by hand (a running app cannot delete itself cleanly).
@MainActor
enum Uninstaller {
    /// - Parameter ask: show the confirmation (only CI skips it, see URLActions).
    static func run(controller: AppController, ask: Bool = true) {
        if ask {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "完全卸载 KongPrism？"
            alert.informativeText = """
            将依次：关闭代理并恢复系统代理设置；移除增强模式的辅助程序和授权文件（需要管理员密码）；取消登录时打开；\
            删除订阅、规则、统计、日志和全部设置。iCloud 云盘里的同步文件会保留（其他 Mac 可能还在用）。

            完成后 KongPrism 会退出，并在访达里选中它，把它拖进废纸篓即可。
            """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "完全卸载")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        AppLog.write("完全卸载：开始")
        // Synchronously (we exit right after): restore the system proxy, stop the core and the root core.
        controller.shutdown()
        if SystemProxy.isPointing(to: controller.settings.mixedPort) { try? SystemProxy.restore(port: controller.settings.mixedPort) }
        var problems: [String] = []
        if TunHelper.isInstalled || FileManager.default.fileExists(atPath: TunHelper.rootDirectory) {
            do { try TunHelper.uninstall() } catch { problems.append("增强模式辅助程序：\(error.localizedDescription)") }
        }
        try? SMAppService.mainApp.unregister()
        // From here on nothing may write the folders again.
        AppLog.disabled = true
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kongxiangrui.KongPrism"
        for url in [Paths.support,
                    library.appendingPathComponent("Caches/\(bundleID)"),
                    library.appendingPathComponent("HTTPStorages/\(bundleID)"),
                    library.appendingPathComponent("Saved Application State/\(bundleID).savedState")] {
            try? fm.removeItem(at: url)
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        if ask {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            let done = NSAlert()
            done.messageText = problems.isEmpty ? "已清理完毕" : "已清理，但有一项没有完成"
            done.informativeText = (problems.isEmpty ? "" : problems.joined(separator: "\n") + "\n\n")
                + "把访达里选中的 KongPrism 拖进废纸篓，就完全卸载了。"
            done.runModal()
        }
        exit(0) // not NSApp.terminate: the normal quit path would save settings and logs again
    }
}
