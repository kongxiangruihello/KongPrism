import Foundation

/// Recognises the ways a subscription reaches KongPrism: one-click import links from
/// provider websites, and whatever is on the clipboard.
public enum ImportSource {
    public struct RemoteProfile: Equatable, Sendable {
        public let url: String
        public let name: String?

        public init(url: String, name: String?) {
            self.url = url
            self.name = name
        }
    }

    /// One-click import links that provider panels put behind "导入到 Clash / sing-box" buttons:
    ///   clash://install-config?url=<encoded>&name=<name>
    ///   clash-meta:// / clashx:// / mihomo:// (same form)
    ///   sing-box://import-remote-profile?url=<encoded>#<name>
    ///   kongprism://install-config?url=<encoded>&name=<name>
    ///   kongprism://add?url=…   (alias)
    public static func remoteProfile(fromImportLink link: String) -> RemoteProfile? {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased() else { return nil }
        let known = ["clash", "clash-meta", "clashx", "clashmeta", "mihomo", "sing-box", "singbox", "kongprism", "stash", "shadowrocket-sub"]
        guard known.contains(scheme) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var url = value("url") ?? value("config") ?? value("link") else { return nil }
        // Some panels encode the URL twice.
        if !url.hasPrefix("http://") && !url.hasPrefix("https://"), let decoded = url.removingPercentEncoding,
           decoded.hasPrefix("http://") || decoded.hasPrefix("https://") { url = decoded }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
        var name = value("name") ?? value("remarks") ?? components.fragment?.removingPercentEncoding
        if let current = name, current.isEmpty { name = nil }
        return RemoteProfile(url: url, name: name)
    }

    public enum Clipboard: Equatable {
        case subscription(RemoteProfile)
        /// Node links, a Clash config or a sing-box config to import as a local profile.
        case nodes(count: Int)
    }

    /// What the clipboard text could be imported as, if anything. Ordinary web links are
    /// ignored unless they look like subscriptions, so the menu does not nag about every URL.
    public static func classify(clipboard text: String, knownURLs: Set<String> = []) -> Clipboard? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 2_000_000 else { return nil }
        if let profile = remoteProfile(fromImportLink: trimmed) {
            return knownURLs.contains(profile.url) ? nil : .subscription(profile)
        }
        let isSingleLine = !trimmed.contains("\n")
        if isSingleLine, trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard !knownURLs.contains(trimmed), looksLikeSubscription(trimmed) else { return nil }
            return .subscription(RemoteProfile(url: trimmed, name: nil))
        }
        if trimmed.contains("://") || trimmed.contains("proxies:") || trimmed.hasPrefix("{") || Base64.decodeString(trimmed)?.contains("://") == true {
            guard let result = try? SubscriptionParser.parse(Data(trimmed.utf8)) else { return nil }
            return .nodes(count: result.nodes.count)
        }
        return nil
    }

    /// Subscription URLs from common panels (V2Board/Xboard, SSPanel, Sub-Store, sub-converters…).
    public static func looksLikeSubscription(_ url: String) -> Bool {
        let lowered = url.lowercased()
        let hints = ["/sub", "subscribe", "token=", "/link/", "/api/v1/client", "clash", "sing-box", "singbox", "flag=", "target=",
                     "/s/", "getsub", "mu=", "/download/", "/api/sub", "/proxy", "config"]
        return hints.contains { lowered.contains($0) }
    }
}

extension SubscriptionUsage {
    /// A short warning when the plan is nearly used up or about to expire.
    public func warning(now: Date = Date()) -> String? {
        if let expire {
            let days = expire.timeIntervalSince(now) / 86_400
            if days < 0 { return "订阅已过期" }
            if days < 7 { return "订阅 \(max(1, Int(days.rounded(.up)))) 天后到期" }
        }
        if total > 0 {
            let ratio = Double(used) / Double(total)
            if ratio >= 1 { return "流量已用完" }
            if ratio >= 0.9 { return "流量已用 \(Int(ratio * 100))%" }
        }
        return nil
    }
}

public enum NodeMerging {
    /// Combines several profiles; each node is prefixed with its profile name ("机场A｜HK 01")
    /// so the same server name from two providers stays distinguishable.
    public static func merge(_ profiles: [(name: String, nodes: [ProxyNode])]) -> [ProxyNode] {
        let prefix = profiles.count > 1
        var result: [ProxyNode] = []
        for profile in profiles {
            for var node in profile.nodes {
                if prefix { node.name = "\(profile.name)｜\(node.name)" }
                result.append(node)
            }
        }
        return NodeFilter.uniqued(result)
    }
}
