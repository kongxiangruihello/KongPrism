import AppKit
import CoreImage
import IOKit.ps
import KongPrismCore

// MARK: - 问题报告

enum ProblemReport {
    /// Diagnostics, recent logs, a settings summary without secrets and an anonymized subscription
    /// sample, zipped onto the Desktop.
    @MainActor
    static func create(controller: AppController) {
        Task {
            let lines = await Diagnostics.run(controller: controller)
            let stamp = { () -> String in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmm"
                return formatter.string(from: Date())
            }()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KongPrism-问题报告-\(stamp)")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func write(_ name: String, _ text: String) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }

            let report = lines.map { ($0.ok == true ? "✅ " : $0.ok == false ? "❌ " : "• ") + $0.text }.joined(separator: "\n")
            write("诊断.txt", LogAnonymizer.anonymize("KongPrism \(AppUpdater.version)（\(AppUpdater.build)） · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n" + report))
            write("设置摘要.txt", settingsSummary(controller))
            // Crash reports from ~/Library/Logs/DiagnosticReports (KongPrism and sing-box, last 14 days).
            let crashes = CrashRecords.recentReports(days: 14).prefix(5)
            if !crashes.isEmpty || CrashRecords.lastRunEndedAbnormally {
                let crashFolder = folder.appendingPathComponent("崩溃记录")
                try? FileManager.default.createDirectory(at: crashFolder, withIntermediateDirectories: true)
                for report in crashes { try? FileManager.default.copyItem(at: report, to: crashFolder.appendingPathComponent(report.lastPathComponent)) }
                try? CrashRecords.summary().write(to: crashFolder.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
            }
            // The nodes KongPrism is using, from the local copy: a regression sample even when the
            // subscription cannot be downloaded right now.
            let nodes = controller.activeNodes()
            if !nodes.isEmpty { write("节点结构（已脱敏）.json", NodeSample.anonymizedJSON(nodes: nodes)) }
            if let profile = controller.selectedProfile, let address = profile.url {
                do {
                    let raw = try await SubscriptionFetcher.raw(url: address, userAgent: profile.userAgent,
                                                                remembered: profile.workingUserAgent, routes: controller.directFirst)
                    write("订阅样本（已脱敏）.yaml", SubscriptionSample.anonymize(String(decoding: raw.data, as: UTF8.self)))
                    write("订阅下载.txt", "下载成功：UA \(raw.agent)，\(raw.data.count) 字节")
                    controller.markSubscriptionReachable(profile.id, agent: raw.agent)
                } catch {
                    write("订阅下载.txt", "下载失败：\(error.localizedDescription)\n（已附上本机缓存的节点结构）")
                }
            }
            // Logs last, so they include what happened while making this report.
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Node servers' addresses are replaced (ip-1, ip-2…); websites' names stay for debugging.
            write("app.log", LogAnonymizer.anonymize(tail(Paths.appLog, lines: 400)))
            write("core.log", LogAnonymizer.anonymize(tail(controller.core.logURL, lines: 400)))
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let zip = desktop.appendingPathComponent("KongPrism-问题报告-\(stamp).zip")
            let result = await Shell.background {
                Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", folder.path, zip.path])
            }
            try? FileManager.default.removeItem(at: folder)
            if result.ok {
                NSWorkspace.shared.activateFileViewerSelecting([zip])
                controller.subscriptionTask = .done("问题报告已保存到桌面")
            } else {
                controller.subscriptionTask = .failed("问题报告生成失败：\(result.output)")
            }
        }
    }

    static func tail(_ url: URL, lines count: Int) -> String {
        // Includes the previous generation (file.1) when the current file is short.
        let text = LogTail.read(url, bytes: 256 * 1024)
        guard !text.isEmpty else { return "（没有日志）" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    @MainActor
    static func settingsSummary(_ controller: AppController) -> String {
        let s = controller.settings
        var lines = [
            "模式：\(s.mode)　增强模式：\(s.tunMode)　系统代理：\(s.setSystemProxy)",
            "端口：\(s.mixedPort) / \(s.apiPort)　局域网：\(s.allowLAN)",
            "广告拦截：\(s.blockAds)　按 IP 分流：\(s.smartIPRouting)　地区分组：\(s.regionGroups)",
            "DNS：\(s.remoteDNS) / \(s.localDNS)",
            "自定义直连 \(s.directDomains.count) 条，自定义代理 \(s.proxyDomains.count) 条",
            "按服务分流：\(s.serviceTargets.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "，"))",
            "合并订阅：\(s.mergeAllProfiles)　备用订阅：\(s.backupProfileID != nil)",
            "网络规则 \(s.networkRules.count) 条　iCloud 同步：\(s.iCloudSync)",
            "自定义规则集：\(s.customRuleSets.map(\.summaryLine).joined(separator: "，"))　收藏节点 \(s.favoriteNodes.count) 个",
            "自动避开连不上的节点：\(s.avoidFailingNodes)　倍率上限：\(s.maxMultiplier > 0 ? String(s.maxMultiplier) : "不限")",
            "订阅：",
        ]
        for profile in controller.profiles {
            lines.append("  · \(profile.name)：\(profile.nodeCount) 个节点，\(profile.format ?? "?")，UA \(profile.workingUserAgent ?? "-")\(profile.lastError.map { "，错误：\($0)" } ?? "")")
            if let usage = profile.usage { lines.append("    用量：\(usage.summary)") }
        }
        lines.append("（不含订阅链接、令牌和控制密钥）")
        return lines.joined(separator: "\n")
    }
}
