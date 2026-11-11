import AppKit
import CoreWLAN
import Network
import UserNotifications
import KongPrismCore

// MARK: - 链接控制

/// kongprism://connect · disconnect · toggle · mode/rule|global|direct · node/<名称> · test · update
/// · recover（断开旧连接并重新测速）· sync（iCloud 同步）· reload（重载内核）· menu（菜单导出到 menu.txt）
/// · settings/<订阅|节点|分流|网络|统计|常规|更新>（或 profiles/nodes/rules/network/stats/general/updates）· report · onboarding
/// For Shortcuts, KongSeek, scripts. Import links (kongprism://install-config?url=…) are handled by Importer.
enum URLActions {
    static let actions: Set<String> = ["connect", "disconnect", "toggle", "mode", "node", "test", "update", "settings", "report", "onboarding", "rules",
                                          "recover", "sync", "reload", "menu", "whatsnew",
                                          "tun", "uninstall", "export", "import", "install-update"]
    /// Set by the app delegate, which owns the settings window.
    @MainActor static var openSettings: ((SettingsTab) -> Void)?
    /// Set by the app delegate: the status menu as text (kongprism://menu writes it to menu.txt).
    @MainActor static var dumpMenu: (() async -> String)?
    /// Hidden `ciTestActions` default: enables the test-only links (export / import with a path,
    /// uninstall without asking, installing an update from a link).
    static var ciActions: Bool { UserDefaults.standard.bool(forKey: "ciTestActions") }

    static func canHandle(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "kongprism" && actions.contains(url.host?.lowercased() ?? "")
    }

    @MainActor
    static func handle(_ url: URL, controller: AppController) {
        let argument = url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? ""
        AppLog.write("链接动作：\(url.absoluteString)")
        switch url.host?.lowercased() ?? "" {
        case "connect": if !controller.status.isRunning { controller.connect() }
        case "disconnect": if controller.status.isRunning || controller.status == .starting { controller.disconnect() }
        case "toggle": controller.toggle()
        case "mode":
            let mode = ["rule": "Rule", "global": "Global", "direct": "Direct"][argument.lowercased()]
            if let mode { controller.setMode(mode) }
        case "node":
            guard !argument.isEmpty else { return }
            Task {
                // The snapshot is only fetched when the menu opens; it may be empty or stale here.
                await controller.refreshSnapshot()
                // Exact name first, then the first node whose name contains it ("香港" → first Hong Kong node).
                let members = controller.snapshot.groups[Groups.select]?.all ?? []
                if let target = members.first(where: { $0 == argument }) ?? members.first(where: { $0.localizedCaseInsensitiveContains(argument) }) {
                    controller.select(target, in: Groups.select)
                } else {
                    AppLog.write("链接动作：没有找到节点“\(argument)”")
                }
            }
        case "test": controller.testAllNodes()
        case "update":
            // ?auto=1 behaves like the scheduled update (few identities, pauses after a refusal).
            let automatic = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "auto" && $0.value == "1" } ?? false
            Task { await controller.updateAllProfiles(automatic: automatic) }
        case "whatsnew": WhatsNewNotice.show()
        case "tun": controller.setTunMode(argument.lowercased() == "on", ask: !ciActions)
        case "uninstall":
            // Always asks first — except on a CI machine that opted in (a web page cannot set that default).
            Uninstaller.run(controller: controller, ask: !ciActions)
        case "export", "import", "install-update":
            // File paths and installing from a link are for CI only.
            guard ciActions else { AppLog.write("链接动作 \(url.host ?? "") 只用于测试，已忽略"); return }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let path = query.first { $0.name == "path" }?.value ?? ""
            switch url.host?.lowercased() {
            case "export":
                try? BackupActions.export(controller: controller, to: URL(fileURLWithPath: path), includeLinks: query.contains { $0.name == "links" && $0.value == "1" })
            case "import":
                if let backup = try? SettingsBackup.read(URL(fileURLWithPath: path)) { BackupActions.apply(backup, controller: controller) }
            default:
                Task {
                    await controller.checkAppUpdate(userInitiated: true)
                    controller.installAppUpdate()
                }
            }
        case "recover": Task { await controller.recoverConnections(reason: "链接动作", force: true) }
        case "sync":
            controller.pullFromICloud()
            controller.pushToICloud()
        case "reload": controller.reloadIfRunning()
        case "menu":
            Task {
                guard let dump = dumpMenu else { return }
                let text = await dump()
                try? text.write(to: Paths.support.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
            }
        case "settings":
            let key = argument.lowercased()
            let tab = SettingsTab(rawValue: key) ?? SettingsTab.allCases.first { $0.title.hasPrefix(argument) && !argument.isEmpty } ?? .general
            openSettings?(tab)
        case "report": ProblemReport.create(controller: controller)
        case "onboarding": Onboarding.show()
        case "rules": Task { await controller.updateRules(userInitiated: true) }
        default: break
        }
    }
}
