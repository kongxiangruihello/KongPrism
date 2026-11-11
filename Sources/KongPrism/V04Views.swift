import AppKit
import Charts
import SwiftUI
import KongPrismCore

// MARK: - 统计

struct StatsView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        let days = controller.stats.usage(lastDays: 30)
        let today = controller.stats.total(since: Calendar.current.startOfDay(for: Date()))
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
        let month = controller.stats.total(since: monthStart)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                stat("今天", today)
                stat("本月", month)
                stat("近 30 天", days.reduce(TrafficStats.Usage()) { TrafficStats.Usage(up: $0.up + $1.usage.up, down: $0.down + $1.usage.down) })
                Spacer()
            }
            Chart {
                ForEach(days, id: \.day) { item in
                    BarMark(x: .value("日期", item.day, unit: .day), y: .value("下载", Double(item.usage.down) / 1_048_576))
                        .foregroundStyle(by: .value("方向", "下载"))
                    BarMark(x: .value("日期", item.day, unit: .day), y: .value("上传", Double(item.usage.up) / 1_048_576))
                        .foregroundStyle(by: .value("方向", "上传"))
                }
            }
            .chartYAxisLabel("MB")
            .frame(minHeight: 200)
            GroupBox("按订阅") {
                VStack(alignment: .leading, spacing: 4) {
                    let rows = controller.stats.profiles.sorted { $0.value.total > $1.value.total }
                    if rows.isEmpty { Text("还没有数据").foregroundStyle(.secondary) }
                    ForEach(rows, id: \.key) { name, usage in
                        HStack {
                            Text(name)
                            Spacer()
                            Text("↓\(SubscriptionUsage.bytes(usage.down))  ↑\(SubscriptionUsage.bytes(usage.up))")
                                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }
            HStack {
                Text("经过 KongPrism 的流量（含直连部分），在打开菜单、每小时一次和关闭代理时记录，后台不常驻。保留 120 天。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清除统计") { controller.clearStats() }
            }
        }
        .task { await controller.sampleTraffic(force: false) }
    }

    private func stat(_ title: String, _ usage: TrafficStats.Usage) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(SubscriptionUsage.bytes(usage.total)).font(.title3.weight(.semibold))
        }
    }
}

// MARK: - 按服务分流

struct ServiceRoutingSection: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        ForEach(Service.allCases, id: \.self) { service in
            Picker(service.title, selection: Binding(
                get: { controller.settings.serviceTargets[service.rawValue] ?? Service.follow },
                set: { controller.setServiceTarget(service, $0) })) {
                ForEach(Service.targets, id: \.self) { Text(Service.targetTitle($0)).tag($0) }
            }
        }
        Text("每项单独选一个地区，在那个地区的节点里自动挑最快的（只在用到时测速）。没有该地区的节点时用全部节点。"
             + "注意：部分服务对使用地区有自己的规定。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - 局域网共享

struct LANShareView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if let ip = LANShare.address {
            let address = "\(ip):\(controller.settings.mixedPort)"
            HStack(alignment: .top, spacing: 16) {
                if let qr = LANShare.qrCode(address) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("其他设备的代理地址").font(.caption).foregroundStyle(.secondary)
                    Text(address).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Text("iPhone / iPad：设置 › 无线局域网 › 当前网络的 ⓘ › 配置代理 › 手动，服务器填 \(ip)，端口填 \(controller.settings.mixedPort)。也可以用相机扫码后复制地址。HTTP 与 SOCKS5 共用这个端口。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("同一网络里的任何设备都能使用，不用时请关掉。").font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            Text("没有找到这台 Mac 的局域网地址。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
