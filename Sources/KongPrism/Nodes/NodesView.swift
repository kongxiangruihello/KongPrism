import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 节点（全部测速与排序、备用订阅）

struct NodesView: View {
    @EnvironmentObject var controller: AppController
    @State private var sortByDelay = true
    @State private var failures: [String: Int] = [:]
    @State private var failuresSince: String?

    private var nodes: [String] {
        let all = controller.snapshot.groups[Groups.select]?.all ?? []
        let list = all.filter { controller.snapshot.groups[$0] == nil && $0 != Groups.direct }
        let favorites = Set(controller.settings.favoriteNodes)
        let sorted = sortByDelay ? list.sorted { a, b in rank(a) < rank(b) } : list
        // 收藏的节点排在最前（稳定排序，保留延迟顺序）。
        return sorted.filter { favorites.contains($0) } + sorted.filter { !favorites.contains($0) }
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
            NodeQualityBar(failures: $failures, since: $failuresSince)
            let current = controller.snapshot.groups[Groups.select]?.now
            List(nodes, id: \.self) { name in
                HStack {
                    Image(systemName: current == name ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(current == name ? Color.accentColor : .secondary)
                        .accessibilityLabel(current == name ? "正在使用" : "未使用")
                    let favorite = controller.settings.favoriteNodes.contains(name)
                    Button { controller.toggleFavorite(name) } label: {
                        Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(favorite ? "取消收藏" : "收藏：在菜单里排在最前")
                    .accessibilityLabel(favorite ? "取消收藏 \(name)" : "收藏 \(name)")
                    Text(name)
                    if controller.backupTags.contains(name) {
                        Text("备用").font(.caption2).padding(.horizontal, 4).background(Color.orange.opacity(0.2)).cornerRadius(3)
                    }
                    Text(controller.nodeProtocols[name] ?? "").font(.caption).foregroundStyle(.secondary)
                    if let rate = NodeFilter.multiplier(name) {
                        let limit = controller.settings.maxMultiplier
                        Text(String(format: rate < 1 ? "%.2g×" : "%.3g×", rate)).font(.caption2.monospacedDigit())
                            .padding(.horizontal, 4)
                            .background((limit > 0 && rate > limit ? Color.gray : rate < 1 ? Color.green : rate > 1 ? Color.orange : Color.blue).opacity(0.18))
                            .cornerRadius(3)
                            .help(limit > 0 && rate > limit ? "倍率高于设置，自动选择不会用它" : "流量倍率")
                    }
                    if controller.avoidedNodes[name].map({ $0 > Date() }) == true {
                        Text("暂避").font(.caption2).padding(.horizontal, 4).background(Color.orange.opacity(0.2)).cornerRadius(3)
                    }
                    Spacer()
                    if let count = failures[name], count > 0 {
                        Text("24h 失败 \(count)").font(.caption.monospacedDigit())
                            .foregroundStyle(count >= 20 ? Color.red : count >= 5 ? Color.orange : Color.secondary)
                    }
                    delayText(controller.snapshot.delays[name])
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { controller.select(name, in: Groups.select) }
            }
            Text("双击使用该节点；点 ☆ 收藏，收藏的节点在菜单里排在最前。共 \(nodes.count) 个，可用 \(nodes.filter { (controller.snapshot.delays[$0] ?? 0) > 0 }.count) 个。")
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
