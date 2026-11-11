import AppKit
import Combine
import KongPrismCore

/// The menu bar item. The menu is rebuilt each time it opens (sing-box is asked for
/// node state only then), so nothing polls in the background.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let controller = AppController.shared
    private var cancellables: Set<AnyCancellable> = []
    private var clipboardSuggestion: Importer.Suggestion?
    var openSettings: ((SettingsTab) -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "KongPrism"
        updateIcon()
        controller.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
    }

    private func updateIcon() {
        let active = controller.status.isRunning
        var failed = false
        if case .failed = controller.status { failed = true }
        item.button?.image = PrismIcon.menuBar(active: active, failed: failed)
        item.button?.toolTip = active ? "KongPrism：已连接" : "KongPrism：未连接"
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        build()
        guard controller.status.isRunning else { return }
        Task {
            await controller.refreshSnapshot()
            build() // while the menu is open, with fresh delays
        }
    }

    // MARK: Building

    private func build() {
        menu.removeAllItems()
        let status = controller.status

        let header: String
        switch status {
        case .running: header = "● 已连接 · \(modeName(controller.settings.mode))"
        case .starting: header = "◐ 正在连接…"
        case .stopped: header = "○ 未连接"
        case .failed(let message): header = "⚠︎ \(message)"
        }
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if case .failed = status { headerItem.attributedTitle = wrapped(header) }
        menu.addItem(headerItem)
        if status.isRunning, controller.settings.setSystemProxy, !SystemProxy.isPointing(to: controller.settings.mixedPort) {
            let item = action("⚠︎ 系统代理被其他软件改掉了，点此重新设置", #selector(reapplyProxy), key: "")
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.menuFont(ofSize: 0)])
            menu.addItem(item)
        }
        if let warning = controller.usageWarning {
            let item = NSMenuItem(title: "⚠︎ " + warning, action: #selector(manageProfiles), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: "⚠︎ " + warning, attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.menuFont(ofSize: 0)])
            menu.addItem(item)
        }
        // Something importable on the clipboard (subscription link, nodes, a QR screenshot).
        clipboardSuggestion = Importer.clipboardSuggestion(knownURLs: controller.knownSubscriptionURLs)
        if let suggestion = clipboardSuggestion {
            let item = action("📋 " + suggestion.title, #selector(acceptClipboard), key: "v")
            menu.addItem(item)
            let ignore = action("忽略剪贴板内容", #selector(ignoreClipboard), key: "")
            ignore.isAlternate = true
            ignore.keyEquivalentModifierMask = [.command, .option]
            ignore.keyEquivalent = "v"
            menu.addItem(ignore)
        }

        let toggle = action(status.isRunning || status == .starting ? "关闭代理" : "开启代理", #selector(toggleConnection), key: "")
        toggle.isEnabled = controller.selectedProfile != nil || status.isRunning
        menu.addItem(toggle)
        if controller.selectedProfile == nil {
            let hint = NSMenuItem(title: "复制订阅地址后再打开此菜单，或点网页上的“一键导入”", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())

        // Mode
        let modeMenu = NSMenu()
        for mode in ["Rule", "Global", "Direct"] {
            let entry = action(modeName(mode), #selector(chooseMode(_:)), key: "")
            entry.representedObject = mode
            entry.state = controller.settings.mode == mode ? .on : .off
            modeMenu.addItem(entry)
        }
        let modeItem = NSMenuItem(title: "出站模式：\(modeName(controller.settings.mode))", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Nodes
        if status.isRunning, let selector = controller.snapshot.groups[Groups.select] {
            let nodeItem = NSMenuItem(title: "节点：\(describe(selector.now ?? "—"))", action: nil, keyEquivalent: "")
            nodeItem.submenu = nodeMenu(selector)
            menu.addItem(nodeItem)
            if !controller.droppedNodes.isEmpty {
                let dropped = NSMenuItem(title: "已跳过 \(controller.droppedNodes.count) 个内核不支持的节点", action: nil, keyEquivalent: "")
                dropped.isEnabled = false
                menu.addItem(dropped)
            }
        }

        // Profiles
        let profileMenu = NSMenu()
        let merging = controller.settings.mergeAllProfiles && controller.profiles.count > 1
        for profile in controller.profiles {
            let entry = action(profile.name, #selector(chooseProfile(_:)), key: "")
            entry.representedObject = profile.id
            entry.state = merging ? .mixed : (controller.selectedProfile?.id == profile.id ? .on : .off)
            var detail = "\(profile.nodeCount) 个节点"
            if let usage = profile.usage { detail += " · " + usage.summary }
            if let error = profile.lastError { detail = "更新失败：" + (error.count > 40 ? String(error.prefix(40)) + "…" : error) }
            entry.toolTip = detail
            profileMenu.addItem(entry)
            let info = NSMenuItem(title: "    " + detail, action: nil, keyEquivalent: "")
            info.isEnabled = false
            info.attributedTitle = NSAttributedString(string: "    " + detail, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: profile.lastError == nil && profile.nodeCount > 0 ? NSColor.secondaryLabelColor : NSColor.systemRed])
            profileMenu.addItem(info)
        }
        if controller.profiles.count > 1 {
            let merge = action("合并全部订阅", #selector(toggleMerge), key: "")
            merge.state = merging ? .on : .off
            merge.toolTip = "把所有订阅的节点放在一起，统一自动选择和按地区分组"
            profileMenu.addItem(merge)
        }
        if !controller.profiles.isEmpty { profileMenu.addItem(.separator()) }
        if controller.profiles.contains(where: \.isRemote) {
            profileMenu.addItem(action("更新全部订阅", #selector(updateSubscriptions), key: "u"))
        }
        profileMenu.addItem(action("从剪贴板导入（链接 / 节点 / 二维码截图）", #selector(importClipboard), key: ""))
        profileMenu.addItem(action("从文件导入…", #selector(importFile), key: ""))
        profileMenu.addItem(action("管理订阅…", #selector(manageProfiles), key: ""))
        let profileTitle = merging ? "全部 \(controller.profiles.count) 个（合并）" : (controller.selectedProfile?.name ?? "无")
        let profileItem = NSMenuItem(title: "订阅：\(profileTitle)", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        menu.addItem(.separator())
        menu.addItem(action("复制终端代理命令", #selector(copyExports), key: "c"))
        menu.addItem(action("诊断连接…", #selector(diagnose), key: "d"))
        if controller.appRelease != nil || controller.latestCore != nil {
            let update = action("有可用更新…", #selector(showUpdates), key: "")
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
        }
        menu.addItem(action("设置…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("退出 KongPrism", #selector(quit), key: "q"))
    }

    private func nodeMenu(_ selector: ClashAPI.Group) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let snapshot = controller.snapshot
        var addedSeparator = false
        for name in selector.all {
            let isGroup = snapshot.groups[name] != nil
            if !isGroup, !addedSeparator {
                submenu.addItem(.separator())
                addedSeparator = true
            }
            var title = name
            if isGroup, let now = snapshot.groups[name]?.now { title += "  → \(now)" }
            let entry = action(title, #selector(chooseNode(_:)), key: "")
            entry.representedObject = name
            entry.state = selector.now == name ? .on : .off
            let delayName = isGroup ? (snapshot.groups[name]?.now ?? name) : name
            entry.attributedTitle = row(title, delay: name == Groups.direct ? nil : snapshot.delays[delayName])
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let test = action(controller.testing ? "正在测速…" : "测速", #selector(testLatency), key: "t")
        test.isEnabled = !controller.testing
        submenu.addItem(test)
        return submenu
    }

    // MARK: Helpers

    private func describe(_ name: String) -> String {
        if let group = controller.snapshot.groups[name], let now = group.now { return "\(name) → \(now)" }
        return name
    }

    private func modeName(_ mode: String) -> String {
        switch mode.lowercased() {
        case "global": return "全局"
        case "direct": return "直连"
        default: return "规则"
        }
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    /// "HK 01        123 ms" with the delay right-aligned and coloured.
    private func row(_ title: String, delay: Int?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        guard let delay else { return text }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 360)]
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        let color: NSColor = delay == 0 ? .systemRed : delay < 200 ? .systemGreen : delay < 500 ? .systemOrange : .systemRed
        text.append(NSAttributedString(string: "\t" + (delay == 0 ? "超时" : "\(delay) ms"), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: color, .paragraphStyle: paragraph]))
        return text
    }

    private func wrapped(_ text: String) -> NSAttributedString {
        let short = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return NSAttributedString(string: short, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
    }

    // MARK: Actions

    @objc private func toggleConnection() { controller.toggle() }
    @objc private func chooseMode(_ sender: NSMenuItem) { if let mode = sender.representedObject as? String { controller.setMode(mode) } }
    @objc private func chooseNode(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { controller.select(name, in: Groups.select) }
    }
    @objc private func chooseProfile(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { controller.selectProfile(id) } }
    @objc private func testLatency() { controller.testLatency() }
    @objc private func updateSubscriptions() { Task { await controller.updateAllProfiles() } }
    @objc private func importClipboard() { controller.importFromClipboard() }
    @objc private func importFile() { Importer.chooseFile(controller: controller) }
    @objc private func toggleMerge() { controller.setMergeAllProfiles(!controller.settings.mergeAllProfiles) }
    @objc private func acceptClipboard() { if let suggestion = clipboardSuggestion { Importer.perform(suggestion, controller: controller) } }
    @objc private func ignoreClipboard() { Importer.markClipboardHandled() }
    @objc private func manageProfiles() { openSettings?(.profiles) }
    @objc private func copyExports() { controller.copyShellExports() }
    @objc private func diagnose() { Diagnostics.show(controller: controller) }
    @objc private func reapplyProxy() { controller.reapplySystemProxy() }
    @objc private func showSettings() { openSettings?(.general) }
    @objc private func showUpdates() { openSettings?(.updates) }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Icons drawn in code: a prism splitting one beam into three.
enum PrismIcon {
    static func menuBar(active: Bool, failed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let alpha: CGFloat = active ? 1 : 0.45
            NSColor.black.withAlphaComponent(alpha).setStroke()
            NSColor.black.withAlphaComponent(alpha).setFill()
            // Prism
            let prism = NSBezierPath()
            prism.move(to: NSPoint(x: 7.5, y: 15.5))
            prism.line(to: NSPoint(x: 13, y: 3))
            prism.line(to: NSPoint(x: 2, y: 3))
            prism.close()
            prism.lineWidth = 1.6
            prism.lineJoinStyle = .round
            prism.stroke()
            // Incoming beam and three outgoing rays
            let beam = NSBezierPath()
            beam.lineWidth = 1.3
            beam.lineCapStyle = .round
            beam.move(to: NSPoint(x: 0.5, y: 9.5))
            beam.line(to: NSPoint(x: 5.3, y: 8.6))
            for y in [12.5, 9.0, 5.5] {
                beam.move(to: NSPoint(x: 10.6, y: 8.6))
                beam.line(to: NSPoint(x: 17.3, y: y))
            }
            beam.stroke()
            if failed {
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
