import AppKit
import CoreImage
import UniformTypeIdentifiers
import KongPrismCore

/// The convenient ways in: one-click links from provider websites, the clipboard
/// (text or a screenshot of a QR code), files, and drag and drop.
@MainActor
enum Importer {
    /// What the menu offers to import from the clipboard.
    struct Suggestion {
        let title: String
        let content: Content
        enum Content {
            case remote(ImportSource.RemoteProfile)
            case text(String)
        }
    }

    private static var handledChangeCount = -1

    /// Looks at the clipboard only when the menu opens, and only if it changed since
    /// the last import or dismissal.
    static func clipboardSuggestion(knownURLs: Set<String>) -> Suggestion? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != handledChangeCount else { return nil }
        if let text = pasteboard.string(forType: .string), let suggestion = suggestion(for: text, knownURLs: knownURLs) {
            return suggestion
        }
        if let image = NSImage(pasteboard: pasteboard) {
            for text in qrCodes(in: image) {
                if let suggestion = suggestion(for: text, knownURLs: knownURLs) {
                    return Suggestion(title: "识别到二维码 · " + suggestion.title, content: suggestion.content)
                }
            }
        }
        return nil
    }

    static func markClipboardHandled() { handledChangeCount = NSPasteboard.general.changeCount }

    private static func suggestion(for text: String, knownURLs: Set<String>) -> Suggestion? {
        switch ImportSource.classify(clipboard: text, knownURLs: knownURLs) {
        case .subscription(let profile)?:
            let host = URL(string: profile.url)?.host ?? profile.url
            return Suggestion(title: "添加剪贴板中的订阅（\(profile.name ?? host)）", content: .remote(profile))
        case .nodes(let count)?:
            return Suggestion(title: "导入剪贴板中的 \(count) 个节点", content: .text(text))
        case nil:
            return nil
        }
    }

    static func qrCodes(in image: NSImage) -> [String] {
        guard let tiff = image.tiffRepresentation, let ciImage = CIImage(data: tiff),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            return []
        }
        return detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    // MARK: Actions

    static func perform(_ suggestion: Suggestion, controller: AppController) {
        markClipboardHandled()
        switch suggestion.content {
        case .remote(let profile): addRemote(profile, controller: controller, confirm: false)
        case .text(let text): addText(text, name: "", controller: controller)
        }
    }

    /// clash://, sing-box://, kongprism:// links from a browser. Asks first, because any web page can open them.
    static func open(_ url: URL, controller: AppController) {
        if url.isFileURL { importFile(url, controller: controller); return }
        if URLActions.canHandle(url) { URLActions.handle(url, controller: controller); return }
        guard let profile = ImportSource.remoteProfile(fromImportLink: url.absoluteString) else {
            alert("无法识别的导入链接", detail: url.absoluteString)
            return
        }
        addRemote(profile, controller: controller, confirm: true)
    }

    static func addRemote(_ profile: ImportSource.RemoteProfile, controller: AppController, confirm: Bool) {
        if controller.profiles.contains(where: { $0.url == profile.url }) {
            controller.subscriptionTask = .done("这个订阅已经添加过了")
            return
        }
        var useNow = controller.profiles.isEmpty
        if confirm {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "添加订阅“\(profile.name ?? URL(string: profile.url)?.host ?? "新订阅")”？"
            alert.informativeText = "来自 \(URL(string: profile.url)?.host ?? profile.url)。添加后会立即下载节点。"
            alert.addButton(withTitle: "添加并使用")
            alert.addButton(withTitle: "仅添加")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: useNow = true
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        Task {
            do {
                let id = try await controller.addProfile(input: profile.url, name: profile.name ?? "")
                if useNow { controller.selectProfile(id, connect: true) }
            } catch {
                controller.subscriptionTask = .failed("添加失败：\(error.localizedDescription)")
                if confirm { alert("添加订阅失败", detail: error.localizedDescription) }
            }
        }
    }

    static func addText(_ text: String, name: String, controller: AppController) {
        Task {
            do {
                let id = try await controller.addProfile(input: text, name: name)
                if controller.profiles.count == 1 { controller.selectProfile(id, connect: true) }
                controller.subscriptionTask = .done("已导入")
            } catch {
                controller.subscriptionTask = .failed("导入失败：\(error.localizedDescription)")
            }
        }
    }

    /// The clipboard as is (menu: 订阅 › 从剪贴板导入).
    static func importClipboard(controller: AppController) {
        let pasteboard = NSPasteboard.general
        var candidates: [String] = []
        if let text = pasteboard.string(forType: .string) { candidates.append(text) }
        if let image = NSImage(pasteboard: pasteboard) { candidates += qrCodes(in: image) }
        markClipboardHandled()
        for text in candidates {
            if let profile = ImportSource.remoteProfile(fromImportLink: text) { addRemote(profile, controller: controller, confirm: false); return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http"), !trimmed.contains("\n") {
                addRemote(.init(url: trimmed, name: nil), controller: controller, confirm: false)
                return
            }
            if (try? SubscriptionParser.parse(Data(trimmed.utf8))) != nil { addText(trimmed, name: "", controller: controller); return }
        }
        controller.subscriptionTask = .failed("剪贴板里没有订阅地址、节点链接或二维码")
    }

    static func chooseFile(controller: AppController) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "选择 Clash / sing-box 配置、节点链接文本，或订阅二维码图片"
        panel.allowedContentTypes = [.yaml, .json, .plainText, .text, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, controller: controller)
    }

    static func importFile(_ url: URL, controller: AppController) {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url), let text = qrCodes(in: image).first else {
                controller.subscriptionTask = .failed("图片里没有找到二维码")
                return
            }
            if let profile = ImportSource.remoteProfile(fromImportLink: text) { addRemote(profile, controller: controller, confirm: false) }
            else if text.hasPrefix("http") { addRemote(.init(url: text, name: nil), controller: controller, confirm: false) }
            else { addText(text, name: "", controller: controller) }
            return
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            controller.subscriptionTask = .failed("无法读取 \(url.lastPathComponent)")
            return
        }
        addText(text, name: url.deletingPathExtension().lastPathComponent, controller: controller)
    }

    /// Lets the app's import scheme handle clash:// and sing-box:// links when the user asks.
    static func becomeDefaultHandler() async -> String {
        var done: [String] = []
        for scheme in ["clash", "sing-box", "kongprism"] {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                done.append(scheme)
            } catch {
                AppLog.write("设为 \(scheme):// 默认打开方式失败：\(error.localizedDescription)")
            }
        }
        return done.isEmpty ? "设置失败（macOS 可能要求先确认）" : "网页上的“一键导入”现在会打开 KongPrism（\(done.map { $0 + "://" }.joined(separator: "、"))）"
    }

    static func alert(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
