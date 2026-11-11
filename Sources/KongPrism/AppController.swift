import AppKit
import ServiceManagement
import KongPrismCore

/// The app's state and actions. UI (menu bar, settings window) only reads and calls this.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    enum Job: Equatable {
        case idle
        case working(String, Double?)
        case done(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published var settings: AppSettings { didSet { if settings != oldValue { Store.save(settings, to: Paths.settings) } } }
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var snapshot = ClashAPI.Snapshot()
    @Published private(set) var droppedNodes: [String] = []
    @Published private(set) var coreVersion: String?
    @Published private(set) var latestCore: String?
    @Published private(set) var appRelease: AppUpdater.Found?
    @Published var appTask: Job = .idle
    @Published var coreTask: Job = .idle
    @Published var rulesTask: Job = .idle
    @Published var subscriptionTask: Job = .idle
    @Published private(set) var testing = false

    let core = CoreManager()
    private var restartAttempts = 0
    private var scheduler: Scheduler?

    private init() {
        Paths.prepare()
        settings = Store.load(AppSettings.self, from: Paths.settings) ?? AppSettings()
        profiles = Store.load([Profile].self, from: Paths.profiles) ?? []
        Store.save(settings, to: Paths.settings)
        core.onUnexpectedExit = { [weak self] status in self?.coreExited(status) }
    }

    var api: ClashAPI { ClashAPI(port: settings.apiPort, secret: settings.apiSecret) }

    var selectedProfile: Profile? {
        profiles.first { $0.id == settings.selectedProfileID } ?? profiles.first
    }

    /// For downloads that should prefer the tunnel (GitHub): proxy first, then direct.
    var proxyFirst: [Net.Route] { status.isRunning ? [.viaProxy(port: settings.mixedPort), .direct] : [.direct] }
    /// For subscriptions (often reachable directly, some refuse proxy IPs): direct first.
    var directFirst: [Net.Route] { status.isRunning ? [.direct, .viaProxy(port: settings.mixedPort)] : [.direct] }

    // MARK: Launch / quit

    func launch() {
        RuleUpdater.installBundledIfMissing()
        CoreManager.killStale()
        // A crash may have left the system proxy pointing at a port nobody serves.
        if SystemProxy.hasBackup || SystemProxy.isPointing(to: settings.mixedPort) {
            try? SystemProxy.restore(port: settings.mixedPort)
        }
        Swift.Task { coreVersion = await Shell.background { [core] in core.currentVersion } }
        if settings.connectOnLaunch && settings.wasConnected && selectedProfile != nil { connect() }
        scheduler = Scheduler(controller: self)
        scheduler?.start()
        // The scheduler's first run comes one interval after launch; catch up on stale subscriptions now.
        let interval = TimeInterval(max(1, settings.subscriptionIntervalHours)) * 3600
        Swift.Task {
            try? await Swift.Task.sleep(nanoseconds: 15_000_000_000)
            for profile in profiles where profile.isRemote && Date().timeIntervalSince(profile.updatedAt ?? .distantPast) > interval {
                try? await updateProfile(profile.id)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Swift.Task { @MainActor in self?.didWake() }
        }
    }

    /// Called from applicationWillTerminate: put the network back the way it was.
    func shutdown() {
        if SystemProxy.hasBackup { try? SystemProxy.restore(port: settings.mixedPort) }
        core.stop()
    }

    func rescheduleBackgroundWork() { scheduler?.restart() }

    private func didWake() {
        // sing-box follows network changes itself; only repair a core that died while asleep.
        if settings.wasConnected, !core.isRunning, status != .starting { connect() }
    }

    // MARK: Connecting

    func toggle() { status.isRunning || status == .starting ? disconnect() : connect() }

    func connect() {
        guard status != .starting else { return }
        status = .starting
        restartAttempts = 0
        let nodes = activeNodes()
        let options = settings.coreOptions
        let setProxy = settings.setSystemProxy
        let port = settings.mixedPort
        let apiPort = settings.apiPort
        let core = core
        Swift.Task {
            let outcome: Result<CoreManager.Prepared, Error> = await Shell.background {
                Result {
                    for (name, value) in [("代理端口", port), ("控制端口", apiPort)] where !CoreManager.isPortFree(value) {
                        throw CoreManager.CoreError("\(name) \(value) 已被占用（可能 KongBabel、Clash 等仍在运行），请退出它们或在设置里换一个端口")
                    }
                    let prepared = try core.prepare(nodes: nodes, options: options)
                    try core.start()
                    return prepared
                }
            }
            switch outcome {
            case .failure(let error):
                fail(error.localizedDescription)
                return
            case .success(let prepared):
                droppedNodes = prepared.dropped
            }
            guard await api.waitUntilReady() else {
                core.stop()
                fail("内核启动后没有响应，请查看日志（设置 › 关于 › 打开日志）")
                return
            }
            if setProxy {
                let proxyResult: Result<Void, Error> = await Shell.background { Result { try SystemProxy.enable(port: port) } }
                if case .failure(let error) = proxyResult {
                    AppLog.write("设置系统代理失败：\(error.localizedDescription)")
                    core.stop()
                    fail("设置系统代理失败：\(error.localizedDescription)")
                    return
                }
            }
            status = .running
            settings.wasConnected = true
            await refreshSnapshot()
        }
    }

    func disconnect() {
        settings.wasConnected = false
        status = .stopped
        let port = settings.mixedPort
        let core = core
        Swift.Task {
            await Shell.background {
                if SystemProxy.hasBackup { try? SystemProxy.restore(port: port) }
                core.stop()
            }
        }
    }

    /// Rebuilds the config and restarts sing-box (after a subscription or setting change).
    func reloadIfRunning() {
        guard status.isRunning else { return }
        status = .stopped
        let core = core
        Swift.Task {
            await Shell.background { core.stop() }
            connect()
        }
    }

    private func fail(_ message: String) {
        AppLog.write("连接失败：\(message)")
        status = .failed(message)
    }

    private func coreExited(_ code: Int32) {
        guard status.isRunning else { return }
        restartAttempts += 1
        if restartAttempts <= 3 {
            AppLog.write("第 \(restartAttempts) 次自动重启内核")
            let core = core
            let delay = UInt64(restartAttempts) * 1_000_000_000
            Swift.Task {
                try? await Swift.Task.sleep(nanoseconds: delay)
                let result: Result<Void, Error> = await Shell.background { Result { try core.start() } }
                if case .failure(let error) = result { fail(error.localizedDescription) }
            }
        } else {
            // Do not leave the Mac pointing at a dead proxy.
            let port = settings.mixedPort
            Swift.Task { await Shell.background { try? SystemProxy.restore(port: port) } }
            fail("内核反复退出（状态 \(code)），已恢复系统代理。详情见日志。")
        }
    }

    // MARK: Nodes and modes

    func refreshSnapshot() async {
        guard status.isRunning, let snapshot = try? await api.snapshot() else { return }
        if snapshot != self.snapshot { self.snapshot = snapshot }
    }

    func select(_ name: String, in group: String) {
        Swift.Task {
            do {
                try await api.select(name, in: group)
                await refreshSnapshot()
            } catch {
                AppLog.write("切换节点失败：\(error.localizedDescription)")
            }
        }
    }

    func setMode(_ mode: String) {
        settings.mode = mode
        guard status.isRunning else { return }
        Swift.Task {
            try? await api.setMode(mode)
            await api.closeConnections()
        }
    }

    func testLatency() {
        guard status.isRunning, !testing else { return }
        testing = true
        Swift.Task {
            defer { testing = false }
            let group = snapshot.groups[Groups.auto] != nil ? Groups.auto : Groups.select
            _ = try? await api.testGroup(group, url: settings.testURL)
            await refreshSnapshot()
        }
    }

    func copyShellExports() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ShellExports.command(port: settings.mixedPort), forType: .string)
    }

    // MARK: Profiles

    private func saveProfiles() { Store.save(profiles, to: Paths.profiles) }

    /// Nodes of the selected profile, or of all profiles when merging is on.
    func activeNodes() -> [ProxyNode] {
        if settings.mergeAllProfiles, profiles.count > 1 {
            return NodeMerging.merge(profiles.map { (name: $0.name, nodes: Store.loadNodes($0.id)) })
        }
        return selectedProfile.map { Store.loadNodes($0.id) } ?? []
    }

    var knownSubscriptionURLs: Set<String> { Set(profiles.compactMap(\.url)) }

    /// Warning for the profile(s) in use: nearly out of traffic or about to expire.
    var usageWarning: String? {
        let inUse = settings.mergeAllProfiles ? profiles : (selectedProfile.map { [$0] } ?? [])
        for profile in inUse { if let warning = profile.usage?.warning() { return "\(profile.name)：\(warning)" } }
        return nil
    }

    func setMergeAllProfiles(_ merge: Bool) {
        settings.mergeAllProfiles = merge
        reloadIfRunning()
    }

    func selectProfile(_ id: UUID, connect connectNow: Bool = false) {
        let changed = settings.selectedProfileID != id || selectedProfile?.id != id || settings.mergeAllProfiles
        settings.selectedProfileID = id
        settings.mergeAllProfiles = false
        if status.isRunning {
            if changed { reloadIfRunning() }
        } else if connectNow {
            connect()
        }
    }

    /// Adds a subscription URL, or a pasted list of links / Clash YAML / sing-box JSON.
    @discardableResult
    func addProfile(input: String, name: String) async throws -> UUID {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = Profile(name: name.isEmpty ? "订阅 \(profiles.count + 1)" : name)
        if text.hasPrefix("http://") || text.hasPrefix("https://"), !text.contains("\n") {
            profile.url = text
            profiles.append(profile)
            saveProfiles()
            do {
                try await updateProfile(profile.id, nameIfDefault: name.isEmpty)
            } catch {
                // A subscription that cannot be downloaded is not kept.
                profiles.removeAll { $0.id == profile.id }
                saveProfiles()
                throw error
            }
        } else {
            let result = try SubscriptionParser.parse(Data(text.utf8))
            profile.name = name.isEmpty ? "本地节点 \(profiles.count + 1)" : name
            profile.nodeCount = result.nodes.count
            profile.format = result.format.rawValue
            profile.skipped = result.skipped
            profile.updatedAt = Date()
            Store.saveNodes(result.nodes, for: profile.id)
            profiles.append(profile)
            saveProfiles()
        }
        if profiles.count == 1 || settings.selectedProfileID == nil { selectProfile(profile.id) }
        return profile.id
    }

    func importFromClipboard() { Importer.importClipboard(controller: self) }

    func renameProfile(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        profiles[index].name = name
        saveProfiles()
    }

    func setProfileURL(_ id: UUID, url: String, userAgent: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].url = url.isEmpty ? nil : url
        profiles[index].userAgent = userAgent.isEmpty ? nil : userAgent
        saveProfiles()
    }

    func deleteProfile(_ id: UUID) {
        let wasSelected = selectedProfile?.id == id
        profiles.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Store.nodesURL(id))
        saveProfiles()
        if wasSelected {
            settings.selectedProfileID = profiles.first?.id
            if profiles.isEmpty { disconnect() } else { reloadIfRunning() }
        }
    }

    func updateProfile(_ id: UUID, nameIfDefault: Bool = false) async throws {
        guard let profile = profiles.first(where: { $0.id == id }), let url = profile.url else { return }
        subscriptionTask = .working("正在更新 \(profile.name)…", nil)
        do {
            let fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: profile.userAgent, routes: directFirst)
            let changed = Store.loadNodes(id) != fetched.result.nodes
            Store.saveNodes(fetched.result.nodes, for: id)
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].nodeCount = fetched.result.nodes.count
                profiles[index].format = fetched.result.format.rawValue
                profiles[index].skipped = fetched.result.skipped
                profiles[index].usage = fetched.usage ?? profiles[index].usage
                profiles[index].updatedAt = Date()
                profiles[index].lastError = nil
                if nameIfDefault, let name = fetched.suggestedName, !name.isEmpty { profiles[index].name = name }
            }
            saveProfiles()
            var message = "\(profile.name)：\(fetched.result.nodes.count) 个节点"
            if fetched.result.skipped > 0 { message += "，跳过 \(fetched.result.skipped) 个不支持的" }
            subscriptionTask = .done(message)
            // Restart the core only when the nodes really changed.
            if changed, settings.mergeAllProfiles || selectedProfile?.id == id { reloadIfRunning() }
        } catch {
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].lastError = error.localizedDescription
                saveProfiles()
            }
            subscriptionTask = .failed("\(profile.name) 更新失败：\(error.localizedDescription)")
            throw error
        }
    }

    func updateAllProfiles() async {
        for profile in profiles where profile.isRemote { try? await updateProfile(profile.id) }
    }

    // MARK: Updates

    func checkAppUpdate(userInitiated: Bool) async {
        if userInitiated { appTask = .working("正在检查 KongPrism 更新…", nil) }
        do {
            let found = try await AppUpdater.check(token: settings.githubToken, routes: proxyFirst)
            if AppUpdater.isNewer(found.release) {
                appRelease = found
                appTask = .done("有新版本 \(found.release.version)")
            } else {
                appRelease = nil
                if userInitiated { appTask = .done("已是最新版本（\(AppUpdater.version)）") }
            }
        } catch {
            if userInitiated {
                let hint = settings.githubToken.isEmpty ? "（仓库为私有时需要在下方填写 GitHub 令牌）" : ""
                appTask = .failed("检查失败：\(error.localizedDescription)\(hint)")
            }
        }
    }

    func installAppUpdate() {
        guard let found = appRelease else { return }
        appTask = .working("正在下载 KongPrism \(found.release.version)…", 0)
        Swift.Task {
            do {
                try await AppUpdater.install(found, token: settings.githubToken, routes: proxyFirst, progress: { value in
                    Swift.Task { @MainActor in AppController.shared.appTask = .working("正在下载 KongPrism \(found.release.version)…", value) }
                }, beforeQuit: { [weak self] in
                    // "wasConnected" stays set, so the new version reconnects on launch.
                    self?.shutdown()
                })
            } catch {
                appTask = .failed("更新失败：\(error.localizedDescription)")
            }
        }
    }

    func checkCoreUpdate(userInitiated: Bool) async {
        if userInitiated { coreTask = .working("正在检查 sing-box 更新…", nil) }
        coreVersion = await Shell.background { [core] in core.currentVersion }
        do {
            let latest = try await CoreUpdater.latestVersion(routes: proxyFirst)
            if let current = coreVersion, !Versions.isNewer(latest, than: current) {
                latestCore = nil
                if userInitiated { coreTask = .done("sing-box 已是最新（\(current)）") }
            } else {
                latestCore = latest
                coreTask = .done("sing-box 有新版本 \(latest)")
            }
        } catch {
            if userInitiated { coreTask = .failed("检查失败：\(error.localizedDescription)") }
        }
    }

    func installCoreUpdate() {
        guard let version = latestCore else { return }
        coreTask = .working("正在下载 sing-box \(version)…", 0)
        let core = core
        Swift.Task {
            do {
                try await CoreUpdater.install(version: version, routes: proxyFirst, core: core) { value in
                    Swift.Task { @MainActor in AppController.shared.coreTask = .working("正在下载 sing-box \(version)…", value) }
                }
                latestCore = nil
                coreVersion = await Shell.background { core.currentVersion }
                coreTask = .done("已更新到 sing-box \(version)")
                reloadIfRunning()
            } catch {
                coreTask = .failed("内核更新失败：\(error.localizedDescription)")
            }
        }
    }

    func rollbackCore() {
        do {
            try CoreUpdater.rollback()
            coreTask = .done("已回退到上一个内核")
        } catch {
            coreTask = .failed(error.localizedDescription)
        }
        Swift.Task {
            coreVersion = await Shell.background { [core] in core.currentVersion }
            reloadIfRunning()
        }
    }

    func useBundledCore() {
        CoreUpdater.useBundled()
        coreTask = .done("已改用应用内置的内核")
        Swift.Task {
            coreVersion = await Shell.background { [core] in core.currentVersion }
            reloadIfRunning()
        }
    }

    func updateRules(userInitiated: Bool) async {
        rulesTask = .working("正在更新分流规则…", nil)
        do {
            let changed = try await RuleUpdater.update(routes: proxyFirst)
            settings.rulesUpdatedAt = Date()
            rulesTask = .done(changed > 0 ? "规则已更新（\(changed) 个文件有变化）" : "规则已是最新")
        } catch {
            rulesTask = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                AppLog.write("登录项设置失败：\(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
