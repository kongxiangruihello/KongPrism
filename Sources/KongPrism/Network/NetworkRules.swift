import AppKit
import CoreWLAN
import Network
import UserNotifications
import KongPrismCore

// MARK: - 按网络自动切换

/// A network the user named, recognised by its router's hardware address (no location permission
/// needed, unlike reading the Wi-Fi name on recent macOS).
struct NetworkRule: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case off, direct, rule, global
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "关闭代理"
            case .direct: return "直连模式"
            case .rule: return "规则模式"
            case .global: return "全局模式"
            }
        }
        var mode: String? {
            switch self {
            case .direct: return "Direct"
            case .rule: return "Rule"
            case .global: return "Global"
            case .off: return nil
            }
        }
    }

    var id = UUID()
    var name: String
    /// The default gateway's MAC address.
    var routerMAC: String
    var action: Action
}

struct NetworkFingerprint: Equatable {
    var gatewayIP: String
    var routerMAC: String
    var wifiName: String?

    var label: String {
        if let wifiName, !wifiName.isEmpty { return "Wi-Fi “\(wifiName)”" }
        return "网关 \(gatewayIP)"
    }

    /// `route -n get default` → gateway, `arp -n gateway` → its MAC.
    static func current() -> NetworkFingerprint? {
        let route = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5).output
        var gateway = route.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("gateway:") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        // In enhanced mode the default route belongs to the TUN interface; ask the physical ones.
        if gateway.isEmpty || gateway.hasPrefix("utun") {
            gateway = ["en0", "en1", "en2"].lazy
                .map { Shell.run("/usr/sbin/ipconfig", ["getoption", $0, "router"], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0.contains(".") } ?? ""
        }
        guard !gateway.isEmpty else { return nil }
        let arp = Shell.run("/usr/sbin/arp", ["-n", gateway], timeout: 5).output
        guard let range = arp.range(of: "([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let mac = arp[range].lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
        // Readable only with location permission on recent macOS; used for display when available.
        let wifi = CWWiFiClient.shared().interface()?.ssid()
        return NetworkFingerprint(gatewayIP: gateway, routerMAC: mac, wifiName: wifi)
    }
}

/// Follows network changes (event-driven through NWPathMonitor, no polling).
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var pending: Task<Void, Never>?
    var onChange: ((NetworkFingerprint?) -> Void)?
    private(set) var current: NetworkFingerprint?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleCheck() }
        }
        monitor.start(queue: DispatchQueue(label: "KongPrism.network", qos: .utility))
    }

    /// Waits a moment: a Wi-Fi switch reports several path changes in a row.
    func scheduleCheck(after seconds: Double = 2.5) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let fingerprint = await Shell.background { NetworkFingerprint.current() }
            guard fingerprint != current else { return }
            current = fingerprint
            onChange?(fingerprint)
        }
    }
}
