import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 崩溃记录

/// "上次异常退出" detection (a marker file that a clean quit removes) and macOS crash reports
/// (~/Library/Logs/DiagnosticReports/*.ips) for KongPrism and sing-box.
enum CrashRecords {
    private static var marker: URL { Paths.support.appendingPathComponent("running.marker") }
    private(set) static var lastRunEndedAbnormally = false
    private(set) static var previousRunInfo = ""
    @MainActor private(set) static var notice: String?

    /// At launch, after any older instance was taken over (`tookOver` skips the notice, since
    /// that instance was stopped on purpose).
    @MainActor
    static func begin(tookOver: Bool) {
        if FileManager.default.fileExists(atPath: marker.path) {
            previousRunInfo = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            if !tookOver {
                lastRunEndedAbnormally = true
                let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path)
                let since = (attributes?[.modificationDate] as? Date) ?? Date().addingTimeInterval(-86_400)
                let found = recentReports(days: 14).contains { modified($0) >= since }
                notice = "上次 KongPrism 没有正常退出" + (found ? "，已找到崩溃记录" : "（可能是强制退出或断电）")
                AppLog.write("上次异常退出：\(previousRunInfo.replacingOccurrences(of: "\n", with: " "))\(found ? "，有崩溃记录" : "")")
            }
        }
        let info = "pid \(ProcessInfo.processInfo.processIdentifier)\nversion \(AppUpdater.version)\nstarted \(ISO8601DateFormatter().string(from: Date()))\n"
        try? info.write(to: marker, atomically: true, encoding: .utf8)
        checkLaunchHealth()
    }

    /// 更新后连续启动失败时退回上一个版本: a version that never ran a full minute and ended
    /// abnormally twice in a row is offered a rollback to the backup kept by the installer.
    @MainActor
    private static func checkLaunchHealth() {
        let defaults = UserDefaults.standard
        let previousVersion = previousRunInfo.split(separator: "\n").first { $0.hasPrefix("version ") }.map { String($0.dropFirst(8)) }
        let count = LaunchHealth.abnormalCount(previous: defaults.integer(forKey: "abnormalLaunches"), lastRunEndedAbnormally: lastRunEndedAbnormally,
                                               previousVersion: previousVersion, currentVersion: AppUpdater.version)
        defaults.set(count, forKey: "abnormalLaunches")
        // Running for a minute makes this version the last good one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            defaults.set(AppUpdater.version, forKey: "lastGoodVersion")
            defaults.set(0, forKey: "abnormalLaunches")
        }
        let backup = AppUpdater.backupVersion
        // Before 0.7 nothing recorded the last good version: the installer's backup is it.
        let lastGood = defaults.string(forKey: "lastGoodVersion") ?? (backup != AppUpdater.version ? backup : nil)
        guard LaunchHealth.shouldOfferRollback(abnormalCount: count, currentVersion: AppUpdater.version, lastGoodVersion: lastGood, backupVersion: backup),
              let lastGood else { return }
        AppLog.write("\(AppUpdater.version) 连续 \(count) 次没有正常运行，提供退回 \(lastGood)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { offerRollback(to: lastGood, failures: count) }
    }

    @MainActor
    private static func offerRollback(to previous: String, failures: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "KongPrism \(AppUpdater.version) 连续 \(failures) 次没能正常运行"
        alert.informativeText = "可以退回上一个版本 \(previous)（更新时保留的备份）。以后仍可在 设置 › 更新与关于 里再次更新；也可以先“生成问题报告”发给开发者。"
        alert.addButton(withTitle: "退回 \(previous)")
        alert.addButton(withTitle: "继续使用 \(AppUpdater.version)")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(0, forKey: "abnormalLaunches")
            return
        }
        do {
            try AppUpdater.rollbackToPrevious()
        } catch {
            let failed = NSAlert()
            failed.messageText = "没能退回 \(previous)"
            failed.informativeText = error.localizedDescription
            failed.runModal()
        }
    }

    /// Clean quit.
    static func end() {
        try? FileManager.default.removeItem(at: marker)
    }

    @MainActor
    static func dismissNotice() { notice = nil }

    static func recentReports(days: Int) -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            let name = url.lastPathComponent.lowercased()
            return (name.hasPrefix("kongprism") || name.hasPrefix("sing-box")) && ["ips", "crash", "diag"].contains(url.pathExtension)
                && modified(url) >= cutoff
        }
        .sorted { modified($0) > modified($1) }
    }

    static func summary() -> String {
        var lines = ["上次异常退出：\(lastRunEndedAbnormally ? "是" : "否")"]
        if !previousRunInfo.isEmpty { lines.append("上次运行：" + previousRunInfo.replacingOccurrences(of: "\n", with: "，")) }
        let reports = recentReports(days: 14)
        lines.append("近 14 天崩溃记录 \(reports.count) 个：")
        lines += reports.map { "  · \($0.lastPathComponent)（\(modified($0).formatted(date: .abbreviated, time: .shortened))）" }
        return lines.joined(separator: "\n")
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
