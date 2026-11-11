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
    @Published var settings: AppSettings { didSet { if settings != oldValue { Store.save(Secrets.forDisk(settings), to: Paths.settings) } } }
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var snapshot = ClashAPI.Snapshot()
    @Published private(set) var droppedNodes: [String] = []
    /// Nodes loaded from the subscription / put into the running config, for 诊断连接.
    @Published private(set) var loadedNodeCount = 0
    @Published private(set) var configNodeCount = 0
    @Published private(set) var coreVersion: String?
    @Published private(set) var latestCore: String?
    @Published private(set) var appRelease: AppUpdater.Found?
    @Published var appTask: Job = .idle
    @Published var coreTask: Job = .idle
    @Published var rulesTask: Job = .idle
    @Published var subscriptionTask: Job = .idle
    @Published private(set) var testing = false
    /// Exit IP / location, looked up when the menu opens.
    @Published private(set) var exitInfo: ExitInfo?
    /// "HK 01 连不上…" when a hand-picked node fails.
    @Published private(set) var nodeNotice: String?
    @Published private(set) var speed: (up: Int64, down: Int64) = (0, 0)
    @Published private(set) var hotKeyRegistered = false

    /// 0.3
    @Published private(set) var nodeProtocols: [String: String] = [:]
    @Published private(set) var backupTags: [String] = []
    @Published private(set) var networkCurrent: NetworkFingerprint?
    /// "已按网络“家里”切到直连模式"
    @Published private(set) var networkNotice: String?
    private let networkWatcher = NetworkWatcher()
    private var appliedNetworkRule: NetworkRule?
    private var modeBeforeNetworkRule: String?
    private var stoppedByNetworkRule = false
    private var switchedToBackup = false

    /// 0.4
    @Published private(set) var stats = TrafficStats.load()
    @Published private(set) var stagedUpdate: (version: String, app: URL)?

    /// 0.6: nodes left out of the automatic groups until the date (自动避开连不上的节点).
    @Published private(set) var avoidedNodes: [String: Date] = [:]
    private var lastRecovery = Date.distantPast
    private var reloadTask: Task<Void, Never>?
    /// 0.9: whether the running config uses the battery test interval; the AI check port, if any.
    private(set) var appliedPowerSaving = false
    private(set) var aiCheckPort: Int?
    func setAvoidedNodes(_ nodes: [String: Date]) { avoidedNodes = nodes }
    var lastRecoveryDate: Date { lastRecovery }
    func markRecovery() { lastRecovery = Date() }
    func showNodeNotice(_ text: String) { nodeNotice = text }

    private var exitFetchedAt: Date?
    private var exitKey = ""
    private var nodeFailures: [String: Int] = [:]
    private let traffic = TrafficMonitor()

    let core = CoreManager()
    private var restartAttempts = 0
    private var scheduler: Scheduler?

    private init() {
        Paths.prepare()
        settings = Secrets.restore(Store.load(AppSettings.self, from: Paths.settings) ?? AppSettings())
        profiles = Secrets.restore(Store.load([Profile].self, from: Paths.profiles) ?? [])
        // Also moves links and the token of older versions out of the files (0.8).
        Store.save(Secrets.forDisk(settings), to: Paths.settings)
        if !profiles.isEmpty { Store.save(Secrets.forDisk(profiles), to: Paths.profiles) }
        core.onUnexpectedExit = { [weak self] status in self?.coreExited(status) }
    }

    var api: ClashAPI { ClashAPI(port: settings.apiPort, secret: settings.apiSecret) }

    var selectedProfile: Profile? {
        profiles.first { $0.id == settings.selectedProfileID } ?? profiles.first
    }

    /// For downloads that should prefer the tunnel (GitHub): proxy first, then direct.
    var proxyFirst: [Net.Route] { status.isRunning ? [.viaProxy(port: settings.mixedPort), .direct] : [.direct] + borrowedProxy }
    /// For subscriptions (often reachable directly, some refuse proxy IPs): direct first.
    var directFirst: [Net.Route] { status.isRunning ? [.direct, .viaProxy(port: settings.mixedPort)] : [.direct] + borrowedProxy }
    /// When KongPrism is off but another client set a system proxy, downloads may try it too
    /// (a provider's subscription domain is often blocked for direct connections).
    private var borrowedProxy: [Net.Route] {
        SystemProxy.hasAnyProxy && !SystemProxy.isPointing(to: settings.mixedPort) ? [.system] : []
    }

    /// Why connecting now would leave the user without any node, if it would.
    var missingNodesReason: String? {
        if settings.mergeAllProfiles, profiles.contains(where: { $0.nodeCount > 0 }) { return nil }
        guard let profile = selectedProfile else { return "还没有订阅，请先添加订阅" }
        guard profile.nodeCount == 0 else { return nil }
        if let error = profile.lastError { return "订阅“\(profile.name)”没有节点：\(error)" }
        return "订阅“\(profile.name)”里没有节点，请在 设置 › 订阅 里更新它"
    }

    // MARK: Launch / quit

    func launch() {
        RuleUpdater.installBundledIfMissing()
        // 0.6: providers without the usage header — read expiry / remaining traffic from the stored information entries.
        var filled = false
        for index in profiles.indices where profiles[index].usage == nil {
            if let usage = SubscriptionUsage.fromInformational(Store.loadNodes(profiles[index].id).map(\.name)) {
                profiles[index].usage = usage
                filled = true
            }
        }
        if filled { saveProfiles() }
        CoreManager.killStale()
        core.tunMode = settings.tunMode
        // An enhanced-mode core left running by a crash keeps routing everything; stop it unless we reconnect now.
        if TunHelper.isRunning && !(settings.connectOnLaunch && settings.wasConnected) { TunHelper.stop() }
        // A crash may have left the system proxy pointing at a port nobody serves.
        if SystemProxy.hasBackup || SystemProxy.isPointing(to: settings.mixedPort) {
            try? SystemProxy.restore(port: settings.mixedPort)
        }
        Task { coreVersion = await Shell.background { [core] in core.currentVersion } }
        if settings.connectOnLaunch && settings.wasConnected && selectedProfile != nil { connect() }
        scheduler = Scheduler(controller: self)
        scheduler?.start()
        // The scheduler's first run comes one interval after launch; catch up on stale subscriptions now.
        let interval = TimeInterval(max(1, settings.subscriptionIntervalHours)) * 3600
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            for profile in profiles where profile.isRemote && Date().timeIntervalSince(profile.updatedAt ?? .distantPast) > interval {
                try? await updateProfile(profile.id, automatic: true)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
        traffic.onUpdate = { [weak self] up, down in self?.speed = (up, down) }
        PowerState.shared.onChange = { [weak self] in
            guard let self else { return }
            self.updateSpeedMonitor()
            self.objectWillChange.send()
            // Plugged in / unplugged: apply the other test interval (one reload, about 0.3 s).
            let saving = self.settings.batterySaverTesting && PowerState.shared.shouldSave
            if self.status.isRunning, saving != self.appliedPowerSaving {
                AppLog.write(saving ? "用电池 / 低电量模式：测速间隔放宽" : "接上电源：测速间隔恢复")
                self.reloadIfRunning()
            }
        }
        networkWatcher.onChange = { [weak self] fingerprint in self?.networkChanged(fingerprint) }
        networkWatcher.start()
        networkWatcher.scheduleCheck(after: 0.5)
        applyHotKey()
        pullFromICloud()
    }

    func applyHotKey() {
        if settings.hotKeyEnabled {
            hotKeyRegistered = HotKey.shared.register { AppController.shared.toggle() }
            if !hotKeyRegistered { AppLog.write("快捷键 \(HotKey.display) 已被其他应用占用") }
        } else {
            HotKey.shared.unregister()
            hotKeyRegistered = false
        }
    }

    /// The speed display streams only while it is switched on and the core runs.
    func updateSpeedMonitor() {
        let paused = settings.pauseSpeedOnBattery && PowerState.shared.shouldSave
        if settings.showSpeed && status.isRunning && !paused {
            if !traffic.isRunning { traffic.start(api: api) }
        } else {
            traffic.stop()
            speed = (0, 0)
        }
    }

    /// Called from applicationWillTerminate: put the network back the way it was.
    func shutdown() {
        sampleTrafficBlocking()
        if SystemProxy.hasBackup { try? SystemProxy.restore(port: settings.mixedPort) }
        core.stop()
        TunHelper.stop()
    }

    /// Quitting with an update downloaded and verified: it is swapped in after KongPrism exits.
    func installStagedUpdateOnQuit() {
        guard let staged = stagedUpdate else { return }
        stagedUpdate = nil
        AppUpdater.installStagedOnQuit(staged.app, version: staged.version)
    }

    func rescheduleBackgroundWork() { scheduler?.restart() }

    private func didWake() {
        // sing-box follows network changes itself; only repair a core that died while asleep.
        if settings.wasConnected, !core.isRunning, status != .starting { connect() }
        exitFetchedAt = nil
        pullFromICloud()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await recoverConnections(reason: "唤醒")
            await checkSelectedNode()
        }
    }

    // MARK: Connecting

    /// From the menu or the hot key: offers to quit other proxy clients before connecting.
    func toggle() {
        if status.isRunning || status == .starting {
            disconnect()
            return
        }
        Task {
            guard await OtherClients.resolveBeforeConnecting() else { return }
            connect()
        }
    }

    func connect() {
        guard status != .starting else { return }
        // Connecting with no node would send everything direct and look "connected" while foreign sites fail.
        if let reason = missingNodesReason {
            fail(reason)
            return
        }
        status = .starting
        restartAttempts = 0
        let nodes = activeNodes()
        let backup = backupNodes()
        var options = settings.coreOptions
        options.avoidNodes = Set(avoidedNodes.filter { $0.value > Date() }.keys)
        // 0.9: test less often on battery / Low Power Mode.
        let saving = settings.batterySaverTesting && PowerState.shared.shouldSave
        options.testIntervalMinutes = PowerPolicy.testInterval(base: settings.testIntervalMinutes, saving: saving)
        appliedPowerSaving = saving
        // 0.9: a local-only inbound that leaves like AI traffic (诊断 › AI 服务出口).
        let checkPort = settings.apiPort + 1
        options.aiCheckPort = settings.aiExitCheck && checkPort != settings.mixedPort && CoreManager.isPortFree(checkPort) ? checkPort : nil
        aiCheckPort = options.aiCheckPort
        let tun = settings.tunMode
        // In enhanced mode the TUN interface carries the traffic; the system proxy stays untouched.
        let setProxy = settings.setSystemProxy && !tun
        let port = settings.mixedPort
        let apiPort = settings.apiPort
        let core = core
        if tun && !TunHelper.isInstalled {
            fail("增强模式还没有安装辅助程序：请在 设置 › 网络 里重新打开“增强模式”")
            return
        }
        Task {
            let outcome: Result<CoreManager.Prepared, Error> = await Shell.background {
                Result {
                    core.stop()
                    core.tunMode = tun
                    if tun {
                        if SystemProxy.hasBackup { try? SystemProxy.restore(port: port) }
                        try core.syncTunCoreIfNeeded()
                    }
                    try core.freePort(port, label: "代理端口")
                    try core.freePort(apiPort, label: "控制端口")
                    let prepared = try core.prepare(nodes: nodes, backupNodes: backup, options: options)
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
                loadedNodeCount = nodes.count + backup.count
                configNodeCount = prepared.built.nodeTags.count
                nodeProtocols = prepared.built.nodeProtocols
                backupTags = prepared.built.backupTags
                switchedToBackup = false
                if prepared.built.nodeTags.isEmpty {
                    core.stop()
                    fail(nodes.isEmpty ? "读不到订阅的节点文件，请在 设置 › 订阅 里右键“立即更新”"
                                       : "订阅的 \(nodes.count) 个节点都没能放进配置（被内核拒绝 \(prepared.dropped.count) 个）。请用“诊断连接”复制报告")
                    return
                }
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
            stats.coreRestarted()
            exitFetchedAt = nil
            nodeNotice = nil
            updateSpeedMonitor()
            await refreshSnapshot()
            // The core remembers the last choice; "直连" may be left over from a time without nodes.
            if snapshot.groups[Groups.select]?.now == Groups.direct, !settings.userChoseDirect, snapshot.groups[Groups.auto] != nil {
                select(Groups.auto, in: Groups.select)
            }
        }
    }

    func disconnect(keepWasConnected: Bool = false) {
        if !keepWasConnected { settings.wasConnected = false }
        status = .stopped
        exitInfo = nil
        nodeNotice = nil
        updateSpeedMonitor()
        let port = settings.mixedPort
        let core = core
        Task {
            await sampleTraffic(force: true)
            await Shell.background {
                if SystemProxy.hasBackup { try? SystemProxy.restore(port: port) }
                core.stop()
            }
        }
    }

    /// Rebuilds the config and restarts sing-box (after a subscription or setting change).
    /// Points the system proxy at KongPrism again (another client may have changed it).
    func reapplySystemProxy() {
        guard status.isRunning else { return }
        let port = settings.mixedPort
        Task {
            let result: Result<Void, Error> = await Shell.background { Result { try SystemProxy.enable(port: port) } }
            if case .failure(let error) = result { fail("设置系统代理失败：\(error.localizedDescription)") }
        }
    }

    /// Restarts the core with the current settings. Changes made within 1.2 seconds of each other
    /// are applied with one restart (each restart drops every connection for a moment).
    func reloadIfRunning(immediately: Bool = false) {
        guard status.isRunning else { return }
        reloadTask?.cancel()
        reloadTask = Task {
            if !immediately {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return }
            }
            guard status.isRunning else { return }
            reloadTask = nil
            let core = core
            let started = Date()
            await sampleTraffic(force: true)
            status = .stopped
            await Shell.background { core.stop() }
            connect()
            AppLog.write("内核重载（停止用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms）")
        }
    }

    private func fail(_ message: String) {
        AppLog.write("连接失败：\(message)")
        status = .failed(message)
        updateSpeedMonitor()
    }

    /// The enhanced-mode core runs as root, outside KongPrism's process; notice when it is gone.
    func verifyCoreAlive() {
        guard status.isRunning, !core.isRunning else { return }
        fail(settings.tunMode ? "增强模式的内核已退出，请重新开启代理" : "内核已退出，请重新开启代理")
    }

    private func coreExited(_ code: Int32) {
        guard status.isRunning else { return }
        restartAttempts += 1
        if restartAttempts <= 3 {
            AppLog.write("第 \(restartAttempts) 次自动重启内核")
            let core = core
            let delay = UInt64(restartAttempts) * 1_000_000_000
            Task {
                try? await Task.sleep(nanoseconds: delay)
                let result: Result<Void, Error> = await Shell.background { Result { try core.start() } }
                if case .failure(let error) = result { fail(error.localizedDescription) }
            }
        } else {
            // Do not leave the Mac pointing at a dead proxy.
            let port = settings.mixedPort
            Task { await Shell.background { try? SystemProxy.restore(port: port) } }
            fail("内核反复退出（状态 \(code)），已恢复系统代理。详情见日志。")
        }
    }

    // MARK: Nodes and modes

    func refreshSnapshot() async {
        guard status.isRunning, let snapshot = try? await api.snapshot() else { return }
        if snapshot != self.snapshot { self.snapshot = snapshot }
    }

    func select(_ name: String, in group: String) {
        if group == Groups.select { settings.userChoseDirect = (name == Groups.direct) }
        nodeFailures[name] = 0
        nodeNotice = nil
        exitFetchedAt = nil
        Task {
            do {
                try await api.select(name, in: group)
                AppLog.write("\(group) → \(name)")
                await refreshSnapshot()
            } catch {
                AppLog.write("切换节点失败：\(error.localizedDescription)")
            }
        }
    }

    func setMode(_ mode: String) {
        settings.mode = mode
        exitFetchedAt = nil
        guard status.isRunning else { return }
        Task {
            try? await api.setMode(mode)
            await api.closeConnections()
        }
    }

    func testLatency() { testAllNodes() }

    /// Tests every node: the 自动选择 group (primary) and the backup group, in parallel inside sing-box.
    func testAllNodes() {
        guard status.isRunning, !testing else { return }
        testing = true
        Task {
            defer { testing = false }
            let groups = [Groups.auto, Groups.backup].filter { snapshot.groups[$0] != nil }
            for group in groups.isEmpty ? [Groups.select] : groups {
                _ = try? await api.testGroup(group, url: settings.testURL)
            }
            await refreshSnapshot()
        }
    }

    /// Nodes of the backup subscription, when one is set (not while merging).
    func backupNodes() -> [ProxyNode] {
        guard !settings.mergeAllProfiles, let id = settings.backupProfileID, id != selectedProfile?.id,
              profiles.contains(where: { $0.id == id }) else { return [] }
        return Store.loadNodes(id)
    }

    func setBackupProfile(_ id: UUID?) {
        settings.backupProfileID = id
        reloadIfRunning()
    }

    /// Failover between subscriptions: when every primary node fails, 节点选择 moves to 🛟 备用订阅;
    /// when the primary recovers, back to 自动选择. Checked on menu open, wake, network changes
    /// and the 15-minute system-scheduled check.
    func checkFailover() async {
        guard status.isRunning, !backupTags.isEmpty else { return }
        await refreshSnapshot()
        let now = snapshot.groups[Groups.select]?.now
        guard now == Groups.auto || (now == Groups.backup && switchedToBackup) else { return }
        let primary = (try? await api.testGroup(Groups.auto, url: settings.testURL, timeoutMs: 5000)) ?? [:]
        let primaryAlive = primary.values.contains { $0 > 0 }
        if now == Groups.auto, !primaryAlive {
            AppLog.write("主用订阅全部不通，切到备用订阅")
            try? await api.select(Groups.backup, in: Groups.select)
            switchedToBackup = true
            nodeNotice = "主用订阅的节点全部不通，已切到备用订阅"
        } else if now == Groups.backup, primaryAlive {
            AppLog.write("主用订阅已恢复，切回自动选择")
            try? await api.select(Groups.auto, in: Groups.select)
            switchedToBackup = false
            nodeNotice = "主用订阅已恢复，已切回自动选择"
        }
        exitFetchedAt = nil
        await refreshSnapshot()
    }

    // MARK: Network rules

    /// Applies the rule for the network just joined, and undoes the previous one when leaving it.
    private func networkChanged(_ fingerprint: NetworkFingerprint?) {
        networkCurrent = fingerprint
        AppLog.write("网络变化：\(fingerprint.map { "\($0.label)（\($0.routerMAC)）" } ?? "无网络")")
        exitFetchedAt = nil
        Task {
            if fingerprint != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await recoverConnections(reason: "网络切换")
            }
            await checkSelectedNode()
            await checkFailover()
        }
        guard settings.networkAutomation else { return }
        let rule = fingerprint.flatMap { current in settings.networkRules.first { $0.routerMAC == current.routerMAC } }
        guard rule != appliedNetworkRule else { return }
        // Leaving a ruled network: put things back unless the new network has its own rule.
        if appliedNetworkRule != nil {
            if rule == nil, let mode = modeBeforeNetworkRule { setMode(mode) }
            if rule == nil || rule?.action.mode == nil { modeBeforeNetworkRule = nil }
            if stoppedByNetworkRule, rule?.action != .off {
                stoppedByNetworkRule = false
                connect()
            }
            networkNotice = nil
        }
        appliedNetworkRule = rule
        guard let rule else { return }
        if let mode = rule.action.mode {
            if modeBeforeNetworkRule == nil { modeBeforeNetworkRule = settings.mode }
            if settings.mode != mode { setMode(mode) }
            networkNotice = "已按网络“\(rule.name)”切到\(rule.action.title)"
        } else if status.isRunning || status == .starting {
            stoppedByNetworkRule = true
            disconnect(keepWasConnected: true)
            networkNotice = "已按网络“\(rule.name)”关闭代理，离开后自动恢复"
        }
        AppLog.write(networkNotice ?? "")
    }

    /// Saves a rule for the network the Mac is on now.
    func addRuleForCurrentNetwork(name: String, action: NetworkRule.Action) {
        guard let current = networkCurrent else { return }
        settings.networkRules.removeAll { $0.routerMAC == current.routerMAC }
        settings.networkRules.append(NetworkRule(name: name.isEmpty ? current.label : name, routerMAC: current.routerMAC, action: action))
        appliedNetworkRule = nil
        networkChanged(current)
    }

    func removeNetworkRule(_ id: UUID) {
        settings.networkRules.removeAll { $0.id == id }
        if appliedNetworkRule?.id == id {
            let current = networkCurrent
            networkChanged(nil)
            networkChanged(current)
        }
    }

    /// Tests a hand-picked node (groups test themselves). After two failures in a row it switches
    /// back to 自动选择 when 自动切换 is on, otherwise shows a notice. Runs only on menu open, wake
    /// and a rare background check, never on a timer of its own.
    func checkSelectedNode() async {
        guard status.isRunning else { return }
        await refreshSnapshot()
        guard let current = snapshot.groups[Groups.select]?.now, current != Groups.direct,
              snapshot.groups[current] == nil, snapshot.groups[Groups.auto] != nil else {
            nodeNotice = nil
            return
        }
        let delay = (try? await api.testProxy(current, url: settings.testURL, timeoutMs: 5000)) ?? 0
        if delay > 0 {
            nodeFailures[current] = 0
            nodeNotice = nil
            return
        }
        let failures = (nodeFailures[current] ?? 0) + 1
        nodeFailures[current] = failures
        if failures >= 2 && settings.autoFailover {
            AppLog.write("节点 \(current) 连续 \(failures) 次测试失败，切回自动选择")
            try? await api.select(Groups.auto, in: Groups.select)
            settings.userChoseDirect = false
            nodeFailures[current] = 0
            exitFetchedAt = nil
            await refreshSnapshot()
            nodeNotice = "\(current) 连不上，已切回自动选择"
        } else {
            nodeNotice = "\(current) 刚才测试连不上"
        }
    }

    func refreshExitInfoIfNeeded() async {
        guard status.isRunning else { exitInfo = nil; return }
        let key = "\(settings.mode)|\(snapshot.groups[Groups.select]?.now ?? "")|\(snapshot.groups[snapshot.groups[Groups.select]?.now ?? ""]?.now ?? "")"
        if key == exitKey, let fetched = exitFetchedAt, Date().timeIntervalSince(fetched) < 300 { return }
        exitKey = key
        exitFetchedAt = Date()
        exitInfo = await ExitLookup.fetch(port: settings.mixedPort)
    }

    // MARK: Traffic statistics

    private var lastSample = Date.distantPast

    /// Adds the core's counters to the statistics (menu open, hourly, before the core stops).
    func sampleTraffic(force: Bool = false) async {
        guard status.isRunning || force, force || Date().timeIntervalSince(lastSample) > 60 else { return }
        guard let totals = try? await api.connections() else { return }
        lastSample = Date()
        stats.record(totalUp: totals.upload, totalDown: totals.download, profile: currentProfileLabel)
        stats.save()
    }

    /// Used while quitting, when there is no time for async work: waits at most a second.
    private func sampleTrafficBlocking() {
        guard status.isRunning else { return }
        final class Box: @unchecked Sendable { var value: (Int64, Int64)? }
        let api = api
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let totals = try? await api.connections() { box.value = (totals.upload, totals.download) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 1) == .success, let result = box.value else { return }
        stats.record(totalUp: result.0, totalDown: result.1, profile: currentProfileLabel)
        stats.save()
    }

    private var currentProfileLabel: String {
        settings.mergeAllProfiles ? "全部订阅（合并）" : (selectedProfile?.name ?? "未知")
    }

    func clearStats() {
        let up = stats.lastUp, down = stats.lastDown
        stats = TrafficStats()
        stats.lastUp = up
        stats.lastDown = down
        stats.save()
    }

    // MARK: Service routing

    func setServiceTarget(_ service: Service, _ target: String) {
        if target == Service.follow { settings.serviceTargets[service.rawValue] = nil } else { settings.serviceTargets[service.rawValue] = target }
        rulesChanged()
        reloadIfRunning()
    }

    // MARK: Automatic updates

    /// With automatic installation on: download and verify in the background (only on mains
    /// power, not in Low Power Mode), then install when the Mac has been idle for five minutes
    /// or when KongPrism quits, whichever comes first.
    func stageUpdateIfWanted() async {
        guard settings.autoInstallUpdates, let found = appRelease, stagedUpdate?.version != found.release.version,
              !PowerState.shared.shouldSave else { return }
        do {
            let app = try await AppUpdater.stage(found, token: settings.githubToken, routes: proxyFirst) { _ in }
            stagedUpdate = (found.release.version, app)
            appTask = .done("\(found.release.version) 已下载，将在电脑空闲时或退出 KongPrism 时安装")
            AppLog.write("已下载 \(found.release.version)，等待空闲时安装")
            installStagedUpdateIfIdle()
        } catch {
            AppLog.write("后台下载更新失败：\(error.localizedDescription)")
        }
    }

    func installStagedUpdateIfIdle() {
        guard let staged = stagedUpdate, PowerState.idleSeconds >= 300, status != .starting else { return }
        AppLog.write("电脑空闲，安装 \(staged.version)")
        stagedUpdate = nil
        try? AppUpdater.installStaged(staged.app, version: staged.version) { shutdown() }
    }

    func copyShellExports() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ShellExports.command(port: settings.mixedPort), forType: .string)
    }

    // MARK: Profiles

    private func saveProfiles() {
        Store.save(Secrets.forDisk(profiles), to: Paths.profiles)
        pushToICloud()
    }

    /// Custom rules changed here (for iCloud sync, the newer side wins).
    func rulesChanged() {
        settings.rulesChangedAt = Date()
        pushToICloud()
    }

    // MARK: iCloud

    private var pushTask: Task<Void, Never>?

    /// Writes subscriptions and rules to iCloud Drive (debounced).
    func pushToICloud() {
        guard settings.iCloudSync, ICloudSync.isAvailable else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let entries = profiles.map { profile in
                ICloudSync.Payload.Entry(id: profile.id, name: profile.name, url: profile.url, userAgent: profile.userAgent,
                                         workingUserAgent: profile.workingUserAgent,
                                         nodes: profile.isRemote ? nil : Store.loadNodes(profile.id))
            }
            var payload = ICloudSync.Payload(updatedAt: Date(), device: ICloudSync.deviceName, profiles: entries,
                                             directDomains: settings.directDomains, proxyDomains: settings.proxyDomains,
                                             rulesChangedAt: settings.rulesChangedAt)
            payload.favoriteNodes = settings.favoriteNodes
            payload.serviceTargets = settings.serviceTargets
            payload.customRuleSets = settings.customRuleSets.map {
                ICloudSync.Payload.RuleSetEntry(id: $0.id, name: $0.name, url: $0.url, target: $0.target, enabled: $0.enabled)
            }
            do {
                try ICloudSync.write(payload)
                settings.lastSyncRead = Date()
            } catch {
                AppLog.write("写入 iCloud 云盘失败：\(error.localizedDescription)")
            }
        }
    }

    /// Adds subscriptions found in iCloud Drive and takes newer custom rules. Never deletes.
    func pullFromICloud() {
        guard settings.iCloudSync, let payload = ICloudSync.read() else { return }
        if let last = settings.lastSyncRead, payload.updatedAt <= last { return }
        settings.lastSyncRead = Date()
        var added: [UUID] = []
        for entry in payload.profiles {
            let known = profiles.contains { $0.id == entry.id || (entry.url != nil && $0.url == entry.url) }
            guard !known else { continue }
            var profile = Profile(id: entry.id, name: entry.name)
            profile.url = entry.url
            profile.userAgent = entry.userAgent
            profile.workingUserAgent = entry.workingUserAgent
            if let nodes = entry.nodes {
                Store.saveNodes(nodes, for: profile.id)
                profile.nodeCount = nodes.count
                profile.updatedAt = Date()
            }
            profiles.append(profile)
            added.append(profile.id)
        }
        if let remoteRules = payload.rulesChangedAt, remoteRules > (settings.rulesChangedAt ?? .distantPast) {
            settings.directDomains = payload.directDomains
            settings.proxyDomains = payload.proxyDomains
            if let favorites = payload.favoriteNodes { settings.favoriteNodes = favorites }
            if let targets = payload.serviceTargets { settings.serviceTargets = targets }
            var needsDownload = false
            if let remoteSets = payload.customRuleSets {
                // Same ids keep their downloaded files; new ones are downloaded; missing ones go.
                let local = Dictionary(uniqueKeysWithValues: settings.customRuleSets.map { ($0.id, $0) })
                let merged: [CustomRuleSetSetting] = remoteSets.map { entry in
                    var item = local[entry.id] ?? CustomRuleSetSetting(name: entry.name, url: entry.url, target: entry.target)
                    item.id = entry.id
                    if item.url != entry.url { item.fileExtension = nil; item.ruleCount = nil }
                    item.name = entry.name
                    item.url = entry.url
                    item.target = entry.target
                    item.enabled = entry.enabled
                    if item.fileExtension == nil { needsDownload = true }
                    return item
                }
                for gone in settings.customRuleSets where !remoteSets.contains(where: { $0.id == gone.id }) {
                    CustomRuleSets.removeFiles(of: gone)
                }
                settings.customRuleSets = merged
            }
            settings.rulesChangedAt = remoteRules
            if needsDownload {
                Task { _ = await refreshCustomRuleSets(); reloadIfRunning() }
            } else {
                reloadIfRunning()
            }
        }
        guard !added.isEmpty else { return }
        Store.save(Secrets.forDisk(profiles), to: Paths.profiles)
        AppLog.write("从 iCloud 云盘（\(payload.device)）同步了 \(added.count) 个订阅")
        subscriptionTask = .done("从 iCloud 云盘同步了 \(added.count) 个订阅")
        Task { for id in added { try? await updateProfile(id) } }
    }

    // MARK: Enhanced mode

    /// Turns enhanced mode (TUN) on or off; the first time it installs the helper (administrator password).
    func setTunMode(_ on: Bool, ask: Bool = true) {
        guard on != settings.tunMode else { return }
        if on && !TunHelper.isInstalled {
            guard let binary = core.binary() else { coreTask = .failed("找不到内核"); return }
            if ask {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "安装增强模式（TUN）？"
            alert.informativeText = "增强模式会接管所有程序的流量（包括终端和不遵守系统代理的软件），需要以管理员身份安装一个辅助程序，之后开关不再需要密码。\n\n它比系统代理模式更耗电一些；随时可以在这里关闭或移除。"
            alert.addButton(withTitle: "安装")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { objectWillChange.send(); return }
            }
            do {
                try TunHelper.install(core: binary)
            } catch {
                coreTask = .failed("安装失败：\(error.localizedDescription)")
                objectWillChange.send()
                return
            }
        }
        let wasRunning = status.isRunning
        if wasRunning {
            // Stop the current core (and system proxy) before switching modes.
            let port = settings.mixedPort
            let core = core
            status = .stopped
            Task {
                await Shell.background {
                    if SystemProxy.hasBackup { try? SystemProxy.restore(port: port) }
                    core.stop()
                }
                settings.tunMode = on
                connect()
            }
        } else {
            settings.tunMode = on
        }
    }

    func uninstallTunHelper() {
        do {
            if settings.tunMode { setTunMode(false) }
            try TunHelper.uninstall()
            coreTask = .done("已移除增强模式辅助程序")
        } catch {
            coreTask = .failed(error.localizedDescription)
        }
        objectWillChange.send()
    }

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
        Secrets.delete(Secrets.subscriptionAccount(id))
        try? FileManager.default.removeItem(at: Store.nodesURL(id))
        saveProfiles()
        if wasSelected {
            settings.selectedProfileID = profiles.first?.id
            if profiles.isEmpty { disconnect() } else { reloadIfRunning() }
        }
    }

    func updateProfile(_ id: UUID, nameIfDefault: Bool = false, automatic: Bool = false, isRetry: Bool = false) async throws {
        guard let profile = profiles.first(where: { $0.id == id }), let url = profile.url else { return }
        if automatic, let until = profile.pausedUntil, until > Date() { return }
        subscriptionTask = .working("正在更新 \(profile.name)…", nil)
        do {
            let fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: profile.userAgent, remembered: profile.workingUserAgent,
                                                              routes: directFirst, automatic: automatic)
            // Providers without the subscription-userinfo header often put it in an information entry.
            let usage = fetched.usage ?? SubscriptionUsage.fromInformational(fetched.result.nodes.map(\.name))
            let changed = Store.loadNodes(id) != fetched.result.nodes
            Store.saveNodes(fetched.result.nodes, for: id)
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].nodeCount = fetched.result.nodes.count
                profiles[index].format = fetched.result.format.rawValue
                profiles[index].skipped = fetched.result.skipped
                profiles[index].usage = usage ?? profiles[index].usage
                profiles[index].pausedUntil = nil
                profiles[index].updatedAt = Date()
                profiles[index].lastError = nil
                profiles[index].lastErrorAt = nil
                profiles[index].workingUserAgent = fetched.agent
                if nameIfDefault, let name = fetched.suggestedName, !name.isEmpty { profiles[index].name = name }
            }
            saveProfiles()
            if settings.usageNotifications, let warning = usage?.warning() {
                Notifier.notifyOnce(key: "\(id.uuidString)-\(warning)", title: "KongPrism：\(profile.name)", body: warning, settings: &settings)
            }
            var message = "\(profile.name)：\(fetched.result.nodes.count) 个节点"
            if fetched.result.skipped > 0 { message += "，跳过 \(fetched.result.skipped) 个不支持的" }
            subscriptionTask = .done(message)
            // Restart the core only when the nodes really changed.
            if changed, settings.mergeAllProfiles || selectedProfile?.id == id || settings.backupProfileID == id { reloadIfRunning() }
        } catch {
            let kind = Self.failureKind(error)
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].lastError = error.localizedDescription
                profiles[index].lastErrorAt = Date()
                if automatic, let refused = error as? SubscriptionFetcher.Refused {
                    // Wait as long as the server asked (Retry-After), otherwise three hours.
                    let wait = UpdatePause.duration(retryAfter: refused.retryAfter)
                    profiles[index].pausedUntil = Date().addingTimeInterval(wait)
                    AppLog.write("订阅“\(profile.name)”被拒绝，自动更新暂停 \(Int(wait / 60)) 分钟")
                }
                saveProfiles()
            }
            // A network hiccup (timeout, TLS, 5xx): one more try in ten minutes instead of waiting for
            // the next scheduled update (hours away). Only one retry per failure.
            if kind == .transient, !isRetry {
                // Hidden `subscriptionRetrySeconds` default: CI shortens the wait.
                let custom = UserDefaults.standard.double(forKey: "subscriptionRetrySeconds")
                let wait = custom > 0 ? custom : FailureKind.retryDelay
                AppLog.write("订阅“\(profile.name)”暂时连不上，\(wait >= 60 ? "\(Int(wait / 60)) 分钟" : "\(Int(wait)) 秒")后重试")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    try? await self?.updateProfile(id, automatic: true, isRetry: true)
                }
            }
            var message = "\(profile.name) 更新失败：\(error.localizedDescription)"
            if error is URLError, !status.isRunning {
                message += "。订阅域名可能在国内直连不通：可先开着其他代理软件（如 KongBabel）再点“立即更新”，KongPrism 会借用系统代理下载"
            }
            subscriptionTask = .failed(message)
            throw error
        }
    }

    /// Refused / transient / other (see FailureKind).
    static func failureKind(_ error: Error) -> FailureKind {
        if error is SubscriptionFetcher.Refused { return .refused }
        if let http = error as? Net.HTTPError { return FailureKind.classify(httpStatus: http.status) }
        if let url = error as? URLError { return FailureKind.classify(urlErrorCode: url.code.rawValue) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return FailureKind.classify(urlErrorCode: ns.code) }
        return .other
    }

    /// 设置导入: a profile from a backup file (pasted ones bring their nodes).
    func addImportedProfile(_ profile: Profile, nodes: [ProxyNode]?) {
        var profile = profile
        if let nodes {
            Store.saveNodes(nodes, for: profile.id)
            profile.nodeCount = nodes.count
            profile.updatedAt = Date()
        }
        profiles.append(profile)
        saveProfiles()
    }

    /// The subscription downloaded fine somewhere else (问题报告): an old error no longer applies.
    func markSubscriptionReachable(_ id: UUID, agent: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles[index].lastError != nil else { return }
        profiles[index].lastError = nil
        profiles[index].lastErrorAt = nil
        profiles[index].workingUserAgent = agent
        saveProfiles()
    }

    func updateAllProfiles(automatic: Bool = false) async {
        for profile in profiles where profile.isRemote { try? await updateProfile(profile.id, automatic: automatic) }
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
        Task {
            do {
                try await AppUpdater.install(found, token: settings.githubToken, routes: proxyFirst, progress: { value in
                    Task { @MainActor in AppController.shared.appTask = .working("正在下载 KongPrism \(found.release.version)…", value) }
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
        Task {
            do {
                try await CoreUpdater.install(version: version, routes: proxyFirst, core: core) { value in
                    Task { @MainActor in AppController.shared.coreTask = .working("正在下载 sing-box \(version)…", value) }
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
        Task {
            coreVersion = await Shell.background { [core] in core.currentVersion }
            reloadIfRunning()
        }
    }

    func useBundledCore() {
        CoreUpdater.useBundled()
        coreTask = .done("已改用应用内置的内核")
        Task {
            coreVersion = await Shell.background { [core] in core.currentVersion }
            reloadIfRunning()
        }
    }

    func updateRules(userInitiated: Bool) async {
        rulesTask = .working("正在更新分流规则…", nil)
        var builtIn: Result<Int, Error> = .success(0)
        do { builtIn = .success(try await RuleUpdater.update(routes: proxyFirst)) } catch { builtIn = .failure(error) }
        // Custom rule-sets come from other hosts; update them even when GitHub is unreachable.
        let custom = await refreshCustomRuleSets()
        switch builtIn {
        case .success(let changed):
            settings.rulesUpdatedAt = Date()
            let total = changed + custom.changed
            var text = total > 0 ? "规则已更新（\(total) 个文件有变化）" : "规则已是最新"
            if custom.failed > 0 { text += "；\(custom.failed) 个自定义规则集更新失败" }
            rulesTask = .done(text)
        case .failure(let error):
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
