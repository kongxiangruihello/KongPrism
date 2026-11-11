import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 按网络自动切换

struct NetworkRulesView: View {
    @EnvironmentObject var controller: AppController
    @State private var name = ""
    @State private var action: NetworkRule.Action = .direct

    var body: some View {
        Toggle("按所连的网络自动切换", isOn: $controller.settings.networkAutomation)
        if let current = controller.networkCurrent {
            HStack {
                Text("当前网络：\(current.label)")
                if let rule = controller.settings.networkRules.first(where: { $0.routerMAC == current.routerMAC }) {
                    Text("（规则：\(rule.name) → \(rule.action.title)）").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("名称", text: $name, prompt: Text("如“家里”“单位”")).labelsHidden().frame(maxWidth: 160)
                Picker("连上时", selection: $action) {
                    ForEach(NetworkRule.Action.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 200)
                Button("为当前网络添加") { controller.addRuleForCurrentNetwork(name: name, action: action); name = "" }
            }
        } else {
            Text("当前没有可识别的网络。").foregroundStyle(.secondary)
        }
        ForEach(controller.settings.networkRules) { rule in
            HStack {
                Text(rule.name)
                Text("→ \(rule.action.title)").foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { controller.removeNetworkRule(rule.id) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("删除这条网络规则")
                    .buttonStyle(.borderless)
            }
        }
        Text("按路由器识别网络，不需要定位权限。离开该网络后自动恢复原来的模式或重新开启代理。")
            .font(.caption).foregroundStyle(.secondary)
    }
}
