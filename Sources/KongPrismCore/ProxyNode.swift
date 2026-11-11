import Foundation

/// One proxy server: a display name plus its sing-box outbound (without `tag`,
/// which is assigned when the config is built).
public struct ProxyNode: Codable, Equatable, Sendable {
    public var name: String
    public var outbound: [String: JSONValue]

    public init(name: String, outbound: [String: JSONValue]) {
        self.name = name
        self.outbound = outbound
    }

    public var type: String { outbound["type"]?.stringValue ?? "?" }
    public var server: String { outbound["server"]?.stringValue ?? "" }
    public var port: Int { outbound["server_port"]?.intValue ?? 0 }

    /// Protocol shown next to the node name in the menu.
    public var protocolLabel: String {
        switch type {
        case "shadowsocks": return "SS"
        case "vmess": return "VMess"
        case "vless": return outbound["tls"]?["reality"]?["enabled"]?.boolValue == true ? "VLESS·Reality" : "VLESS"
        case "trojan": return "Trojan"
        case "hysteria2": return "Hy2"
        case "hysteria": return "Hysteria"
        case "tuic": return "TUIC"
        case "anytls": return "AnyTLS"
        case "socks": return "SOCKS"
        case "http": return "HTTP"
        default: return type
        }
    }
}

/// Outbound types KongPrism accepts as nodes.
public enum NodeTypes {
    public static let supported: Set<String> = [
        "shadowsocks", "vmess", "vless", "trojan", "hysteria2", "hysteria", "tuic", "anytls", "socks", "http",
        "shadowtls", "naive", "ssh", "snell",
    ]
}

public enum NodeFilter {
    /// Entries many providers put in subscriptions to show remaining traffic, expiry
    /// or their website. They are not real servers, so they stay out of groups.
    /// Only explicit phrases count: plain words such as "流量" or "Traffic" also appear in real
    /// node names ("大流量", "0.5x 流量", "Low Traffic").
    public static func isInformational(_ name: String) -> Bool {
        let pattern = "剩余流量|已用流量|总流量|流量剩余|套餐到期|到期时间|过期时间|有效期|距离下次|下次重置|重置日|官网|官方网站|网址|续费|更新订阅|订阅已|"
            + "expire[sd]?\\s*[:：]|remaining|traffic\\s*[:：]|reset\\s*[:：]|website"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The real servers of a subscription. If every entry would be dropped, the filter must be
    /// wrong for this provider, so nothing is dropped.
    public static func realNodes(_ nodes: [ProxyNode]) -> [ProxyNode] {
        let kept = nodes.filter { !isInformational($0.name) }
        return kept.isEmpty ? nodes : kept
    }

    /// Makes names unique ("HK", "HK", "HK" → "HK", "HK 2", "HK 3"); sing-box tags must be unique
    /// and must not collide with the built-in group names.
    public static func uniqued(_ nodes: [ProxyNode], reserved: Set<String> = Groups.reservedNames) -> [ProxyNode] {
        var used = reserved
        return nodes.map { node in
            var node = node
            var base = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "\(node.server):\(node.port)" }
            var candidate = base
            var index = 2
            while used.contains(candidate) {
                candidate = "\(base) \(index)"
                index += 1
            }
            used.insert(candidate)
            node.name = candidate
            return node
        }
    }
}

/// Names of the groups KongPrism builds.
public enum Groups {
    public static let select = "节点选择"
    public static let auto = "自动选择"
    public static let direct = "直连"
    public static var reservedNames: Set<String> {
        Set([select, auto, direct, "GLOBAL"] + Region.all.map(\.groupName))
    }
}

/// Region groups built from node names (each one picks its fastest node).
public struct Region: Equatable, Sendable {
    public let code: String
    public let groupName: String
    let pattern: String

    public static let all: [Region] = [
        Region(code: "HK", groupName: "🇭🇰 香港", pattern: "香港|港|🇭🇰|Hong ?Kong|(?<![A-Za-z])HK(?![A-Za-z])|HKG"),
        Region(code: "TW", groupName: "🇹🇼 台湾", pattern: "台湾|臺灣|台北|🇹🇼|Taiwan|(?<![A-Za-z])TW(?![A-Za-z])"),
        Region(code: "JP", groupName: "🇯🇵 日本", pattern: "日本|东京|大阪|🇯🇵|Japan|Tokyo|Osaka|(?<![A-Za-z])JP(?![A-Za-z])"),
        Region(code: "SG", groupName: "🇸🇬 新加坡", pattern: "新加坡|狮城|🇸🇬|Singapore|(?<![A-Za-z])SG(?![A-Za-z])"),
        Region(code: "US", groupName: "🇺🇸 美国", pattern: "美国|美國|洛杉矶|硅谷|西雅图|纽约|🇺🇸|United States|America|(?<![A-Za-z])US(?![A-Za-z])|USA"),
        Region(code: "KR", groupName: "🇰🇷 韩国", pattern: "韩国|韓國|首尔|🇰🇷|Korea|Seoul|(?<![A-Za-z])KR(?![A-Za-z])"),
    ]

    public func matches(_ name: String) -> Bool {
        name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Region of a node name; the first matching region wins.
    public static func of(_ name: String) -> Region? { all.first { $0.matches(name) } }
}
