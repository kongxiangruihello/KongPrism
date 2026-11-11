import AppKit
import Charts
import SwiftUI
import KongPrismCore

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
