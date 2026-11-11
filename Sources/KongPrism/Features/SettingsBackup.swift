import AppKit
import KongPrismCore
import UniformTypeIdentifiers

/// 设置导出 / 导入: a JSON file for moving to another Mac, a reinstall or a backup, without iCloud.
struct SettingsBackup: Codable {
    struct ProfileEntry: Codable {
        var id: UUID
        var name: String
        /// nil when exported without links.
        var url: String?
        var userAgent: String?
        /// Pasted (local) profiles carry their nodes; subscriptions are downloaded again.
        var nodes: [ProxyNode]?
    }

    var format = 1
    var exportedAt: Date
    var appVersion: String
    var includesLinks: Bool
    var profiles: [ProfileEntry]
    var selectedProfileID: UUID?
    var mode: String
    var directDomains: [String]
    var proxyDomains: [String]
    var serviceTargets: [String: String]
    var favoriteNodes: [String]
    var customRuleSets: [CustomRuleSetSetting]
    var networkRules: [NetworkRule]
    var blockAds: Bool
    var smartIPRouting: Bool
    var regionGroups: Bool
    var remoteDNS: String
    var localDNS: String
    var maxMultiplier: Double
    var avoidFailingNodes: Bool
    var siteChecks: [String]

    @MainActor
    init(controller: AppController, includeLinks: Bool) {
        let s = controller.settings
        exportedAt = Date()
        appVersion = AppUpdater.version
        includesLinks = includeLinks
        profiles = controller.profiles.map { profile in
            ProfileEntry(id: profile.id, name: profile.name, url: includeLinks ? profile.url : nil, userAgent: profile.userAgent,
                         nodes: profile.isRemote ? nil : Store.loadNodes(profile.id))
        }
        selectedProfileID = s.selectedProfileID
        mode = s.mode
        directDomains = s.directDomains
        proxyDomains = s.proxyDomains
        serviceTargets = s.serviceTargets
        favoriteNodes = s.favoriteNodes
        // Download state is per Mac; the files are fetched again after importing.
        customRuleSets = s.customRuleSets.map { var set = $0; set.fileExtension = nil; set.ruleCount = nil; set.updatedAt = nil; set.lastError = nil; return set }
        networkRules = s.networkRules
        blockAds = s.blockAds
        smartIPRouting = s.smartIPRouting
        regionGroups = s.regionGroups
        remoteDNS = s.remoteDNS
        localDNS = s.localDNS
        maxMultiplier = s.maxMultiplier
        avoidFailingNodes = s.avoidFailingNodes
        siteChecks = s.siteChecks
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func read(_ url: URL) throws -> SettingsBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(SettingsBackup.self, from: Data(contentsOf: url)) }
        catch { throw CoreManager.CoreError("不是 KongPrism 导出的设置文件") }
    }
}

@MainActor
enum BackupActions {
    // MARK: Export

    static func export(controller: AppController, to url: URL, includeLinks: Bool) throws {
        let data = try SettingsBackup.encoder.encode(SettingsBackup(controller: controller, includeLinks: includeLinks))
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        AppLog.write("设置已导出（\(includeLinks ? "含" : "不含")订阅链接）")
    }

    static func exportInteractively(controller: AppController) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KongPrism-设置-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let links = NSButton(checkboxWithTitle: "包含订阅链接（链接里有账户令牌，请妥善保管这个文件）", target: nil, action: nil)
        links.state = .off
        panel.accessoryView = links
        panel.message = "导出订阅、分流规则、按服务分流、收藏、自定义规则集和网络规则"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(controller: controller, to: url, includeLinks: links.state == .on)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            controller.subscriptionTask = .failed("导出失败：\(error.localizedDescription)")
        }
    }

    // MARK: Import

    /// What importing would change, in words (shown before applying).
    static func summary(_ backup: SettingsBackup, controller: AppController) -> [String] {
        let known = Set(controller.profiles.map(\.id))
        let knownURLs = Set(controller.profiles.compactMap(\.url))
        let newProfiles = backup.profiles.filter { !known.contains($0.id) && !($0.url.map(knownURLs.contains) ?? false) }
        let unusable = newProfiles.filter { $0.url == nil && $0.nodes == nil }
        var lines = ["来自 KongPrism \(backup.appVersion)，导出于 \(backup.exportedAt.formatted(date: .abbreviated, time: .shortened))"]
        lines.append("订阅：新增 \(newProfiles.count - unusable.count) 个（已有的不会改动）"
                     + (unusable.isEmpty ? "" : "；\(unusable.count) 个导出时没有带链接，会跳过"))
        lines.append("自定义直连 \(backup.directDomains.count) 条、总是走代理 \(backup.proxyDomains.count) 条（替换现有）")
        lines.append("自定义规则集 \(backup.customRuleSets.count) 个、网络规则 \(backup.networkRules.count) 条、收藏 \(backup.favoriteNodes.count) 个（替换现有）")
        lines.append("按服务分流、广告拦截、DNS、倍率上限等设置（替换现有；端口不变）")
        return lines
    }

    static func apply(_ backup: SettingsBackup, controller: AppController) {
        let known = Set(controller.profiles.map(\.id))
        let knownURLs = Set(controller.profiles.compactMap(\.url))
        var added: [UUID] = []
        for entry in backup.profiles where !known.contains(entry.id) && !(entry.url.map(knownURLs.contains) ?? false) {
            guard entry.url != nil || entry.nodes != nil else { continue }
            var profile = Profile(id: entry.id, name: entry.name)
            profile.url = entry.url
            profile.userAgent = entry.userAgent
            controller.addImportedProfile(profile, nodes: entry.nodes)
            added.append(entry.id)
        }
        var s = controller.settings
        s.mode = backup.mode
        s.directDomains = backup.directDomains
        s.proxyDomains = backup.proxyDomains
        s.serviceTargets = backup.serviceTargets
        s.favoriteNodes = backup.favoriteNodes
        let downloaded = Dictionary(uniqueKeysWithValues: s.customRuleSets.map { ($0.id, $0) })
        s.customRuleSets = backup.customRuleSets.map { entry in
            // Keep this Mac's downloaded file when the same rule-set is already here.
            guard let local = downloaded[entry.id], local.url == entry.url else { return entry }
            var merged = entry
            merged.fileExtension = local.fileExtension
            merged.ruleCount = local.ruleCount
            merged.updatedAt = local.updatedAt
            return merged
        }
        s.networkRules = backup.networkRules
        s.blockAds = backup.blockAds
        s.smartIPRouting = backup.smartIPRouting
        s.regionGroups = backup.regionGroups
        s.remoteDNS = backup.remoteDNS
        s.localDNS = backup.localDNS
        s.maxMultiplier = backup.maxMultiplier
        s.avoidFailingNodes = backup.avoidFailingNodes
        s.siteChecks = backup.siteChecks
        if controller.selectedProfile == nil, let selected = backup.selectedProfileID { s.selectedProfileID = selected }
        controller.settings = s
        controller.rulesChanged()
        AppLog.write("已导入设置：新增 \(added.count) 个订阅")
        controller.subscriptionTask = .done("已导入设置（新增 \(added.count) 个订阅）")
        Task {
            if s.customRuleSets.contains(where: { $0.fileExtension == nil }) { _ = await controller.refreshCustomRuleSets() }
            for id in added { try? await controller.updateProfile(id) }
            controller.reloadIfRunning()
        }
    }

    static func importInteractively(controller: AppController) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "选择 KongPrism 导出的设置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try SettingsBackup.read(url)
            let alert = NSAlert()
            alert.messageText = "导入这些设置？"
            alert.informativeText = summary(backup, controller: controller).joined(separator: "\n")
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            apply(backup, controller: controller)
        } catch {
            controller.subscriptionTask = .failed("导入失败：\(error.localizedDescription)")
        }
    }
}
