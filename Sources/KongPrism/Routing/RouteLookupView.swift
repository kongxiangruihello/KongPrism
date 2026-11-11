import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 走哪条线

struct RouteLookupView: View {
    @EnvironmentObject var controller: AppController
    @State private var input = ""
    @State private var answer: RouteExplainer.Answer?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("输入网址或域名，例如 scholar.google.com", text: $input).onSubmit(lookup)
                Button("查询", action: lookup).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            if let answer {
                HStack(alignment: .top) {
                    Image(systemName: symbol(answer.target)).foregroundStyle(color(answer.target))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(answer.host)：\(title(answer.target))").fontWeight(.medium)
                        Text(answer.reason).font(.caption).foregroundStyle(.secondary)
                        if answer.target == .proxy || answer.target == .byIP, let node = currentNode {
                            Text("当前节点：\(node)").font(.caption).foregroundStyle(.secondary)
                        }
                        if case .service(let group) = answer.target, let now = controller.snapshot.groups[group]?.now {
                            Text("该分组当前节点：\(now)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if answer.target != .direct {
                        Button("改为总是直连") { add(to: \.directDomains) }
                    }
                    if answer.target != .proxy {
                        Button("改为总是走代理") { add(to: \.proxyDomains) }
                    }
                }
            }
        }
    }

    private var currentNode: String? {
        guard let now = controller.snapshot.groups[Groups.select]?.now else { return nil }
        return controller.snapshot.groups[now]?.now.map { "\(now) → \($0)" } ?? now
    }

    private func lookup() {
        let text = input
        let options = controller.settings.coreOptions
        let core = controller.core
        busy = true
        Task {
            answer = await Shell.background {
                RouteExplainer.explain(text, options: options) { set, host in core.ruleSetContains(set, host) }
            }
            busy = false
        }
    }

    private func add(to keyPath: WritableKeyPath<AppSettings, [String]>) {
        guard let host = answer?.host, !host.isEmpty else { return }
        controller.settings.directDomains.removeAll { $0 == host }
        controller.settings.proxyDomains.removeAll { $0 == host }
        controller.settings[keyPath: keyPath].append(host)
        controller.rulesChanged()
        controller.reloadIfRunning()
        lookup()
    }

    private func title(_ target: RouteExplainer.Target) -> String {
        switch target {
        case .direct: return "直连"
        case .proxy: return "走节点"
        case .reject: return "拦截"
        case .byIP: return "看 IP 决定"
        case .service(let group): return "走 \(group)"
        }
    }
    private func symbol(_ target: RouteExplainer.Target) -> String {
        switch target {
        case .direct: return "arrow.right.circle"
        case .proxy: return "globe"
        case .reject: return "nosign"
        case .byIP: return "questionmark.circle"
        case .service: return "sparkles"
        }
    }
    private func color(_ target: RouteExplainer.Target) -> Color {
        switch target {
        case .direct: return .green
        case .proxy: return .blue
        case .reject: return .red
        case .byIP: return .orange
        case .service: return .purple
        }
    }
}
