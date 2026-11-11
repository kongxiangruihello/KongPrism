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

        lines.append(Line(ok: nil, text: Secrets.storageDescription))

        // 1b. Crashes
        let crashes = CrashRecords.recentReports(days: 14)
        if CrashRecords.lastRunEndedAbnormally || !crashes.isEmpty {
            var text = CrashRecords.lastRunEndedAbnormally ? "上次 KongPrism 没有正常退出" : "近 14 天有崩溃记录"
            if !crashes.isEmpty { text += "；崩溃记录：" + crashes.prefix(3).map(\.lastPathComponent).joined(separator: "、") + "（已附在问题报告里）" }
            lines.append(Line(ok: nil, text: text))
        }

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
        if settings.tunMode {
            lines.append(Line(ok: nil, text: "增强模式不使用系统代理。当前系统代理：\(current)"))
        } else if !settings.setSystemProxy {
            lines.append(Line(ok: nil, text: "未让 KongPrism 设置系统代理（设置 › 网络）。当前系统代理：\(current)"))
        } else if SystemProxy.isPointing(to: port) {
            lines.append(Line(ok: true, text: "系统代理指向 KongPrism（127.0.0.1:\(port)）"))
        } else {
            lines.append(Line(ok: false, text: "系统代理没有指向 KongPrism，当前是：\(current)"))
        }
        if hasTunDefaultRoute() && !settings.tunMode {
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
            if let error = profile.lastError {
                let when = profile.lastErrorAt.map { $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) + " " } ?? ""
                lines.append(Line(ok: false, text: "\(when)更新失败：\(error)"))
            }
            if let until = profile.pausedUntil, until > Date() {
                lines.append(Line(ok: nil, text: "订阅服务器上次拒绝了请求，自动更新暂停到 \(until.formatted(date: .omitted, time: .shortened))（手动“立即更新”不受影响）"))
            }
            if let usage = profile.usage { lines.append(Line(ok: usage.warning() == nil ? nil : false, text: "用量：\(usage.summary)")) }
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
            // Say what the test covered: 自动选择 may leave nodes out (multiplier limit, avoided nodes).
            let configured = max(controller.configNodeCount, total)
            var outsideNote = ""
            if configured > total {
                var reasons: [String] = []
                let limit = settings.maxMultiplier
                let auto = Set(snapshot.groups[Groups.auto]?.all ?? [])
                let outside = (snapshot.groups[Groups.select]?.all ?? []).filter { name in snapshot.groups[name] == nil && name != Groups.direct && !auto.contains(name) }
                let byRate = limit > 0 ? outside.filter { name in (NodeFilter.multiplier(name) ?? 0) > limit }.count : 0
                let byAvoid = outside.filter { name in (controller.avoidedNodes[name] ?? .distantPast) > Date() }.count
                if byRate > 0 { reasons.append("\(byRate) 个因倍率上限") }
                if byAvoid > 0 { reasons.append("\(byAvoid) 个因暂时避开") }
                let rest = configured - total - byRate - byAvoid
                if rest > 0 { reasons.append("\(rest) 个属于备用订阅或其他原因") }
                outsideNote = "；另有 \(reasons.joined(separator: "、"))，不在测速范围内"
            }
            var text = "节点测速：自动选择范围内 \(total) 个，\(alive.count) 个可用"
            if let best { text += "，最快 \(best.key) \(best.value) ms" }
            text += outsideNote
            if alive.isEmpty { text += "。全部不通：订阅可能过期，或节点协议转换有问题（把本报告发给开发者）" }
            lines.append(Line(ok: !alive.isEmpty, text: text))
        } else if total == 0 {
            lines.append(Line(ok: false, text: "当前订阅里没有可用节点"))
        }
        if !controller.droppedNodes.isEmpty {
            lines.append(Line(ok: nil, text: "被内核跳过的节点：\(controller.droppedNodes.prefix(5).joined(separator: "、"))\(controller.droppedNodes.count > 5 ? " 等 \(controller.droppedNodes.count) 个" : "")"))
        }

        let avoided = controller.avoidedNodes.filter { $0.value > Date() }
        if !avoided.isEmpty {
            lines.append(Line(ok: nil, text: "自动选择正在避开：\(avoided.keys.sorted().joined(separator: "、"))（近 15 分钟连不上 5 次以上，1 小时后恢复）"))
        }
        // Exit IP through the proxy (the same lookup the menu uses; remembers which service answered).
        let mainExit = await ExitLookup.fetch(port: port)
        if let exit = mainExit {
            var text = "出口：" + exit.summary
            if let mismatch = controller.exitMismatch(for: exit) { text += "；\(mismatch)（仅供参考）" }
            lines.append(Line(ok: nil, text: text))
        } else {
            lines.append(Line(ok: false, text: "出口查询失败（ipinfo.io、ipapi.co、api.ip.sb 都没有回应）"))
        }
        // 0.9: where AI traffic exits (its own route when 按服务分流 sets one), and whether ChatGPT / Claude serve that region.
        let aiExit: ExitInfo?
        if let checkPort = controller.aiCheckPort {
            aiExit = await ExitLookup.fetch(port: checkPort)
        } else {
            aiExit = mainExit
        }
        if let exit = aiExit {
            let supported = AIRegions.isSupported(countryCode: exit.countryCode)
            var text = "AI 服务出口：" + exit.summary
            if supported == false {
                text += "。ChatGPT、Claude 不在这个地区提供服务（OpenAI / Anthropic 公开的支持名单里没有），会提示地区不可用：请在 设置 › 分流 › 按服务分流 里把 AI 服务换成其他地区"
            }
            lines.append(Line(ok: supported == false ? false : nil, text: text))
        } else if controller.aiCheckPort != nil {
            lines.append(Line(ok: false, text: "AI 服务出口查询失败"))
        }
        // 0.9: 常用网站体检
        for result in await SiteCheck.run(controller: controller) {
            lines.append(Line(ok: result.ok ? nil : false, text: "体检 " + result.line))
        }

        // 7. Recent core errors
        if settings.tunMode {
            lines.append(Line(ok: TunHelper.isInstalled ? nil : false,
                              text: TunHelper.isInstalled ? "增强模式（TUN）已开启" : "增强模式已开启，但辅助程序没有安装"))
        }
        let coreLog = LogTail.read(controller.core.logURL, bytes: 4 * 1024 * 1024)
        if !coreLog.isEmpty, let log = Optional(coreLog) {
            // Which nodes failed to connect, apart from the bursts logged while the Mac slept or switched networks.
            let stats = CoreLogStats.summarize(log)
            if let worst = stats.nodes.first {
                let period = [stats.firstTime, stats.lastTime].compactMap { $0.map { String($0.suffix(8).prefix(5)) } }.joined(separator: "–")
                let list = stats.nodes.prefix(3).map { "\($0.node) \($0.count) 次" }.joined(separator: "、")
                var text = "近期连不上的节点（\(period)）：\(list)"
                if !worst.hosts.isEmpty { text += "；受影响最多的网站：\(worst.hosts.joined(separator: "、"))" }
                // A service group may point at a region group (🇯🇵 日本 → 日本 02); follow up to two levels.
                func resolved(_ group: String) -> String? {
                    guard let now = snapshot.groups[group]?.now else { return nil }
                    guard let next = snapshot.groups[now]?.now else { return now }
                    return snapshot.groups[next]?.now ?? next
                }
                let services = Service.allCases.filter { resolved($0.groupName) == worst.node }
                if !services.isEmpty {
                    text += "。\(services.map(\.groupName).joined(separator: "、")) 正在用 \(worst.node)，可在 设置 › 分流 › 按服务分流 里换成“自动（排除香港）”等更大的范围"
                } else if resolved(Groups.select) == worst.node, snapshot.groups[Groups.select]?.now == worst.node {
                    text += "。这是你手选的节点，可以换一个或改回“自动选择”"
                }
                lines.append(Line(ok: worst.count >= 10 ? false : nil, text: text))
            }
            if stats.directFailures > 0 {
                lines.append(Line(ok: nil, text: "另有 \(stats.directFailures) 次直连失败（国内网站或局域网本身连不上，与节点无关）"))
            }
            if stats.networkDown > 0 {
                lines.append(Line(ok: nil, text: "另有 \(stats.networkDown) 条是网络暂时不可用时的报错（睡眠、唤醒或切换 Wi-Fi 时常见，不是节点问题）"))
            }
            let errors = log.split(whereSeparator: \.isNewline).filter { $0.contains("ERROR") || $0.contains("FATAL") }.suffix(3)
            for line in errors { lines.append(Line(ok: nil, text: "内核日志：" + LogAnonymizer.anonymize(CheckError.readable(String(line))))) }
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
            alert.addButton(withTitle: "导出脱敏订阅样本…")
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(header + "\n" + report, forType: .string)
            case .alertThirdButtonReturn:
                exportSample(controller: controller)
            default:
                break
            }
        }
    }

    /// Downloads the current subscription again and saves it with every secret replaced,
    /// so it can be sent to the developer and kept as a regression test.
    static func exportSample(controller: AppController) {
        guard let profile = controller.selectedProfile, let address = profile.url.flatMap(URL.init(string:)) else {
            controller.subscriptionTask = .failed("当前订阅不是链接订阅，无法导出")
            return
        }
        Task {
            let agent = profile.workingUserAgent ?? profile.userAgent ?? SubscriptionFetcher.agents[0]
            do {
                let (data, _) = try await Net.get(address, headers: SubscriptionFetcher.headers(agent: agent, url: address),
                                                  routes: controller.directFirst, timeout: 20)
                let text = SubscriptionSample.anonymize(String(decoding: data, as: UTF8.self))
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSSavePanel()
                panel.message = "已去掉服务器地址、密码、UUID 和密钥，只保留结构，可放心发送"
                panel.nameFieldStringValue = "KongPrism-订阅样本.yaml"
                panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                controller.subscriptionTask = .failed("导出失败：\(error.localizedDescription)")
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
