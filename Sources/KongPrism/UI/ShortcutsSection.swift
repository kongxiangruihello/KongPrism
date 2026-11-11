import AppKit
import SwiftUI

/// 设置 › 常规 › 快捷指令: KongPrism's links ready to paste into the Shortcuts app's
/// “打开 URL” action (Siri and automations can then run them).
///
/// Native Shortcuts actions (App Intents) need the metadata Xcode extracts while building an app
/// target; KongPrism is built with Swift Package Manager, which has no such step, so the links
/// are the dependable way for now.
struct ShortcutsSection: View {
    @EnvironmentObject var controller: AppController

    private var items: [(String, String)] {
        var list = [("开启代理", "kongprism://connect"), ("关闭代理", "kongprism://disconnect"), ("开关代理", "kongprism://toggle"),
                    ("规则模式", "kongprism://mode/rule"), ("全局模式", "kongprism://mode/global"), ("直连模式", "kongprism://mode/direct"),
                    ("全部测速", "kongprism://test"), ("更新订阅", "kongprism://update")]
        if let node = controller.settings.favoriteNodes.first {
            list.append(("切到收藏的“\(node)”", "kongprism://node/" + (node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node)))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.1) { item in
                HStack {
                    Text(item.0).frame(width: 150, alignment: .leading)
                    Text(item.1).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.1, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("拷贝“\(item.0)”的链接")
                }
            }
            HStack {
                Text("在“快捷指令” App 里新建快捷指令 › 添加“打开 URL”动作 › 粘贴上面的链接。之后可以用 Siri 说出快捷指令的名字，或在“自动化”里设定触发条件（例如连上公司 Wi-Fi 时关闭代理）。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开快捷指令") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
        }
    }
}
