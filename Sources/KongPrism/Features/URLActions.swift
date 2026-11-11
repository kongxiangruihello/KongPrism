import AppKit
import CoreWLAN
import Network
import UserNotifications
import KongPrismCore

// MARK: - 链接控制

/// kongprism://connect · disconnect · toggle · mode/rule|global|direct · node/<名称> · test · update
/// · settings/<订阅|节点|分流|网络|统计|常规|更新>（或 profiles/nodes/rules/network/stats/general/updates）· report · onboarding
/// For Shortcuts, KongSeek, scripts. Import links (kongprism://install-config?url=…) are handled by Importer.
enum URLActions {
    static let actions: Set<String> = ["connect", "disconnect", "toggle", "mode", "node", "test", "update", "settings", "report", "onboarding", "rules"]
    /// Set by the app delegate, which owns the settings window.
    @MainActor static var openSettings: ((SettingsTab) -> Void)?

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
        case "update": Task { await controller.updateAllProfiles() }
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
