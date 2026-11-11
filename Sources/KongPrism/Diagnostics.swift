import AppKit
import CFNetwork
import KongPrismCore

/// 菜单 › 诊断连接：one click, a plain-language report of where the chain breaks.
@MainActor
enum Diagnostics {
    struct Line {
        let ok: Bool?
        let text: String
    }

    static let otherClients = ["kongbabel", "clash", "verge", "mihomo", "v2ray", "shadowrocket", "surge", "hiddify", "sing-box",
                               "singbox", "stash", "quantumult", "loon", "flclash", "nekoray", "kong.networkconsole"]

    static func run(controller: AppController) async -> [Line] {
        var lines: [Line] = []
        let settings = controller.settings
        let port = settings.mixedPort

        // 1. Core
        let running = controller.core.isRunning
        lines.append(Line(ok: running, text: running ? "内核正在运行（sing-box \(controller.coreVersion ?? "?")）" : "内核没有运行：\(statusText(controller.status))"))

        // 2. Other proxy clients
        let others = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let id = app.bundleIdentifier?.lowercased(), id != Bundle.main.bundleIdentifier?.lowercased(),
                  otherClients.contains(where: { id.contains($0) }) else { return nil }
            return app.localizedName ?? id
        }
        if others.isEmpty {
            lines.append(Line(ok: true, text: "没有发现其他代理软件在运行"))
        } else {
            lines.append(Line(ok: false, text: "其他代理软件正在运行：\(others.joined(separator: "、"))。它们可能改回系统代理或用 TUN 接管全部流量，请先退出"))
        }

        // 3. System proxy
        let current = systemProxyDescription()
        if !settings.setSystemProxy {
            lines.append(Line(ok: nil, text: "未让 KongPrism 设置系统代理（设置 › 常规）。当前系统代理：\(current)"))
        } else if SystemProxy.isPointing(to: port) {
            lines.append(Line(ok: true, text: "系统代理指向 KongPrism（127.0.0.1:\(port)）"))
        } else {
            lines.append(Line(ok: false, text: "系统代理没有指向 KongPrism，当前是：\(current)"))
        }
        if hasTunDefaultRoute() {
            lines.append(Line(ok: false, text: "发现有 TUN 网卡接管默认路由（通常是另一个代理软件的增强/TUN 模式）"))
        }

        // 4. Subscription
        if let profile = controller.selectedProfile {
            var text = "订阅“\(profile.name)”：\(profile.nodeCount) 个节点"
            if let format = profile.format { text += "（\(format)）" }
            if let date = profile.updatedAt { text += "，更新于 \(date.formatted(date: .abbreviated, time: .shortened))" }
            if profile.skipped > 0 { text += "，跳过 \(profile.skipped) 个不支持的" }
            if let host = profile.url.flatMap({ URL(string: $0)?.host }) { text += "，订阅域名 \(host)" }
            lines.append(Line(ok: profile.nodeCount > 0, text: text))
            if let error = profile.lastError { lines.append(Line(ok: false, text: "上次更新失败：\(error)")) }
            let stored = controller.activeNodes()
            let informational = stored.filter { NodeFilter.isInformational($0.name) }
            let sample = stored.prefix(6).map { "\($0.name)（\($0.protocolLabel)）" }.joined(separator: "、")
            lines.append(Line(ok: stored.isEmpty ? false : nil,
                              text: "节点文件：\(stored.count) 个，其中信息条目 \(informational.count) 个；前几个：\(sample.isEmpty ? "无" : sample)"))
            if running {
                lines.append(Line(ok: controller.configNodeCount > 0,
                                  text: "内核配置：载入 \(controller.loadedNodeCount) 个，放进配置 \(controller.configNodeCount) 个，被内核拒绝 \(controller.droppedNodes.count) 个"))
            }
        } else {
            lines.append(Line(ok: false, text: "还没有订阅"))
        }

        // 5. Direct internet
        let direct = await probe("https://www.baidu.com", route: .direct)
        lines.append(Line(ok: direct.ok, text: "不经代理访问百度：\(direct.text)"))

        guard running else { return lines }

        // 5. Through KongPrism
        let domestic = await probe("https://www.baidu.com", route: .viaProxy(port: port))
        lines.append(Line(ok: domestic.ok, text: "经 KongPrism 访问百度（应直连）：\(domestic.text)"))
        // www.google.com is blocked for direct connections; gstatic is not, so it would prove nothing.
        let foreign = await probe("https://www.google.com/generate_204", route: .viaProxy(port: port))
        lines.append(Line(ok: foreign.ok, text: "经 KongPrism 访问 Google（走节点）：\(foreign.text)"))

        // 6. Nodes
        await controller.refreshSnapshot()
        let snapshot = controller.snapshot
        if let now = snapshot.groups[Groups.select]?.now {
            let detail = snapshot.groups[now]?.now.map { "\(now) → \($0)" } ?? now
            lines.append(Line(ok: now == Groups.direct ? false : nil,
                              text: now == Groups.direct ? "当前节点：直连（国外网站不会走代理）" : "当前节点：\(detail)"))
        }
        let total = snapshot.groups[Groups.auto]?.all.count ?? 0
        if total > 0, let delays = try? await controller.api.testGroup(Groups.auto, url: settings.testURL, timeoutMs: 5000) {
            let alive = delays.filter { $0.value > 0 }
            let best = alive.min { $0.value < $1.value }
            var text = "节点测速：\(alive.count)/\(total) 个可用"
            if let best { text += "，最快 \(best.key) \(best.value) ms" }
            if alive.isEmpty { text += "。全部不通：订阅可能过期，或节点协议转换有问题（把本报告发给开发者）" }
            lines.append(Line(ok: !alive.isEmpty, text: text))
        } else if total == 0 {
            lines.append(Line(ok: false, text: "当前订阅里没有可用节点"))
        }
        if !controller.droppedNodes.isEmpty {
            lines.append(Line(ok: nil, text: "被内核跳过的节点：\(controller.droppedNodes.prefix(5).joined(separator: "、"))\(controller.droppedNodes.count > 5 ? " 等 \(controller.droppedNodes.count) 个" : "")"))
        }

        // 7. Recent core errors
        if let log = try? String(contentsOf: Paths.coreLog, encoding: .utf8) {
            let errors = log.split(whereSeparator: \.isNewline).filter { $0.contains("ERROR") || $0.contains("FATAL") }.suffix(5)
            for line in errors { lines.append(Line(ok: nil, text: "内核日志：" + CheckError.readable(String(line)))) }
        }
        return lines
    }

    static func show(controller: AppController) {
        Task {
            let lines = await run(controller: controller)
            let report = lines.map { line -> String in
                switch line.ok {
                case true?: return "✅ " + line.text
                case false?: return "❌ " + line.text
                case nil: return "• " + line.text
                }
            }.joined(separator: "\n")
            let header = "KongPrism \(AppUpdater.version)（\(AppUpdater.build)） · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "连接诊断"
            alert.informativeText = report
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "复制报告")
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(header + "\n" + report, forType: .string)
            }
        }
    }

    // MARK: Helpers

    private static func statusText(_ status: AppController.Status) -> String {
        switch status {
        case .stopped: return "未开启"
        case .starting: return "正在启动"
        case .running: return "运行中"
        case .failed(let message): return message
        }
    }

    private static func probe(_ address: String, route: Net.Route) async -> (ok: Bool, text: String) {
        let start = Date()
        do {
            let (_, response) = try await Net.get(URL(string: address)!, headers: ["User-Agent": "KongPrism-Diagnostics"], routes: [route], timeout: 8)
            return (true, "成功（HTTP \(response.statusCode)，\(Int(Date().timeIntervalSince(start) * 1000)) ms）")
        } catch {
            return (false, "失败（\(error.localizedDescription)）")
        }
    }

    private static func systemProxyDescription() -> String {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return "无法读取" }
        var parts: [String] = []
        if (settings[kCFNetworkProxiesHTTPSEnable as String] as? Int) == 1 {
            parts.append("HTTPS \(settings[kCFNetworkProxiesHTTPSProxy as String] ?? "?"):\(settings[kCFNetworkProxiesHTTPSPort as String] ?? "?")")
        }
        if (settings[kCFNetworkProxiesHTTPEnable as String] as? Int) == 1 {
            parts.append("HTTP \(settings[kCFNetworkProxiesHTTPProxy as String] ?? "?"):\(settings[kCFNetworkProxiesHTTPPort as String] ?? "?")")
        }
        if (settings[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int) == 1 {
            parts.append("PAC \(settings[kCFNetworkProxiesProxyAutoConfigURLString as String] ?? "")")
        }
        return parts.isEmpty ? "未设置" : parts.joined(separator: "，")
    }

    /// `route -n get default` names a utun interface when a TUN client owns the default route.
    private static func hasTunDefaultRoute() -> Bool {
        Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5).output
            .split(whereSeparator: \.isNewline)
            .contains { $0.contains("interface:") && $0.contains("utun") }
    }
}
