import Foundation
import KongPrismCore

/// Where KongPrism keeps its files: ~/Library/Application Support/KongPrism.
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KongPrism", isDirectory: true)
    }()

    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var profiles: URL { support.appendingPathComponent("profiles.json") }
    static var profileNodes: URL { support.appendingPathComponent("profiles", isDirectory: true) }
    static var rules: URL { support.appendingPathComponent("rules", isDirectory: true) }
    static var core: URL { support.appendingPathComponent("core", isDirectory: true) }
    static var downloadedCore: URL { core.appendingPathComponent("sing-box") }
    static var previousCore: URL { core.appendingPathComponent("sing-box.previous") }
    static var runtime: URL { support.appendingPathComponent("runtime", isDirectory: true) }
    static var config: URL { runtime.appendingPathComponent("config.json") }
    static var cache: URL { runtime.appendingPathComponent("cache.db") }
    static var pidFile: URL { runtime.appendingPathComponent("sing-box.pid") }
    static var proxyBackup: URL { support.appendingPathComponent("system-proxy-backup.json") }
    static var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    static var coreLog: URL { logs.appendingPathComponent("core.log") }
    static var appLog: URL { logs.appendingPathComponent("app.log") }
    static var updates: URL { support.appendingPathComponent("updates", isDirectory: true) }

    static var bundledCore: URL? { Bundle.main.url(forAuxiliaryExecutable: "sing-box") }
    static var bundledRules: URL? { Bundle.main.resourceURL?.appendingPathComponent("rules", isDirectory: true) }

    static func prepare() {
        let fm = FileManager.default
        for directory in [support, profileNodes, rules, core, runtime, logs, updates] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Subscription links carry account tokens; keep the folder private.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    }
}

/// Keeps one previous generation of a log: past `limit` bytes, file → file.1.
enum LogRotation {
    static func previous(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".1") }

    static func rotate(_ url: URL, limit: Int) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit else { return }
        let old = previous(url)
        try? FileManager.default.removeItem(at: old)
        if (try? FileManager.default.moveItem(at: url, to: old)) == nil { try? FileManager.default.removeItem(at: url) }
    }
}

/// A small append-only log in logs/app.log (becomes app.log.1 past 1 MB).
enum AppLog {
    private static let queue = DispatchQueue(label: "KongPrism.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = Paths.appLog
            LogRotation.rotate(url, limit: 1_000_000)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                // The first lines of a fresh install come before Paths.prepare(): create the folder.
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var mixedPort = 7899
    var apiPort = 9099
    var apiSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var allowLAN = false
    var mode = "Rule"
    var blockAds = true
    var smartIPRouting = false
    var regionGroups = true
    var remoteDNS = "https://1.1.1.1/dns-query"
    var localDNS = "https://223.5.5.5/dns-query"
    var testURL = "https://www.gstatic.com/generate_204"
    var testIntervalMinutes = 10
    var logLevel = "warn"
    var setSystemProxy = true
    var connectOnLaunch = true
    var wasConnected = false
    var selectedProfileID: UUID?
    var mergeAllProfiles = false
    /// The user picked 直连 in 节点选择 themselves (otherwise a leftover 直连 is switched to 自动选择).
    var userChoseDirect = false
    var subscriptionIntervalHours = 12
    var autoUpdateRules = true
    var autoCheckAppUpdates = true
    var autoCheckCoreUpdates = true
    var githubToken = ""
    var directDomains: [String] = []
    var proxyDomains: [String] = []
    var rulesUpdatedAt: Date?
    /// 0.2 features
    var tunMode = false
    var showSpeed = false
    var hotKeyEnabled = true
    var autoFailover = true
    var iCloudSync = false
    /// When the custom rules last changed here (iCloud sync keeps the newer side).
    var rulesChangedAt: Date?
    var lastSyncRead: Date?
    /// 0.3 features
    var hideDeadNodes = false
    var backupProfileID: UUID?
    var networkRules: [NetworkRule] = []
    var networkAutomation = true
    var usageNotifications = true
    var notifiedWarnings: [String: Date] = [:]
    /// 0.4 features
    var autoInstallUpdates = false
    var pauseSpeedOnBattery = true
    var serviceTargets: [String: String] = [:]
    /// 0.5 features
    var favoriteNodes: [String] = []
    var customRuleSets: [CustomRuleSetSetting] = []
    var onboardingDone = false
    /// 0.6 features
    var avoidFailingNodes = true
    /// 0 = no limit; otherwise automatic groups skip nodes with a higher 流量倍率.
    var maxMultiplier: Double = 0
    /// 0.8: the GitHub token is in the keychain (githubToken is filled in after loading).
    var githubTokenInKeychain = false
    /// Bumped when a default changes for everyone (see the migration in init(from:)).
    var settingsVersion = AppSettings.currentVersion

    static let currentVersion = 2

    init() {}

    // Every field falls back to its default, so older settings files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        mixedPort = v(.mixedPort, d.mixedPort)
        apiPort = v(.apiPort, d.apiPort)
        apiSecret = v(.apiSecret, d.apiSecret)
        allowLAN = v(.allowLAN, d.allowLAN)
        mode = v(.mode, d.mode)
        blockAds = v(.blockAds, d.blockAds)
        smartIPRouting = v(.smartIPRouting, d.smartIPRouting)
        regionGroups = v(.regionGroups, d.regionGroups)
        remoteDNS = v(.remoteDNS, d.remoteDNS)
        localDNS = v(.localDNS, d.localDNS)
        testURL = v(.testURL, d.testURL)
        testIntervalMinutes = v(.testIntervalMinutes, d.testIntervalMinutes)
        logLevel = v(.logLevel, d.logLevel)
        setSystemProxy = v(.setSystemProxy, d.setSystemProxy)
        connectOnLaunch = v(.connectOnLaunch, d.connectOnLaunch)
        wasConnected = v(.wasConnected, d.wasConnected)
        selectedProfileID = try? c.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        mergeAllProfiles = v(.mergeAllProfiles, d.mergeAllProfiles)
        userChoseDirect = v(.userChoseDirect, d.userChoseDirect)
        subscriptionIntervalHours = v(.subscriptionIntervalHours, d.subscriptionIntervalHours)
        autoUpdateRules = v(.autoUpdateRules, d.autoUpdateRules)
        autoCheckAppUpdates = v(.autoCheckAppUpdates, d.autoCheckAppUpdates)
        autoCheckCoreUpdates = v(.autoCheckCoreUpdates, d.autoCheckCoreUpdates)
        githubToken = v(.githubToken, d.githubToken)
        directDomains = v(.directDomains, d.directDomains)
        proxyDomains = v(.proxyDomains, d.proxyDomains)
        rulesUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .rulesUpdatedAt)
        tunMode = v(.tunMode, d.tunMode)
        showSpeed = v(.showSpeed, d.showSpeed)
        hotKeyEnabled = v(.hotKeyEnabled, d.hotKeyEnabled)
        autoFailover = v(.autoFailover, d.autoFailover)
        iCloudSync = v(.iCloudSync, d.iCloudSync)
        rulesChangedAt = try? c.decodeIfPresent(Date.self, forKey: .rulesChangedAt)
        lastSyncRead = try? c.decodeIfPresent(Date.self, forKey: .lastSyncRead)
        hideDeadNodes = v(.hideDeadNodes, d.hideDeadNodes)
        backupProfileID = try? c.decodeIfPresent(UUID.self, forKey: .backupProfileID)
        networkRules = v(.networkRules, d.networkRules)
        networkAutomation = v(.networkAutomation, d.networkAutomation)
        usageNotifications = v(.usageNotifications, d.usageNotifications)
        notifiedWarnings = v(.notifiedWarnings, d.notifiedWarnings)
        autoInstallUpdates = v(.autoInstallUpdates, d.autoInstallUpdates)
        pauseSpeedOnBattery = v(.pauseSpeedOnBattery, d.pauseSpeedOnBattery)
        serviceTargets = v(.serviceTargets, d.serviceTargets)
        favoriteNodes = v(.favoriteNodes, d.favoriteNodes)
        customRuleSets = v(.customRuleSets, d.customRuleSets)
        onboardingDone = v(.onboardingDone, d.onboardingDone)
        avoidFailingNodes = v(.avoidFailingNodes, d.avoidFailingNodes)
        maxMultiplier = v(.maxMultiplier, d.maxMultiplier)
        githubTokenInKeychain = v(.githubTokenInKeychain, d.githubTokenInKeychain)
        let version = v(.settingsVersion, 1)
        // 0.1.0 resolved unknown domains through the domestic DNS and sent the IP to the
        // proxy, which broke sites with polluted answers; turn that off once for everyone.
        if version < 2 { smartIPRouting = false }
        settingsVersion = AppSettings.currentVersion
    }

    var coreOptions: CoreOptions {
        var options = CoreOptions()
        options.mixedPort = mixedPort
        options.allowLAN = allowLAN
        options.apiPort = apiPort
        options.apiSecret = apiSecret
        options.mode = mode
        options.blockAds = blockAds
        options.smartIPRouting = smartIPRouting
        options.regionGroups = regionGroups
        options.remoteDNS = remoteDNS
        options.localDNS = localDNS
        options.testURL = testURL
        options.testIntervalMinutes = testIntervalMinutes
        options.logLevel = logLevel
        options.logPath = Paths.coreLog.path
        options.rulesDirectory = Paths.rules.path
        options.cachePath = Paths.cache.path
        options.directDomains = directDomains
        options.proxyDomains = proxyDomains
        options.tun = tunMode
        options.serviceTargets = serviceTargets
        options.maxMultiplier = maxMultiplier > 0 ? maxMultiplier : nil
        // Only rule-sets that downloaded at least once (sing-box refuses a missing local file).
        options.customRuleSets = customRuleSets.compactMap { custom in
            guard custom.enabled, let set = custom.ruleSet,
                  FileManager.default.fileExists(atPath: Paths.rules.appendingPathComponent(set.file).path) else { return nil }
            return CustomRule(set: set, target: custom.target)
        }
        return options
    }
}

struct Profile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// nil for nodes pasted in by hand.
    var url: String?
    var userAgent: String?
    /// The User-Agent the provider last accepted (tried first next time).
    var workingUserAgent: String?
    var updatedAt: Date?
    var usage: SubscriptionUsage?
    var nodeCount = 0
    var format: String?
    var skipped = 0
    var lastError: String?
    /// When lastError happened (shown next to it, so an old error is recognisable).
    var lastErrorAt: Date?
    /// The link is in the keychain (0.8); `url` is filled in after loading.
    var urlInKeychain: Bool?
    /// Automatic updates wait until then after the provider refused (manual updates do not).
    var pausedUntil: Date?

    var isRemote: Bool { url != nil }
}

enum Store {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func nodesURL(_ id: UUID) -> URL { Paths.profileNodes.appendingPathComponent("\(id.uuidString).json") }
    static func loadNodes(_ id: UUID) -> [ProxyNode] { load([ProxyNode].self, from: nodesURL(id)) ?? [] }
    static func saveNodes(_ nodes: [ProxyNode], for id: UUID) { save(nodes, to: nodesURL(id)) }
}
