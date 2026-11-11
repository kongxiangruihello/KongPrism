import Foundation
import SwiftUI
import KongPrismCore

/// 常用网站体检: for each site, which way KongPrism sends it (the same rule order as the core),
/// whether it opens through KongPrism, and how long it took. Sites are checked in parallel.
enum SiteCheck {
    struct Result: Identifiable, Equatable {
        let host: String
        let route: String
        let ok: Bool
        let detail: String
        var id: String { host }

        var line: String { "\(host) → \(route) · \(detail)" }
    }

    /// "节点选择 → 日本 01" (follows groups down to the node).
    static func resolved(_ group: String, in snapshot: ClashAPI.Snapshot) -> String {
        var name = group
        for _ in 0..<3 { if let next = snapshot.groups[name]?.now { name = next } else { break } }
        return name == group ? group : "\(group) → \(name)"
    }

    @MainActor
    static func run(controller: AppController) async -> [Result] {
        let hosts = controller.settings.siteChecks.map { RouteExplainer.host(from: $0) }.filter { !$0.isEmpty }
        let options = controller.settings.coreOptions
        let core = controller.core
        let port = controller.settings.mixedPort
        let running = controller.status.isRunning
        if running { await controller.refreshSnapshot() }
        let snapshot = controller.snapshot
        return await withTaskGroup(of: (Int, Result).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    let answer = await Shell.background {
                        RouteExplainer.explain(host, options: options) { set, name in core.ruleSetContains(set, name) }
                    }
                    let route: String
                    switch answer.target {
                    case .direct: route = "直连"
                    case .reject: route = "拦截"
                    case .proxy: route = resolved(Groups.select, in: snapshot)
                    case .service(let name): route = resolved(name, in: snapshot)
                    case .byIP: route = "按 IP 归属"
                    }
                    guard running, answer.target != .reject else {
                        return (index, Result(host: host, route: route, ok: answer.target == .reject, detail: running ? "按规则拦截" : "代理未开启"))
                    }
                    let start = Date()
                    do {
                        let url = URL(string: "https://\(host)/")!
                        let (_, response) = try await Net.get(url, headers: ["User-Agent": "Mozilla/5.0 (Macintosh) KongPrism-SiteCheck"],
                                                              routes: [.viaProxy(port: port)], timeout: 10)
                        return (index, Result(host: host, route: route, ok: true,
                                              detail: "HTTP \(response.statusCode)，\(Int(Date().timeIntervalSince(start) * 1000)) ms"))
                    } catch let error as Net.HTTPError where error.status < 500 {
                        // 403 / 404 from the site itself still proves the route works.
                        return (index, Result(host: host, route: route, ok: true,
                                              detail: "HTTP \(error.status)，\(Int(Date().timeIntervalSince(start) * 1000)) ms（网站有回应）"))
                    } catch {
                        return (index, Result(host: host, route: route, ok: false, detail: "打不开：\(ErrorSummary.short(error.localizedDescription))"))
                    }
                }
            }
            var results: [(Int, Result)] = []
            for await item in group { results.append(item) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// 设置 › 分流 › 常用网站体检
struct SiteCheckSection: View {
    @EnvironmentObject var controller: AppController
    @State private var text = ""
    @State private var results: [SiteCheck.Result] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(width: 200, height: 120)
                    .accessibilityLabel("要体检的网站，每行一个")
                VStack(alignment: .leading, spacing: 4) {
                    if results.isEmpty {
                        Text(controller.status.isRunning ? "点“立即体检”：每个网站走哪条线、能不能打开、用时多少。" : "开启代理后可以体检。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(results) { result in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.ok ? .green : .red)
                                .accessibilityLabel(result.ok ? "正常" : "有问题")
                            Text(result.host).font(.callout.monospaced())
                            Text("→ \(result.route)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(result.detail).font(.caption.monospacedDigit()).foregroundStyle(result.ok ? Color.secondary : Color.red)
                        }
                    }
                }
            }
            HStack {
                Button(running ? "正在体检…" : "立即体检") { check() }.disabled(running || !controller.status.isRunning)
                Button("恢复默认列表") { text = AppSettings.defaultSiteChecks.joined(separator: "\n"); save() }
                Spacer()
                Text("每行一个域名；改完点体检即保存。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = controller.settings.siteChecks.joined(separator: "\n") }
    }

    private func save() {
        let hosts = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if hosts != controller.settings.siteChecks { controller.settings.siteChecks = hosts }
    }

    private func check() {
        save()
        running = true
        Task {
            results = await SiteCheck.run(controller: controller)
            running = false
        }
    }
}
