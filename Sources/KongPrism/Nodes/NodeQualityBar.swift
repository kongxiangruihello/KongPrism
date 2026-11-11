import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 节点页的倍率与稳定性

struct NodeQualityBar: View {
    @EnvironmentObject var controller: AppController
    @Binding var failures: [String: Int]
    @Binding var since: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("自动选择只用倍率", selection: Binding(get: { controller.settings.maxMultiplier }, set: { value in
                    controller.settings.maxMultiplier = value
                    controller.reloadIfRunning()
                })) {
                    Text("不限").tag(0.0)
                    Text("≤ 1 倍").tag(1.0)
                    Text("≤ 0.5 倍").tag(0.5)
                }
                .frame(maxWidth: 260)
                Spacer()
                Toggle("自动避开连不上的节点", isOn: $controller.settings.avoidFailingNodes)
                    .help("近 15 分钟连不上 5 次以上的节点，自动选择、地区和按服务分组暂时避开 1 小时；手选的节点不受影响")
            }
            let avoided = controller.avoidedNodes.filter { $0.value > Date() }
            if !avoided.isEmpty {
                HStack {
                    Text("正在避开：\(avoided.keys.sorted().joined(separator: "、"))").font(.caption).foregroundStyle(.orange)
                    Button("不再避开") { controller.clearAvoidedNodes() }.controlSize(.small)
                }
            }
            Text("倍率从节点名称识别（如“流量倍率:0.2”“0.5x”）；手选节点不受限制。右侧“24h 失败”来自内核日志\(since.map { "（自 \($0.suffix(8).prefix(5)) 起）" } ?? "")，只统计连接失败，不含断网时的报错。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let result = await controller.nodeFailureCounts()
        failures = result.counts
        since = result.since
    }
}
