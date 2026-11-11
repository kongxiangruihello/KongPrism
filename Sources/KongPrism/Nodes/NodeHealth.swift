import AppKit
import SwiftUI
import KongPrismCore

enum LogTail {
    /// The last `bytes` of a log file (the core log can reach 5 MB).
    static func read(_ url: URL, bytes: Int = 512 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

extension AppController {
    // MARK: 自动避开连不上的节点

    /// sing-box's automatic groups choose by a test URL only; a node that answers the test but
    /// keeps failing real connections stays selected. Every 15 minutes (the existing node-health
    /// schedule) the core log is read: a node with 5+ failed connections in that window is left
    /// out of 自动选择, the region groups and the service groups for an hour. The core is reloaded
    /// only if such a node is in use right now; otherwise the change waits for the next reload.
    func checkFailingNodes() async {
        guard settings.avoidFailingNodes, status.isRunning else { return }
        let url = core.logURL
        let since = Date().addingTimeInterval(-NodeAvoidance.window)
        let failing = await Shell.background { CoreLogStats.failingNodes(LogTail.read(url), since: since, threshold: NodeAvoidance.threshold) }
        await refreshSnapshot()
        // What the automatic groups use right now.
        let groups = [Groups.auto] + Service.allCases.map(\.groupName) + Region.all.map(\.groupName)
        let decision = NodeAvoidance.decide(failing: failing, current: avoidedNodes, handPicked: snapshot.groups[Groups.select]?.now,
                                            inUse: groups.compactMap { snapshot.groups[$0]?.now })
        setAvoidedNodes(decision.avoided)
        guard let first = decision.newlyAvoided.first else { return }
        let names = decision.newlyAvoided.map { "\($0.node)（\($0.count) 次）" }.joined(separator: "、")
        AppLog.write("近 15 分钟连不上：\(names)，自动选择暂时避开 1 小时")
        if decision.reloadNow {
            showNodeNotice("\(first.node) 近 15 分钟连不上 \(first.count) 次，已暂时避开 1 小时")
            reloadIfRunning()
        }
    }

    /// Forget the avoided nodes (from 设置 › 节点).
    func clearAvoidedNodes() {
        setAvoidedNodes([:])
        reloadIfRunning()
    }

    // MARK: 唤醒 / 切换网络后快速恢复

    /// Connections opened before sleep or on the previous network are dead but apps wait for
    /// them to time out. Close them so apps reconnect at once, and re-test the automatic group
    /// for the new network. At most once every 20 seconds.
    func recoverConnections(reason: String, force: Bool = false) async {
        guard status.isRunning, force || Date().timeIntervalSince(lastRecoveryDate) > 20 else { return }
        markRecovery()
        await api.closeConnections()
        let groups = [Groups.auto] + options(forRecovery: snapshot)
        for group in groups {
            _ = try? await api.testGroup(group, url: settings.testURL, timeoutMs: 5000)
        }
        AppLog.write("\(reason)后已断开旧连接并重新测速（\(groups.joined(separator: "、"))）")
        await refreshSnapshot()
    }

    /// Service groups that exist in the running config.
    private func options(forRecovery snapshot: ClashAPI.Snapshot) -> [String] {
        Service.allCases.map(\.groupName).filter { snapshot.groups[$0] != nil }
    }

    // MARK: 节点稳定性（节点页）

    /// Failed connections per node in the last 24 hours, from the core log.
    func nodeFailureCounts() async -> (counts: [String: Int], since: String?) {
        let url = core.logURL
        let since = Date().addingTimeInterval(-24 * 3600)
        let summary = await Shell.background { CoreLogStats.summarize(LogTail.read(url, bytes: 2 * 1024 * 1024), since: since) }
        return (Dictionary(uniqueKeysWithValues: summary.nodes.map { ($0.node, $0.count) }), summary.firstTime)
    }

    // MARK: 出口与节点名称

    /// "节点名称是日本，出口 IP 归属美国" when they differ (IP databases can be wrong too).
    var exitMismatch: String? { exitMismatch(for: exitInfo) }

    func exitMismatch(for exit: ExitInfo?) -> String? {
        guard status.isRunning, let exit, let exitCode = exit.countryCode else { return nil }
        var name = snapshot.groups[Groups.select]?.now ?? ""
        for _ in 0..<3 { if let next = snapshot.groups[name]?.now { name = next } else { break } }
        guard name != Groups.direct, let nodeCode = NodeCountry.code(for: name), nodeCode != exitCode else { return nil }
        // Hong Kong / Macau / Taiwan relays are often registered in mainland ranges; still worth showing.
        let label = { (code: String) in ExitInfo(ip: "", countryCode: code, country: nil, city: nil, organization: nil).placeName }
        return "节点名称是\(label(nodeCode))，出口 IP 归属\(label(exitCode))"
    }
}
