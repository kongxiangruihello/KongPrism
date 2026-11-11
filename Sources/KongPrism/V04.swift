import AppKit
import CoreImage
import IOKit.ps
import KongPrismCore

// MARK: - 电源

/// Battery and Low Power Mode, followed through notifications (no polling).
@MainActor
final class PowerState {
    static let shared = PowerState()
    private(set) var onBattery = false
    private(set) var lowPower = false
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in PowerState.shared.refresh() }
        }
        if let loop = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerState.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            source = loop
        }
    }

    /// True when the Mac should not spend energy on extras (battery or Low Power Mode).
    var shouldSave: Bool { onBattery || lowPower }

    private func refresh() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type: String? = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        let battery = type == kIOPSBatteryPowerValue
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard battery != onBattery || low != lowPower else { return }
        onBattery = battery
        lowPower = low
        onChange?()
    }

    /// Seconds since the last keyboard or mouse event.
    static var idleSeconds: TimeInterval {
        [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}

// MARK: - 流量统计

/// Daily and per-subscription traffic. sing-box reports totals since it started; KongPrism samples
/// them only when the menu opens, once an hour (system-scheduled), and before the core stops.
struct TrafficStats: Codable, Equatable {
    struct Usage: Codable, Equatable {
        var up: Int64 = 0
        var down: Int64 = 0
        var total: Int64 { up + down }
    }

    var days: [String: Usage] = [:]
    var profiles: [String: Usage] = [:]
    var lastUp: Int64 = 0
    var lastDown: Int64 = 0

    static var url: URL { Paths.support.appendingPathComponent("traffic.json") }
    static func load() -> TrafficStats { Store.load(TrafficStats.self, from: url) ?? TrafficStats() }
    func save() { Store.save(self, to: Self.url) }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Adds what the core counted since the last sample. A smaller total means the core restarted.
    mutating func record(totalUp: Int64, totalDown: Int64, profile: String, on date: Date = Date()) {
        let up = totalUp >= lastUp ? totalUp - lastUp : totalUp
        let down = totalDown >= lastDown ? totalDown - lastDown : totalDown
        lastUp = totalUp
        lastDown = totalDown
        guard up > 0 || down > 0 else { return }
        let day = Self.dayFormatter.string(from: date)
        days[day, default: Usage()].up += up
        days[day, default: Usage()].down += down
        profiles[profile, default: Usage()].up += up
        profiles[profile, default: Usage()].down += down
        // Keep 120 days.
        let cutoff = Self.dayFormatter.string(from: date.addingTimeInterval(-120 * 86_400))
        days = days.filter { $0.key >= cutoff }
    }

    /// The core restarted: its counters start from zero again.
    mutating func coreRestarted() {
        lastUp = 0
        lastDown = 0
    }

    func usage(lastDays count: Int, until date: Date = Date()) -> [(day: Date, usage: Usage)] {
        (0..<count).reversed().map { offset in
            let day = Calendar.current.startOfDay(for: date.addingTimeInterval(-Double(offset) * 86_400))
            return (day, days[Self.dayFormatter.string(from: day)] ?? Usage())
        }
    }

    func total(since start: Date) -> Usage {
        let from = Self.dayFormatter.string(from: start)
        return days.filter { $0.key >= from }.values.reduce(Usage()) { Usage(up: $0.up + $1.up, down: $0.down + $1.down) }
    }
}

// MARK: - 局域网共享

enum LANShare {
    /// The Mac's IPv4 address on Wi-Fi / Ethernet.
    static var address: String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(String, String)] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((name, String(cString: host)))
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }

    static func qrCode(_ text: String, size: CGFloat = 180) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

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
            write("诊断.txt", "KongPrism \(AppUpdater.version)（\(AppUpdater.build)） · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n" + report)
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
                } catch {
                    write("订阅下载.txt", "下载失败：\(error.localizedDescription)\n（已附上本机缓存的节点结构）")
                }
            }
            // Logs last, so they include what happened while making this report.
            try? await Task.sleep(nanoseconds: 300_000_000)
            write("app.log", tail(Paths.appLog, lines: 400))
            write("core.log", tail(controller.core.logURL, lines: 400))
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
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "（没有日志）" }
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
