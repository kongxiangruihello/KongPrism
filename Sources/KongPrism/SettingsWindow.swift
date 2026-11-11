import AppKit
import SwiftUI
import KongPrismCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case profiles, nodes, rules, network, stats, general, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profiles: return "订阅"
        case .nodes: return "节点"
        case .general: return "常规"
        case .rules: return "分流"
        case .network: return "网络"
        case .stats: return "统计"
        case .updates: return "更新与关于"
        }
    }
    var symbol: String {
        switch self {
        case .profiles: return "tray.full"
        case .nodes: return "point.3.connected.trianglepath.dotted"
        case .general: return "gearshape"
        case .rules: return "arrow.triangle.branch"
        case .network: return "network"
        case .stats: return "chart.bar"
        case .updates: return "arrow.down.circle"
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let selection = TabSelection()

    func show(_ tab: SettingsTab) {
        selection.tab = tab
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(selection: selection).environmentObject(AppController.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "KongPrism"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 680, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class TabSelection: ObservableObject {
    @Published var tab: SettingsTab = .profiles
}

struct SettingsView: View {
    @ObservedObject var selection: TabSelection
    @EnvironmentObject var controller: AppController

    var body: some View {
        TabView(selection: $selection.tab) {
            ProfilesView().tabItem { Label(SettingsTab.profiles.title, systemImage: SettingsTab.profiles.symbol) }.tag(SettingsTab.profiles)
            NodesView().tabItem { Label(SettingsTab.nodes.title, systemImage: SettingsTab.nodes.symbol) }.tag(SettingsTab.nodes)
            RulesView().tabItem { Label(SettingsTab.rules.title, systemImage: SettingsTab.rules.symbol) }.tag(SettingsTab.rules)
            NetworkSettingsView().tabItem { Label(SettingsTab.network.title, systemImage: SettingsTab.network.symbol) }.tag(SettingsTab.network)
            StatsView().tabItem { Label(SettingsTab.stats.title, systemImage: SettingsTab.stats.symbol) }.tag(SettingsTab.stats)
            GeneralView().tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            Form { UpdatesView(); AboutView() }.formStyle(.grouped)
                .tabItem { Label(SettingsTab.updates.title, systemImage: SettingsTab.updates.symbol) }.tag(SettingsTab.updates)
        }
        .padding()
        .frame(minWidth: 620, minHeight: 460)
    }
}

/// One line of status for a background job.
struct JobLine: View {
    let job: AppController.Job
    var body: some View {
        switch job {
        case .idle: EmptyView()
        case .working(let text, let progress):
            HStack {
                if let progress { ProgressView(value: progress).frame(width: 120) } else { ProgressView().controlSize(.small) }
                Text(text).foregroundStyle(.secondary)
            }
        case .done(let text): Label(text, systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

// MARK: - 订阅

struct ProfilesView: View {
    @EnvironmentObject var controller: AppController
    @State private var input = ""
    @State private var name = ""
    @State private var adding = false
    @State private var editing: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(controller.profiles) { profile in
                    ProfileRow(profile: profile, selected: controller.selectedProfile?.id == profile.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { controller.selectProfile(profile.id) }
                        .contextMenu {
                            Button("使用此订阅") { controller.selectProfile(profile.id) }
                            if profile.isRemote { Button("立即更新") { Task { try? await controller.updateProfile(profile.id) } } }
                            Button("编辑…") { editing = profile }
                            Divider()
                            Button("删除", role: .destructive) { controller.deleteProfile(profile.id) }
                        }
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if controller.profiles.isEmpty {
                    VStack(spacing: 6) {
                        Text("还没有订阅").font(.headline)
                        Text("在机场网页点“一键导入 Clash / sing-box”，或复制订阅地址后点下面的“从剪贴板导入”，\n也可以把配置文件、二维码图片拖到这里。")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary).padding()
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls {
                    if url.isFileURL { Importer.importFile(url, controller: controller) }
                    else if let profile = ImportSource.remoteProfile(fromImportLink: url.absoluteString) { Importer.addRemote(profile, controller: controller, confirm: false) }
                    else { Importer.addRemote(.init(url: url.absoluteString, name: nil), controller: controller, confirm: false) }
                }
                return !urls.isEmpty
            }
            HStack {
                Text("双击使用；右键可更新、编辑或删除；可拖入文件或链接。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.profiles.count > 1 {
                    Toggle("合并全部订阅", isOn: Binding(get: { controller.settings.mergeAllProfiles }, set: { controller.setMergeAllProfiles($0) }))
                        .help("把所有订阅的节点放在一起，统一自动选择和按地区分组")
                }
            }
            HStack {
                Button { Importer.importClipboard(controller: controller) } label: { Label("从剪贴板导入", systemImage: "doc.on.clipboard") }
                    .help("订阅地址、一键导入链接、节点链接、Clash/sing-box 配置，或二维码截图（⌃⇧⌘4 截到剪贴板）")
                Button { Importer.chooseFile(controller: controller) } label: { Label("从文件导入…", systemImage: "folder") }
                Spacer()
                Button("让网页“一键导入”打开 KongPrism") {
                    Task { controller.subscriptionTask = .done(await Importer.becomeDefaultHandler()) }
                }
                .help("把 clash:// 和 sing-box:// 链接的默认打开方式设为 KongPrism")
            }

            GroupBox("添加") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名称（可选）", text: $name)
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Text("订阅地址（https://…），或 ss:// vmess:// vless:// trojan:// hy2:// tuic:// anytls:// 链接，或 Clash / sing-box 配置")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("添加") { add() }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || adding)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(4)
            }
            HStack {
                JobLine(job: controller.subscriptionTask)
                Spacer()
                Picker("自动更新", selection: $controller.settings.subscriptionIntervalHours) {
                    Text("每 6 小时").tag(6)
                    Text("每 12 小时").tag(12)
                    Text("每天").tag(24)
                    Text("每 3 天").tag(72)
                }
                .frame(width: 200)
                .onChange(of: controller.settings.subscriptionIntervalHours) { _ in controller.rescheduleBackgroundWork() }
                Button("全部更新") { Task { await controller.updateAllProfiles() } }
            }
        }
        .sheet(item: $editing) { profile in ProfileEditor(profile: profile) }
        .onAppear(perform: prefillFromClipboard)
    }

    /// A copied subscription URL is filled in already, so adding it is one click.
    private func prefillFromClipboard() {
        guard input.isEmpty, let text = NSPasteboard.general.string(forType: .string),
              case .subscription(let profile)? = ImportSource.classify(clipboard: text, knownURLs: controller.knownSubscriptionURLs) else { return }
        input = profile.url
        name = profile.name ?? ""
    }

    private func add() {
        adding = true
        let text = input
        let title = name
        Task {
            do {
                let id = try await controller.addProfile(input: text, name: title)
                if controller.profiles.count == 1 { controller.selectProfile(id, connect: true) }
                input = ""
                name = ""
            } catch {
                controller.subscriptionTask = .failed("添加失败：\(error.localizedDescription)")
            }
            adding = false
        }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let selected: Bool

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).fontWeight(selected ? .semibold : .regular)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let usage = profile.usage { Text(usage.summary).font(.caption).foregroundStyle(.secondary) }
                if let error = profile.lastError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = ["\(profile.nodeCount) 个节点"]
        if let format = profile.format { parts.append(format) }
        if profile.skipped > 0 { parts.append("跳过 \(profile.skipped) 个") }
        if let date = profile.updatedAt { parts.append("更新于 " + date.formatted(date: .abbreviated, time: .shortened)) }
        if !profile.isRemote { parts.append("本地") }
        return parts.joined(separator: " · ")
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State private var name = ""
    @State private var url = ""
    @State private var userAgent = ""

    var body: some View {
        Form {
            TextField("名称", text: $name)
            if profile.isRemote {
                TextField("订阅地址", text: $url)
                TextField("User-Agent（留空自动）", text: $userAgent)
                Text("留空时依次尝试 Clash.Meta、sing-box、v2rayN 三种格式。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    controller.renameProfile(profile.id, to: name)
                    if profile.isRemote { controller.setProfileURL(profile.id, url: url, userAgent: userAgent) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear {
            name = profile.name
            url = profile.url ?? ""
            userAgent = profile.userAgent ?? ""
        }
    }
}

// MARK: - 常规

struct GeneralView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动打开 KongPrism", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.launchAtLogin = $0 }))
                Toggle("打开时恢复上次的连接状态", isOn: $controller.settings.connectOnLaunch)
            }
            Section("菜单栏与快捷键") {
                Toggle("全局快捷键 \(HotKey.display) 开关代理", isOn: $controller.settings.hotKeyEnabled)
                    .onChange(of: controller.settings.hotKeyEnabled) { _ in controller.applyHotKey() }
                if controller.settings.hotKeyEnabled && !controller.hotKeyRegistered {
                    Text("\(HotKey.display) 已被其他应用占用（例如 KongBabel）。").font(.caption).foregroundStyle(.orange)
                }
                Toggle("菜单栏显示网速", isOn: $controller.settings.showSpeed)
                    .onChange(of: controller.settings.showSpeed) { _ in controller.updateSpeedMonitor() }
                Text("每秒刷新一次，会多耗一点电；默认关闭。").font(.caption).foregroundStyle(.secondary)
                Toggle("使用电池或低电量模式时暂停网速显示", isOn: $controller.settings.pauseSpeedOnBattery)
                    .onChange(of: controller.settings.pauseSpeedOnBattery) { _ in controller.updateSpeedMonitor() }
            }
            Section("提醒与自动处理") {
                Toggle("手选的节点连不上时，自动切回“自动选择”", isOn: $controller.settings.autoFailover)
                Toggle("订阅快到期或流量快用完时发系统通知", isOn: $controller.settings.usageNotifications)
            }
            Section("iCloud 云盘同步") {
                Toggle("在多台 Mac 之间同步订阅和自定义规则", isOn: $controller.settings.iCloudSync)
                    .disabled(!ICloudSync.isAvailable)
                    .onChange(of: controller.settings.iCloudSync) { on in
                        if on { controller.pullFromICloud(); controller.pushToICloud() }
                    }
                Text(ICloudSync.isAvailable
                     ? "保存在 iCloud 云盘 › KongPrism（含订阅链接，不含端口和令牌）。只增不删：在一台 Mac 上删除的订阅，不会从其他 Mac 上删除。"
                     : "这台 Mac 没有开启 iCloud 云盘（系统设置 › Apple 账户 › iCloud）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct NetworkSettingsView: View {
    @EnvironmentObject var controller: AppController
    @State private var mixedPort = ""
    @State private var apiPort = ""

    var body: some View {
        Form {
            Section("系统代理") {
                Toggle("开启代理时设置系统代理", isOn: $controller.settings.setSystemProxy)
                    .disabled(controller.settings.tunMode)
                Text("关闭后只运行内核，可在浏览器插件或终端里手动指向 127.0.0.1:\(controller.settings.mixedPort)。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("按网络自动切换") {
                NetworkRulesView()
            }
            Section("增强模式（TUN）") {
                Toggle("接管所有程序的流量", isOn: Binding(get: { controller.settings.tunMode }, set: { controller.setTunMode($0) }))
                Text("让终端、命令行工具和不遵守系统代理的软件也走代理。首次开启需要管理员密码安装辅助程序；比系统代理模式更耗电，平时用浏览器和普通软件不必开启。")
                    .font(.caption).foregroundStyle(.secondary)
                if TunHelper.isInstalled {
                    HStack {
                        Text("辅助程序已安装").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("移除辅助程序") { controller.uninstallTunHelper() }
                    }
                }
            }
            Section("端口") {
                HStack {
                    TextField("代理端口（HTTP + SOCKS5）", text: $mixedPort).frame(width: 260)
                    TextField("控制端口", text: $apiPort).frame(width: 160)
                    Button("应用") { applyPorts() }
                }
                Toggle("允许局域网设备使用（监听 0.0.0.0）", isOn: $controller.settings.allowLAN)
                    .onChange(of: controller.settings.allowLAN) { _ in controller.reloadIfRunning() }
                if controller.settings.allowLAN { LANShareView() }
            }
            Section("DNS") {
                TextField("国外域名 DNS（经代理）", text: $controller.settings.remoteDNS)
                TextField("国内 / 其余域名 DNS（直连）", text: $controller.settings.localDNS)
                Text("支持 https://、tls://、quic://、h3:// 或纯 IP。修改后重新开启代理生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("测速") {
                TextField("测速地址", text: $controller.settings.testURL)
                Stepper("自动选择每 \(controller.settings.testIntervalMinutes) 分钟测一次（仅在使用时）",
                        value: $controller.settings.testIntervalMinutes, in: 3...60)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mixedPort = String(controller.settings.mixedPort)
            apiPort = String(controller.settings.apiPort)
        }
    }

    private func applyPorts() {
        guard let mixed = Int(mixedPort), let api = Int(apiPort), (1024...65535).contains(mixed), (1024...65535).contains(api), mixed != api else {
            controller.subscriptionTask = .failed("端口需在 1024–65535 之间且互不相同")
            return
        }
        let wasRunning = controller.status.isRunning
        if wasRunning { controller.disconnect() }
        controller.settings.mixedPort = mixed
        controller.settings.apiPort = api
        if wasRunning { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppController.shared.connect() } }
    }
}

// MARK: - 分流

struct RulesView: View {
    @EnvironmentObject var controller: AppController
    @State private var direct = ""
    @State private var proxy = ""

    var body: some View {
        Form {
            Section("这个网站走哪条线？") {
                RouteLookupView()
            }
            Section("按服务分流") {
                ServiceRoutingSection()
            }
            Section("规则") {
                Toggle("拦截广告域名（geosite-category-ads-all）", isOn: $controller.settings.blockAds)
                Toggle("未知域名按 IP 归属分流（国内 IP 直连）", isOn: $controller.settings.smartIPRouting)
                Text("开启后，列表外的域名会先经代理 DNS 解析，国内 IP 直连、其余把 IP 交给节点。一般不必开启。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("按地区自动分组（香港、日本、美国…）", isOn: $controller.settings.regionGroups)
                Text("顺序：局域网直连 → 自定义域名 → 自定义规则集 → 国内域名直连 → 国外域名走代理 →（可选）国内 IP 直连 → 其余走代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义（每行一个域名后缀，如 example.com）") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("总是直连").font(.caption)
                        TextEditor(text: $direct).font(.system(.body, design: .monospaced)).frame(height: 110)
                    }
                    VStack(alignment: .leading) {
                        Text("总是走代理").font(.caption)
                        TextEditor(text: $proxy).font(.system(.body, design: .monospaced)).frame(height: 110)
                    }
                }
            }
            Section("自定义远程规则集") {
                CustomRuleSetsSection()
            }
            Section("规则集") {
                HStack {
                    Text("上次更新：\(controller.settings.rulesUpdatedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "使用内置版本")")
                    Spacer()
                    Button("立即更新") { Task { await controller.updateRules(userInitiated: true) } }
                }
                Toggle("每周自动更新规则集", isOn: $controller.settings.autoUpdateRules)
                JobLine(job: controller.rulesTask)
            }
            HStack {
                Spacer()
                Button("保存并应用") {
                    controller.settings.directDomains = lines(direct)
                    controller.settings.proxyDomains = lines(proxy)
                    controller.rulesChanged()
                    controller.reloadIfRunning()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            direct = controller.settings.directDomains.joined(separator: "\n")
            proxy = controller.settings.proxyDomains.joined(separator: "\n")
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

// MARK: - 更新

struct UpdatesView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Group {
            Section("KongPrism") {
                HStack {
                    Text("当前版本 \(AppUpdater.version)（\(AppUpdater.build)）")
                    Spacer()
                    if let found = controller.appRelease {
                        Button("下载并安装 \(found.release.version)") { controller.installAppUpdate() }.buttonStyle(.borderedProminent)
                        Button("在浏览器中下载") { NSWorkspace.shared.open(AppUpdater.releasesPage) }
                    }
                    Button("检查更新") { Task { await controller.checkAppUpdate(userInitiated: true) } }
                }
                if let notes = controller.appRelease?.release.notes, !notes.isEmpty {
                    Text(notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                JobLine(job: controller.appTask)
                if AppUpdater.isTranslocatedOrOutsideApplications {
                    Text("KongPrism 不在“应用程序”文件夹里，更新会安装到 /Applications/KongPrism.app。").font(.caption).foregroundStyle(.orange)
                }
                Toggle("每天自动检查", isOn: $controller.settings.autoCheckAppUpdates)
                Toggle("自动下载并安装新版本", isOn: $controller.settings.autoInstallUpdates)
                Text("只在接通电源、未开低电量模式时下载；下载并校验后，在电脑空闲 5 分钟或退出 KongPrism 时安装。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("GitHub 令牌（可选）") {
                    SecureField("仓库公开时不用填", text: $controller.settings.githubToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Text("更新包从 GitHub Releases 下载，校验 SHA-256 和签名后替换，并在重启后自动恢复连接。下载优先走代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("sing-box 内核") {
                HStack {
                    Text("当前内核 \(controller.coreVersion ?? "未知")")
                    Spacer()
                    if let latest = controller.latestCore {
                        Button("更新到 \(latest)") { controller.installCoreUpdate() }.buttonStyle(.borderedProminent)
                    }
                    Button("检查更新") { Task { await controller.checkCoreUpdate(userInitiated: true) } }
                }
                JobLine(job: controller.coreTask)
                Toggle("每天自动检查", isOn: $controller.settings.autoCheckCoreUpdates)
                HStack {
                    Button("回退到上一个内核") { controller.rollbackCore() }
                        .disabled(!FileManager.default.fileExists(atPath: Paths.previousCore.path))
                    Button("改用应用内置内核") { controller.useBundledCore() }
                        .disabled(!FileManager.default.fileExists(atPath: Paths.downloadedCore.path))
                }
                Text("新内核会先用当前配置做一次检查，通过后才替换；不通过则保持原内核。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text("KongPrism").font(.title2.bold())
                        Text("版本 \(AppUpdater.version) · sing-box \(controller.coreVersion ?? "?")").foregroundStyle(.secondary)
                        Text("一束光进来，按规则分成几路出去。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("省电设计") {
                Text("""
                • 默认用系统代理而非 TUN：只有走代理的应用流量经过内核，CPU 占用最低；增强模式按需开启。
                • 节点测速只在分组被使用时进行（idle_timeout），不用时不测。
                • 菜单只在打开时向内核取数据，后台无轮询、无计时器；订阅、规则、更新检查交给 macOS 统一调度（NSBackgroundActivityScheduler），低电量时自动推迟。
                • 内核日志级别 warn，不经管道读取；规则集为本地二进制文件，改动后内核自动重载。
                • 用电池或低电量模式时：暂停网速显示、不下载更新；流量统计只在打开菜单、每小时一次和关闭代理时记录。
                """).font(.callout)
            }
            Section("文件") {
                HStack {
                    Button("打开日志文件夹") { NSWorkspace.shared.open(Paths.logs) }
                    Button("打开数据文件夹") { NSWorkspace.shared.open(Paths.support) }
                    Button("复制终端代理命令") { controller.copyShellExports() }
                    Button("诊断连接…") { Diagnostics.show(controller: controller) }
                    Button("导出脱敏订阅样本…") { Diagnostics.exportSample(controller: controller) }
                    Button("生成问题报告") { ProblemReport.create(controller: controller) }
                    Button("新手引导…") { Onboarding.show() }
                }
                Text(ShellExports.command(port: controller.settings.mixedPort)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("开源组件") {
                Text("sing-box（GPL-3.0，github.com/SagerNet/sing-box）作为独立进程运行；规则集来自 SagerNet/sing-geosite 与 sing-geoip。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
