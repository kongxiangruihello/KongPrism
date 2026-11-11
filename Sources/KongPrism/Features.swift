import AppKit
import Carbon
import KongPrismCore

// MARK: - 出口信息

/// Looks up where traffic leaves the proxy. Asked only when the menu opens, at most every
/// five minutes or after a node / mode change, so it costs nothing in the background.
enum ExitLookup {
    static let services = ["https://api.ip.sb/geoip", "https://ipinfo.io/json"]

    static func fetch(port: Int) async -> ExitInfo? {
        for service in services {
            guard let url = URL(string: service),
                  let (data, _) = try? await Net.get(url, headers: ["User-Agent": "curl/8.7.1", "Accept": "application/json"],
                                                     routes: [.viaProxy(port: port)], timeout: 6),
                  let json = JSONValue.parse(data), let info = ExitInfo(json: json) else { continue }
            return info
        }
        return nil
    }
}

// MARK: - 菜单栏网速

/// Reads sing-box's /traffic stream (one line per second) while the speed display is on.
@MainActor
final class TrafficMonitor {
    private var task: Task<Void, Never>?
    var onUpdate: ((Int64, Int64) -> Void)?

    var isRunning: Bool { task != nil }

    func start(api: ClashAPI) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.stream(api)
                // The stream ends when the core restarts; try again shortly.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func stream(_ api: ClashAPI) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(api.port)/traffic")!)
        request.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3600
        let session = Net.session(.direct, timeout: 3600)
        defer { session.invalidateAndCancel() }
        guard let (bytes, _) = try? await session.bytes(for: request) else { return }
        do {
            for try await line in bytes.lines {
                guard let json = JSONValue.parse(Data(line.utf8)) else { continue }
                let up = Int64(json["up"]?.intValue ?? 0)
                let down = Int64(json["down"]?.intValue ?? 0)
                onUpdate?(up, down)
            }
        } catch {}
    }
}

// MARK: - 全局快捷键

/// ⌃⌥P toggles the proxy from any app (Carbon hot keys need no Accessibility permission).
@MainActor
final class HotKey {
    static let shared = HotKey()
    static let display = "⌃⌥P"

    private var reference: EventHotKeyRef?
    private var handlerInstalled = false
    private var action: (() -> Void)?

    /// Returns false when another app already uses the combination.
    @discardableResult
    func register(_ action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4B505253), id: 1) // 'KPRS'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        reference = ref
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    fileprivate func fire() { action?() }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in HotKey.shared.fire() }
            return noErr
        }, 1, &type, nil, nil)
    }
}

// MARK: - 其他代理软件

enum OtherClients {
    static let markers = ["kongbabel", "kong.networkconsole", "clash", "verge", "mihomo", "v2ray", "shadowrocket", "surge", "hiddify",
                          "sing-box", "singbox", "stash", "quantumult", "loon", "flclash", "nekoray", "clashx"]

    static func running() -> [NSRunningApplication] {
        let own = Bundle.main.bundleIdentifier?.lowercased()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier?.lowercased(), id != own else { return false }
            return markers.contains { id.contains($0) }
        }
    }

    /// Asks the user (they started connecting) whether to quit the other clients first.
    /// Returns false when they cancel.
    @MainActor
    static func resolveBeforeConnecting() async -> Bool {
        let others = running()
        guard !others.isEmpty else { return true }
        let names = others.map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }.joined(separator: "、")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(names) 正在运行"
        alert.informativeText = "两个代理软件同时开启，会互相改写系统代理或抢占网络，常常导致上不了网。建议先退出它。"
        alert.addButton(withTitle: "退出它并继续")
        alert.addButton(withTitle: "仍然继续")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for app in others { app.terminate() }
            // Give them time to put their system proxy back.
            for _ in 0..<30 where others.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            for app in others where !app.isTerminated { app.forceTerminate() }
            AppLog.write("已退出 \(names)")
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - iCloud 云盘同步

/// Keeps subscriptions and custom rules in iCloud Drive (~/Library/Mobile Documents/com~apple~CloudDocs/KongPrism),
/// so another Mac signed in to the same Apple ID picks them up. Ports, secrets and tokens are not synced.
/// Merging only adds: a subscription deleted on one Mac is not deleted on the others.
enum ICloudSync {
    struct Payload: Codable {
        struct Entry: Codable {
            var id: UUID
            var name: String
            var url: String?
            var userAgent: String?
            var workingUserAgent: String?
            /// Local (pasted) profiles carry their nodes; remote ones are downloaded again.
            var nodes: [ProxyNode]?
        }
        var version = 1
        var updatedAt: Date
        var device: String
        var profiles: [Entry]
        var directDomains: [String]
        var proxyDomains: [String]
        var rulesChangedAt: Date?
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/KongPrism", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("sync.json") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
    }

    static func write(_ bundle: Payload) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(to: file, options: .atomic)
    }

    static func read() -> Payload? {
        // An iCloud placeholder (not downloaded yet) is named .sync.json.icloud; ask for it.
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
