import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 节点（全部测速与排序、备用订阅）

struct NodesView: View {
    @EnvironmentObject var controller: AppController
    @State private var sortByDelay = true

    private var nodes: [String] {
        let all = controller.snapshot.groups[Groups.select]?.all ?? []
        let list = all.filter { controller.snapshot.groups[$0] == nil && $0 != Groups.direct }
        guard sortByDelay else { return list }
        return list.sorted { a, b in rank(a) < rank(b) }
    }

    /// Untested last, timeouts after working nodes.
    private func rank(_ name: String) -> Int {
        guard let delay = controller.snapshot.delays[name] else { return Int.max - 1 }
        return delay == 0 ? Int.max - 2 : delay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.status.isRunning {
                Text("开启代理后可以在这里测速和切换节点。").foregroundStyle(.secondary)
            }
            HStack {
                Button(controller.testing ? "正在测速…" : "全部测速") { controller.testAllNodes() }
                    .disabled(controller.testing || !controller.status.isRunning)
                Toggle("按延迟排序", isOn: $sortByDelay)
                Spacer()
                Toggle("菜单里隐藏不可用节点", isOn: $controller.settings.hideDeadNodes)
            }
            let current = controller.snapshot.groups[Groups.select]?.now
            List(nodes, id: \.self) { name in
                HStack {
                    Image(systemName: current == name ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(current == name ? Color.accentColor : .secondary)
                    Text(name)
                    if controller.backupTags.contains(name) {
                        Text("备用").font(.caption2).padding(.horizontal, 4).background(Color.orange.opacity(0.2)).cornerRadius(3)
                    }
                    Text(controller.nodeProtocols[name] ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    delayText(controller.snapshot.delays[name])
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { controller.select(name, in: Groups.select) }
            }
            Text("双击使用该节点。共 \(nodes.count) 个，可用 \(nodes.filter { (controller.snapshot.delays[$0] ?? 0) > 0 }.count) 个。")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("备用订阅（故障转移）") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("备用订阅", selection: Binding(get: { controller.settings.backupProfileID }, set: { controller.setBackupProfile($0) })) {
                        Text("不使用").tag(UUID?.none)
                        ForEach(controller.profiles.filter { $0.id != controller.selectedProfile?.id }) { profile in
                            Text(profile.name).tag(UUID?.some(profile.id))
                        }
                    }
                    .disabled(controller.settings.mergeAllProfiles || controller.profiles.count < 2)
                    Text(controller.settings.mergeAllProfiles ? "“合并全部订阅”开启时不使用备用订阅。"
                         : "主用订阅的节点全部不通时，自动切到备用订阅；主用恢复后切回。需要至少两个订阅。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
    }

    @ViewBuilder private func delayText(_ delay: Int?) -> some View {
        if let delay {
            Text(delay == 0 ? "超时" : "\(delay) ms")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(delay == 0 ? .red : delay < 200 ? .green : delay < 500 ? .orange : .red)
        } else {
            Text("未测").foregroundStyle(.secondary)
        }
    }
}

// MARK: - 走哪条线

struct RouteLookupView: View {
    @EnvironmentObject var controller: AppController
    @State private var input = ""
    @State private var answer: RouteExplainer.Answer?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("输入网址或域名，例如 scholar.google.com", text: $input).onSubmit(lookup)
                Button("查询", action: lookup).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            if let answer {
                HStack(alignment: .top) {
                    Image(systemName: symbol(answer.target)).foregroundStyle(color(answer.target))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(answer.host)：\(title(answer.target))").fontWeight(.medium)
                        Text(answer.reason).font(.caption).foregroundStyle(.secondary)
                        if answer.target == .proxy || answer.target == .byIP, let node = currentNode {
                            Text("当前节点：\(node)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if answer.target != .direct {
                        Button("改为总是直连") { add(to: \.directDomains) }
                    }
                    if answer.target != .proxy {
                        Button("改为总是走代理") { add(to: \.proxyDomains) }
                    }
                }
            }
        }
    }

    private var currentNode: String? {
        guard let now = controller.snapshot.groups[Groups.select]?.now else { return nil }
        return controller.snapshot.groups[now]?.now.map { "\(now) → \($0)" } ?? now
    }

    private func lookup() {
        let text = input
        let options = controller.settings.coreOptions
        let core = controller.core
        busy = true
        Task {
            answer = await Shell.background {
                RouteExplainer.explain(text, options: options) { set, host in core.ruleSetContains(set, host) }
            }
            busy = false
        }
    }

    private func add(to keyPath: WritableKeyPath<AppSettings, [String]>) {
        guard let host = answer?.host, !host.isEmpty else { return }
        controller.settings.directDomains.removeAll { $0 == host }
        controller.settings.proxyDomains.removeAll { $0 == host }
        controller.settings[keyPath: keyPath].append(host)
        controller.rulesChanged()
        controller.reloadIfRunning()
        lookup()
    }

    private func title(_ target: RouteExplainer.Target) -> String {
        switch target {
        case .direct: return "直连"
        case .proxy: return "走节点"
        case .reject: return "拦截"
        case .byIP: return "看 IP 决定"
        }
    }
    private func symbol(_ target: RouteExplainer.Target) -> String {
        switch target {
        case .direct: return "arrow.right.circle"
        case .proxy: return "globe"
        case .reject: return "nosign"
        case .byIP: return "questionmark.circle"
        }
    }
    private func color(_ target: RouteExplainer.Target) -> Color {
        switch target {
        case .direct: return .green
        case .proxy: return .blue
        case .reject: return .red
        case .byIP: return .orange
        }
    }
}

// MARK: - 按网络自动切换

struct NetworkRulesView: View {
    @EnvironmentObject var controller: AppController
    @State private var name = ""
    @State private var action: NetworkRule.Action = .direct

    var body: some View {
        Toggle("按所连的网络自动切换", isOn: $controller.settings.networkAutomation)
        if let current = controller.networkCurrent {
            HStack {
                Text("当前网络：\(current.label)")
                if let rule = controller.settings.networkRules.first(where: { $0.routerMAC == current.routerMAC }) {
                    Text("（规则：\(rule.name) → \(rule.action.title)）").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("名称，如“家里”“单位”", text: $name).frame(maxWidth: 180)
                Picker("连上时", selection: $action) {
                    ForEach(NetworkRule.Action.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 200)
                Button("为当前网络添加") { controller.addRuleForCurrentNetwork(name: name, action: action); name = "" }
            }
        } else {
            Text("当前没有可识别的网络。").foregroundStyle(.secondary)
        }
        ForEach(controller.settings.networkRules) { rule in
            HStack {
                Text(rule.name)
                Text("→ \(rule.action.title)").foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { controller.removeNetworkRule(rule.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        Text("按路由器识别网络，不需要定位权限。离开该网络后自动恢复原来的模式或重新开启代理。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - 连接

@MainActor
final class ConnectionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = ConnectionsModel()

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ConnectionsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "KongPrism · 连接"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 480))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Polling stops as soon as the window closes or is minimised.
    func windowWillClose(_ notification: Notification) { model.stop() }
    func windowDidMiniaturize(_ notification: Notification) { model.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { model.start() }
}

@MainActor
final class ConnectionsModel: ObservableObject {
    @Published var connections: [ClashAPI.Connection] = []
    @Published var totals: (up: Int64, down: Int64) = (0, 0)
    @Published var filter = ""
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let controller = AppController.shared
        guard controller.status.isRunning else { connections = []; return }
        Task {
            guard let result = try? await controller.api.connections() else { return }
            connections = result.connections.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            totals = (result.upload, result.download)
        }
    }

    func close(_ id: String) {
        Task {
            await AppController.shared.api.closeConnection(id)
            refresh()
        }
    }

    func closeAll() {
        Task {
            await AppController.shared.api.closeConnections()
            refresh()
        }
    }
}

struct ConnectionsView: View {
    @ObservedObject var model: ConnectionsModel

    private var shown: [ClashAPI.Connection] {
        let text = model.filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return model.connections }
        return model.connections.filter { "\($0.host) \($0.rule) \($0.chain) \($0.process)".lowercased().contains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("筛选：域名、规则、节点、程序", text: $model.filter).frame(maxWidth: 280)
                Spacer()
                Text("\(shown.count) 条 · 累计 ↑\(SubscriptionUsage.bytes(model.totals.up)) ↓\(SubscriptionUsage.bytes(model.totals.down))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("全部断开") { model.closeAll() }
            }
            Table(shown) {
                TableColumn("域名 / 地址") { Text($0.host).lineLimit(1).help($0.host) }.width(min: 180, ideal: 240)
                TableColumn("规则") { Text($0.rule).lineLimit(1).foregroundStyle(.secondary) }.width(min: 100, ideal: 150)
                TableColumn("线路") { Text($0.chain).lineLimit(1) }.width(min: 120, ideal: 180)
                TableColumn("程序") { Text($0.process).lineLimit(1).foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                TableColumn("↓ / ↑") { item in
                    Text("\(SubscriptionUsage.bytes(item.download)) / \(SubscriptionUsage.bytes(item.upload))")
                        .font(.system(.caption, design: .monospaced))
                }.width(min: 90, ideal: 120)
                TableColumn("") { item in
                    Button { model.close(item.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("断开")
                }.width(28)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 360)
    }
}
