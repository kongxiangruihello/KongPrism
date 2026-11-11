import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 自定义远程规则集

/// A rule list from any URL, routed to 直连 / 代理 / 拦截 and refreshed with the built-in rule-sets.
struct CustomRuleSetSetting: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var url: String
    /// "direct", "proxy" or "reject"
    var target = "proxy"
    var enabled = true
    /// "srs" or "json" once downloaded.
    var fileExtension: String?
    var ruleCount: Int?
    var updatedAt: Date?
    var lastError: String?

    init(name: String, url: String, target: String) {
        self.name = name
        self.url = url
        self.target = target
    }

    var tag: String { CustomRuleSource.tag(for: id) }
    var file: String? { fileExtension.map { "\(tag).\($0)" } }
    var ruleSet: RuleSet? { file.map { RuleSet(tag: tag, file: $0, urls: [url]) } }

    var targetName: String { Self.targetName(target) }
    var summaryLine: String { "\(name)→\(targetName)" + (lastError == nil ? "" : "（失败）") }

    static let targets = ["proxy", "direct", "reject"]
    static func targetName(_ target: String) -> String {
        switch target {
        case "direct": return "直连"
        case "reject": return "拦截"
        default: return "代理"
        }
    }
}

enum CustomRuleSets {
    struct Outcome {
        var entry: CustomRuleSetSetting
        /// The file content changed (sing-box reloads it by itself).
        var changed: Bool
        /// The file name changed (.json ↔ .srs, or first download): the config must be rebuilt.
        var needsReload: Bool
    }

    /// Downloads one list, converts Clash formats to a sing-box source rule-set, checks it with
    /// `sing-box rule-set match` and only then replaces the file in the rules folder.
    static func download(_ entry: CustomRuleSetSetting, routes: [Net.Route], binary: URL?) async -> Outcome {
        var entry = entry
        let before = entry.file
        do {
            guard let url = URL(string: entry.url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw CoreManager.CoreError("地址需以 http:// 或 https:// 开头")
            }
            let (data, _) = try await Net.get(url, headers: ["User-Agent": "KongPrism/\(AppUpdater.version)"], routes: routes, timeout: 30)
            guard data.count < 30_000_000 else { throw CoreManager.CoreError("文件超过 30 MB") }
            guard let result = CustomRuleSource.convert(data) else {
                throw CoreManager.CoreError("不是能识别的规则集（支持 sing-box .srs / .json，以及 Clash 规则集 YAML / 文本）")
            }
            let ext = result.converted.fileExtension
            let fileName = "\(entry.tag).\(ext)"
            let target = Paths.rules.appendingPathComponent(fileName)
            let staging = Paths.rules.appendingPathComponent(".\(fileName).new")
            try result.converted.data.write(to: staging, options: .atomic)
            defer { try? FileManager.default.removeItem(at: staging) }
            if let binary {
                let format = ext == "json" ? "source" : "binary"
                let check = await Shell.background {
                    Shell.run(binary.path, ["rule-set", "match", "-f", format, staging.path, "example.invalid", "--disable-color"], timeout: 20)
                }
                guard check.ok else { throw CoreManager.CoreError("sing-box 无法读取：" + CheckError.readable(check.output)) }
            }
            let changed = (try? Data(contentsOf: target)) != result.converted.data
            if changed {
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: staging, to: target)
            }
            // Drop the file of the other format, if the list switched formats.
            for other in ["json", "srs"] where other != ext {
                try? FileManager.default.removeItem(at: Paths.rules.appendingPathComponent("\(entry.tag).\(other)"))
            }
            entry.fileExtension = ext
            entry.ruleCount = result.summary?.total
            entry.updatedAt = Date()
            entry.lastError = nil
            AppLog.write("自定义规则集“\(entry.name)”已更新\(changed ? "" : "（无变化）")")
            return Outcome(entry: entry, changed: changed, needsReload: before != entry.file)
        } catch {
            entry.lastError = error.localizedDescription
            AppLog.write("自定义规则集“\(entry.name)”更新失败：\(error.localizedDescription)")
            return Outcome(entry: entry, changed: false, needsReload: false)
        }
    }

    static func removeFiles(of entry: CustomRuleSetSetting) {
        for ext in ["json", "srs"] {
            try? FileManager.default.removeItem(at: Paths.rules.appendingPathComponent("\(entry.tag).\(ext)"))
        }
    }
}

extension AppController {
    @discardableResult
    func addCustomRuleSet(name: String, url: String, target: String) async -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = name.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = URL(string: trimmed)?.lastPathComponent ?? "规则集" }
        let entry = CustomRuleSetSetting(name: title, url: trimmed, target: target)
        let outcome = await CustomRuleSets.download(entry, routes: proxyFirst, binary: core.binary())
        if let error = outcome.entry.lastError { return error }
        settings.customRuleSets.append(outcome.entry)
        rulesChanged()
        reloadIfRunning()
        return nil
    }

    func removeCustomRuleSet(_ id: UUID) {
        guard let entry = settings.customRuleSets.first(where: { $0.id == id }) else { return }
        settings.customRuleSets.removeAll { $0.id == id }
        reloadIfRunning()
        // Remove the file after the core has the new config.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { CustomRuleSets.removeFiles(of: entry) }
    }

    func updateCustomRuleSet(_ id: UUID, change: (inout CustomRuleSetSetting) -> Void) {
        guard let index = settings.customRuleSets.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.customRuleSets[index])
        rulesChanged()
        reloadIfRunning()
    }

    /// Called with the built-in rule update (weekly, or 立即更新). Returns how many changed.
    func refreshCustomRuleSets() async -> (changed: Int, failed: Int) {
        var changed = 0, failed = 0, reload = false
        let binary = core.binary()
        for entry in settings.customRuleSets where entry.enabled {
            let outcome = await CustomRuleSets.download(entry, routes: proxyFirst, binary: binary)
            if let index = settings.customRuleSets.firstIndex(where: { $0.id == entry.id }) {
                // Keep a user edit made while downloading (name / target / enabled).
                var merged = settings.customRuleSets[index]
                merged.fileExtension = outcome.entry.fileExtension
                merged.ruleCount = outcome.entry.ruleCount
                merged.updatedAt = outcome.entry.updatedAt
                merged.lastError = outcome.entry.lastError
                settings.customRuleSets[index] = merged
            }
            if outcome.entry.lastError != nil { failed += 1 }
            if outcome.changed { changed += 1 }
            if outcome.needsReload { reload = true }
        }
        if reload { reloadIfRunning() }
        return (changed, failed)
    }

    // MARK: 收藏节点

    func toggleFavorite(_ name: String) {
        if let index = settings.favoriteNodes.firstIndex(of: name) {
            settings.favoriteNodes.remove(at: index)
        } else {
            settings.favoriteNodes.append(name)
        }
    }
}

struct CustomRuleSetsSection: View {
    @EnvironmentObject var controller: AppController
    @State private var name = ""
    @State private var url = ""
    @State private var target = "proxy"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.settings.customRuleSets) { entry in
                HStack {
                    Toggle("", isOn: Binding(get: { entry.enabled }, set: { on in controller.updateCustomRuleSet(entry.id) { $0.enabled = on } }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(detail(entry)).font(.caption)
                            .foregroundStyle(entry.lastError == nil ? Color.secondary : Color.red)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { entry.target }, set: { value in controller.updateCustomRuleSet(entry.id) { $0.target = value } })) {
                        ForEach(CustomRuleSetSetting.targets, id: \.self) { Text(CustomRuleSetSetting.targetName($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 80)
                    Button(role: .destructive) { controller.removeCustomRuleSet(entry.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("删除这个规则集")
                }
            }
            HStack {
                TextField("名称（可选）", text: $name).frame(width: 110)
                TextField("规则集地址 https://…", text: $url)
                Picker("", selection: $target) {
                    ForEach(CustomRuleSetSetting.targets, id: \.self) { Text(CustomRuleSetSetting.targetName($0)).tag($0) }
                }
                .labelsHidden().frame(width: 80)
                Button(busy ? "下载中…" : "添加") { add() }
                    .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("支持 sing-box 规则集（.srs / .json）和 Clash 规则集（YAML 的 payload 列表或纯文本，domain / ipcidr / classical）。排在内置规则之前生效；随“每周自动更新规则集”一起更新，下载优先走代理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ entry: CustomRuleSetSetting) -> String {
        if let error = entry.lastError { return "更新失败：\(error)" }
        var parts: [String] = []
        if let count = entry.ruleCount { parts.append("\(count) 条") }
        if let date = entry.updatedAt { parts.append("更新于 \(date.formatted(date: .abbreviated, time: .shortened))") }
        parts.append(URL(string: entry.url)?.host ?? entry.url)
        return parts.joined(separator: " · ")
    }

    private func add() {
        busy = true
        error = nil
        Task {
            if let failure = await controller.addCustomRuleSet(name: name, url: url, target: target) {
                error = "添加失败：\(failure)"
            } else {
                name = ""
                url = ""
            }
            busy = false
        }
    }
}

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

// MARK: - 新手引导

@MainActor
enum Onboarding {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView().environmentObject(AppController.shared))
            let created = NSWindow(contentViewController: hosting)
            created.title = "欢迎使用 KongPrism"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 520, height: 470))
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    @EnvironmentObject var controller: AppController
    @State private var input = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var checking = false
    @State private var googleResult: (ok: Bool, text: String)?
    @State private var others: [String] = OtherClients.running().map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }

    private var step: Int {
        if controller.profiles.isEmpty { return 1 }
        if !controller.status.isRunning { return 2 }
        return googleResult?.ok == true ? 4 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("三步开始使用").font(.title2.bold())
            if AppUpdater.isTranslocatedOrOutsideApplications {
                warning("KongPrism 不在“应用程序”文件夹里，在线更新无法替换它。", button: "移到“应用程序”") { AppUpdater.moveToApplications() }
            }
            if !others.isEmpty {
                warning("\(others.joined(separator: "、")) 正在运行，两个代理软件会互相改写系统代理。", button: "退出它们") {
                    for app in OtherClients.running() { app.terminate() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { others = OtherClients.running().map { $0.localizedName ?? "?" } }
                }
            }

            stepView(1, "添加订阅") {
                if step == 1 {
                    TextField("粘贴订阅地址 https://…（机场网页上的 Clash 订阅）", text: $input)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(adding ? "正在下载订阅…" : "添加") { add() }
                            .disabled(adding || input.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                        Button("从文件导入…") { Importer.chooseFile(controller: controller) }
                        if adding { ProgressView().controlSize(.small) }
                    }
                    if let addError { Text(addError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    Text("也可以在机场网页上点“一键导入 Clash / sing-box”。").font(.caption).foregroundStyle(.secondary)
                } else if let profile = controller.selectedProfile {
                    Text("“\(profile.name)”：\(profile.nodeCount) 个节点").foregroundStyle(.secondary)
                }
            }

            stepView(2, "开启代理") {
                if step == 2 {
                    HStack {
                        Button("开启代理") { controller.connect() }.disabled(controller.status == .starting)
                        if controller.status == .starting { ProgressView().controlSize(.small) }
                    }
                    if case .failed(let message) = controller.status { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                } else if step > 2 {
                    Text("已连接，系统代理指向 127.0.0.1:\(String(controller.settings.mixedPort))").foregroundStyle(.secondary)
                }
            }

            stepView(3, "验证能打开 Google") {
                if step >= 3 {
                    HStack {
                        Button(checking ? "正在检查…" : "检查") { checkGoogle() }.disabled(checking)
                        if let googleResult {
                            Label(googleResult.text, systemImage: googleResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(googleResult.ok ? .green : .red)
                        }
                    }
                    if googleResult?.ok == false {
                        Button("诊断连接…") { Diagnostics.show(controller: controller) }
                    }
                }
            }

            Spacer()
            HStack {
                Text("菜单栏的 ◇ 图标可以开关代理、换节点；\(HotKey.display) 一键开关。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(step == 4 ? "完成" : "以后再说") {
                    controller.settings.onboardingDone = true
                    Onboarding.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520, height: 470)
        .onAppear {
            if controller.status.isRunning, googleResult == nil { checkGoogle() }
            if input.isEmpty, let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.hasPrefix("http"), !text.contains("\n"), text.count < 2000 {
                input = text
            }
        }
        .onChange(of: controller.status) { status in
            if status.isRunning, googleResult == nil { checkGoogle() }
        }
    }

    @ViewBuilder
    private func stepView<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(step > number ? Color.green : step == number ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 26, height: 26)
                if step > number { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold()) }
                else { Text("\(number)").foregroundStyle(.white).font(.callout.bold()) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(step >= number ? Color.primary : Color.secondary)
                content()
            }
        }
    }

    private func warning(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button(button, action: action)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    private func add() {
        adding = true
        addError = nil
        let text = input
        Task {
            do {
                let id = try await controller.addProfile(input: text, name: "")
                controller.selectProfile(id)
                input = ""
            } catch {
                addError = "添加失败：\(error.localizedDescription)"
            }
            adding = false
        }
    }

    private func checkGoogle() {
        checking = true
        let port = controller.settings.mixedPort
        Task {
            let start = Date()
            do {
                let (_, response) = try await Net.get(URL(string: "https://www.google.com/generate_204")!, headers: ["User-Agent": "KongPrism-Onboarding"],
                                                      routes: [.viaProxy(port: port)], timeout: 10)
                googleResult = (true, "可以访问（HTTP \(response.statusCode)，\(Int(Date().timeIntervalSince(start) * 1000)) ms）")
            } catch {
                googleResult = (false, "打不开：\(error.localizedDescription)")
            }
            checking = false
        }
    }
}
