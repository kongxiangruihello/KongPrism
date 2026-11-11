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
    var openConnections: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "KongPrism"
        item.button?.setAccessibilityLabel("KongPrism")
        updateIcon()
        controller.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        controller.$speed.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSpeed() }.store(in: &cancellables)
        // Mode or enhanced mode changed: redraw the icon (only when they actually change).
        controller.$settings.map { "\($0.mode)|\($0.tunMode)|\($0.showSpeed)" }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.updateSpeed() }.store(in: &cancellables)
    }

    /// "↓1.2M ↑30K" beside the icon while the speed display is on.
    private func updateSpeed() {
        guard let button = item.button else { return }
        if controller.settings.showSpeed && controller.status.isRunning
            && !(controller.settings.pauseSpeedOnBattery && PowerState.shared.shouldSave) {
            item.length = NSStatusItem.variableLength
            let text = "↓\(SpeedText.compact(controller.speed.down)) ↑\(SpeedText.compact(controller.speed.up))"
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .baselineOffset: 1])
            button.imagePosition = .imageLeft
        } else if item.length != NSStatusItem.squareLength {
            button.attributedTitle = NSAttributedString(string: "")
            item.length = NSStatusItem.squareLength
        }
    }

    private func updateIcon() {
        let active = controller.status.isRunning
        var failed = false
        if case .failed = controller.status { failed = true }
        item.button?.image = PrismIcon.menuBar(active: active, failed: failed, mode: controller.settings.mode, tun: controller.settings.tunMode)
        item.button?.toolTip = active ? "KongPrism：已连接" : "KongPrism：未连接"
        item.button?.setAccessibilityLabel(item.button?.toolTip)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.verifyCoreAlive()
        build()
        guard controller.status.isRunning else { return }
        Task {
            await controller.refreshSnapshot()
            build() // while the menu is open, with fresh delays
            await controller.checkSelectedNode()
            await controller.checkFailover()
            await controller.refreshExitInfoIfNeeded()
            await controller.sampleTraffic()
            build()
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
        let headerItem = NSMenuItem(title: header + (controller.settings.tunMode && status.isRunning ? " · 增强模式" : ""), action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if case .failed = status { headerItem.attributedTitle = wrapped(header) }
        menu.addItem(headerItem)
        if status.isRunning, let exit = controller.exitInfo {
            let item = NSMenuItem(title: "出口：" + exit.summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let mismatch = controller.exitMismatch {
                let note = NSMenuItem(title: "    " + mismatch, action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.toolTip = "IP 归属来自公开数据库，中转线路或数据库滞后时也会不一致；只作参考"
                menu.addItem(note)
            }
        }
        if let notice = CrashRecords.notice {
            let item = action("⚠︎ " + notice + "（点此不再提示）", #selector(dismissCrashNotice), key: "")
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.menuFont(ofSize: 0)])
            item.toolTip = "崩溃记录会自动附在“生成问题报告”和“诊断连接”里"
            menu.addItem(item)
        }
        if let notice = controller.networkNotice {
            let item = NSMenuItem(title: "🛜 " + notice, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let notice = controller.nodeNotice {
            let item = action("⚠︎ " + notice + (notice.contains("已切回") ? "" : "，点此切回自动选择"), #selector(switchToAuto), key: "")
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.menuFont(ofSize: 0)])
            menu.addItem(item)
        }
        if status.isRunning, controller.settings.setSystemProxy, !controller.settings.tunMode, !SystemProxy.isPointing(to: controller.settings.mixedPort) {
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
        if controller.hotKeyRegistered {
            toggle.keyEquivalent = "p"
            toggle.keyEquivalentModifierMask = [.control, .option]
        }
        toggle.isEnabled = controller.selectedProfile != nil || status.isRunning
        menu.addItem(toggle)
        if controller.selectedProfile == nil {
            let hint = NSMenuItem(title: "复制订阅地址后再打开此菜单，或点网页上的“一键导入”", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(action("新手引导…", #selector(showOnboarding), key: ""))  // the first thing a new user needs
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
        // Tools in one submenu (0.7); their shortcuts still work while the menu is open.
        let tools = NSMenu()
        tools.autoenablesItems = false
        tools.addItem(action("复制终端代理命令", #selector(copyExports), key: "c"))
        tools.addItem(action("连接…", #selector(showConnections), key: "l"))
        tools.addItem(action("诊断连接…", #selector(diagnose), key: "d"))
        tools.addItem(action("生成问题报告", #selector(problemReport), key: ""))
        tools.addItem(.separator())
        tools.addItem(action("新手引导…", #selector(showOnboarding), key: ""))
        let toolsItem = NSMenuItem(title: "工具", action: nil, keyEquivalent: "")
        toolsItem.submenu = tools
        menu.addItem(toolsItem)
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
        // 按服务分流 status first (0.7: moved here from the top level to keep the menu short).
        var serviceLines = 0
        for service in Service.allCases {
            guard let group = snapshot.groups[service.groupName], let now = group.now else { continue }
            let line = NSMenuItem(title: "\(service.groupName) → \(now)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            submenu.addItem(line)
            serviceLines += 1
        }
        if !controller.droppedNodes.isEmpty {
            let dropped = NSMenuItem(title: "已跳过 \(controller.droppedNodes.count) 个内核不支持的节点", action: nil, keyEquivalent: "")
            dropped.isEnabled = false
            submenu.addItem(dropped)
            serviceLines += 1
        }
        if serviceLines > 0 { submenu.addItem(.separator()) }
        var addedSeparator = false
        var hidden = 0
        // 收藏的节点排在分组之后、其他节点之前。
        let favorites = Set(controller.settings.favoriteNodes)
        // Groups, then favorites, then the other nodes; 直连 last.
        let groups = selector.all.filter { snapshot.groups[$0] != nil }
        let plain = selector.all.filter { snapshot.groups[$0] == nil && $0 != Groups.direct }
        let favored = plain.filter { favorites.contains($0) }
        let ordered = groups + favored + plain.filter { !favorites.contains($0) } + (selector.all.contains(Groups.direct) ? [Groups.direct] : [])
        for name in ordered {
            let isGroup = snapshot.groups[name] != nil
            if controller.settings.hideDeadNodes, !isGroup, name != Groups.direct, snapshot.delays[name] == 0, selector.now != name {
                hidden += 1
                continue
            }
            if !isGroup, !addedSeparator || name == Groups.direct {
                submenu.addItem(.separator())
                addedSeparator = true
            }
            var title = name
            if isGroup, let now = snapshot.groups[name]?.now { title += "  → \(now)" }
            let entry = action(title, #selector(chooseNode(_:)), key: "")
            entry.representedObject = name
            entry.state = selector.now == name ? .on : .off
            let delayName = isGroup ? (snapshot.groups[name]?.now ?? name) : name
            let favorite = favorites.contains(name)
            entry.attributedTitle = row((favorite ? "★ " : "") + title, delay: name == Groups.direct ? nil : snapshot.delays[delayName])
            submenu.addItem(entry)
            if !isGroup, name != Groups.direct {
                // 按住 Option 时变成“收藏 / 取消收藏”。
                let star = action(favorite ? "取消收藏 \(name)" : "收藏 \(name)", #selector(toggleFavorite(_:)), key: "")
                star.representedObject = name
                star.isAlternate = true
                star.keyEquivalentModifierMask = [.option]
                submenu.addItem(star)
            }
            if favorite, name == favored.last, favored.count < plain.count {
                submenu.addItem(.separator())
            }
        }
        submenu.addItem(.separator())
        if hidden > 0 {
            let note = NSMenuItem(title: "已隐藏 \(hidden) 个不可用节点", action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }
        if favorites.isEmpty {
            let tip = NSMenuItem(title: "按住 Option 可收藏节点，收藏的排在最前", action: nil, keyEquivalent: "")
            tip.isEnabled = false
            submenu.addItem(tip)
        }
        submenu.addItem(action("全部节点…", #selector(showNodes), key: ""))
        let test = action(controller.testing ? "正在测速…" : "测速", #selector(testLatency), key: "t")
        test.isEnabled = !controller.testing
        submenu.addItem(test)
        return submenu
    }

    // MARK: Text dump (kongprism://menu, for CI: the status menu cannot be screenshotted there)

    /// The menu as indented text, after fetching fresh node state like opening it does.
    func dump() async -> String {
        // A reload may be under way (e.g. right after an iCloud sync): wait up to 10 s for it.
        for _ in 0..<100 where controller.status == .starting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        controller.verifyCoreAlive()
        if controller.status.isRunning { await controller.refreshSnapshot() }
        build()
        func lines(_ menu: NSMenu, depth: Int) -> [String] {
            menu.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return [String(repeating: "  ", count: depth) + "—"] }
                if item.isAlternate { return [] }
                var text = String(repeating: "  ", count: depth) + (item.attributedTitle?.string ?? item.title)
                if !item.keyEquivalent.isEmpty { text += "  [⌘\(item.keyEquivalent.uppercased())]" }
                if item.state == .on { text += "  ✓" }
                if !item.isEnabled && item.submenu == nil { text += "  (灰)" }
                return [text] + (item.submenu.map { lines($0, depth: depth + 1) } ?? [])
            }
        }
        return lines(menu, depth: 0).joined(separator: "\n")
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
    @objc private func problemReport() { ProblemReport.create(controller: controller) }
    @objc private func toggleFavorite(_ sender: NSMenuItem) { if let name = sender.representedObject as? String { controller.toggleFavorite(name) } }
    @objc private func dismissCrashNotice() { CrashRecords.dismissNotice() }
    @objc private func showOnboarding() { Onboarding.show() }
    @objc private func switchToAuto() { controller.select(Groups.auto, in: Groups.select) }
    @objc private func showNodes() { openSettings?(.nodes) }
    @objc private func showConnections() { openConnections?() }
    @objc private func reapplyProxy() { controller.reapplySystemProxy() }
    @objc private func showSettings() { openSettings?(.general) }
    @objc private func showUpdates() { openSettings?(.updates) }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Icons drawn in code: a prism splitting one beam into three.
enum PrismIcon {
    /// Rule: outline prism splitting the beam into three rays. Global: filled prism.
    /// Direct: the beam passes straight through. Enhanced mode: a small bar under the prism.
    static func menuBar(active: Bool, failed: Bool, mode: String = "Rule", tun: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let alpha: CGFloat = active ? 1 : 0.45
            NSColor.black.withAlphaComponent(alpha).setStroke()
            NSColor.black.withAlphaComponent(alpha).setFill()
            let prism = NSBezierPath()
            prism.move(to: NSPoint(x: 7.5, y: 15.5))
            prism.line(to: NSPoint(x: 13, y: 3.5))
            prism.line(to: NSPoint(x: 2, y: 3.5))
            prism.close()
            prism.lineWidth = 1.6
            prism.lineJoinStyle = .round
            prism.stroke()
            if active && mode.lowercased() == "global" { prism.fill() }
            let beam = NSBezierPath()
            beam.lineWidth = 1.3
            beam.lineCapStyle = .round
            beam.move(to: NSPoint(x: 0.5, y: 9.8))
            beam.line(to: NSPoint(x: 5.3, y: 8.9))
            if active && mode.lowercased() == "direct" {
                beam.move(to: NSPoint(x: 10.6, y: 8.9))
                beam.line(to: NSPoint(x: 17.3, y: 8.9))
            } else {
                for y in [12.8, 9.3, 5.8] {
                    beam.move(to: NSPoint(x: 10.6, y: 8.9))
                    beam.line(to: NSPoint(x: 17.3, y: y))
                }
            }
            beam.stroke()
            if active && tun {
                NSBezierPath(roundedRect: NSRect(x: 3, y: 0.3, width: 9, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            }
            if failed {
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
