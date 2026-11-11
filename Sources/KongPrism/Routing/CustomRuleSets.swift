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
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { CustomRuleSets.removeFiles(of: entry) }
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
        rulesChanged() // iCloud sync carries favorites (0.6)
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
                    Toggle("启用 \(entry.name)", isOn: Binding(get: { entry.enabled }, set: { on in controller.updateCustomRuleSet(entry.id) { $0.enabled = on } }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(detail(entry)).font(.caption)
                            .foregroundStyle(entry.lastError == nil ? Color.secondary : Color.red)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Picker("\(entry.name) 走哪条线", selection: Binding(get: { entry.target }, set: { value in controller.updateCustomRuleSet(entry.id) { $0.target = value } })) {
                        ForEach(CustomRuleSetSetting.targets, id: \.self) { Text(CustomRuleSetSetting.targetName($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 80)
                    Button(role: .destructive) { controller.removeCustomRuleSet(entry.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("删除规则集 \(entry.name)")
                        .buttonStyle(.borderless).help("删除这个规则集")
                }
            }
            HStack {
                TextField("名称（可选）", text: $name).frame(width: 110)
                TextField("规则集地址 https://…", text: $url)
                Picker("新规则集走哪条线", selection: $target) {
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
