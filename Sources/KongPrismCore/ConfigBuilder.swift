import Foundation

/// Rule-sets shipped with the app and refreshed by the rule updater.
public struct RuleSet: Equatable, Sendable {
    public let tag: String
    /// File name in the rules folder (no "!" so shell scripts stay simple).
    public let file: String
    /// Source paths, tried in order through the proxy and directly.
    public let urls: [String]

    public static let geositeCN = RuleSet(tag: "geosite-cn", file: "geosite-cn.srs", repo: "sing-geosite", remote: "geosite-cn.srs")
    public static let geositeNotCN = RuleSet(tag: "geosite-geolocation-!cn", file: "geosite-geolocation-not-cn.srs",
                                             repo: "sing-geosite", remote: "geosite-geolocation-!cn.srs")
    public static let ads = RuleSet(tag: "geosite-category-ads-all", file: "geosite-category-ads-all.srs",
                                    repo: "sing-geosite", remote: "geosite-category-ads-all.srs")
    public static let geoipCN = RuleSet(tag: "geoip-cn", file: "geoip-cn.srs", repo: "sing-geoip", remote: "geoip-cn.srs")

    public static let ai = RuleSet(tag: "geosite-category-ai-!cn", file: "geosite-category-ai-not-cn.srs",
                                   repo: "sing-geosite", remote: "geosite-category-ai-!cn.srs")
    public static let youtube = RuleSet(tag: "geosite-youtube", file: "geosite-youtube.srs", repo: "sing-geosite", remote: "geosite-youtube.srs")
    public static let netflix = RuleSet(tag: "geosite-netflix", file: "geosite-netflix.srs", repo: "sing-geosite", remote: "geosite-netflix.srs")

    /// Everything the rule updater keeps fresh; a config declares only the sets it uses.
    public static let all: [RuleSet] = [geositeCN, geositeNotCN, ads, geoipCN, ai, youtube, netflix]

    /// A rule-set from any URL (自定义规则集). `file` ends in .srs (binary) or .json (source).
    public init(tag: String, file: String, urls: [String]) {
        self.tag = tag
        self.file = file
        self.urls = urls
    }

    public var format: String { file.hasSuffix(".json") ? "source" : "binary" }

    init(tag: String, file: String, repo: String, remote: String) {
        self.tag = tag
        self.file = file
        let escaped = remote.replacingOccurrences(of: "!", with: "%21")
        urls = [
            "https://raw.githubusercontent.com/SagerNet/\(repo)/rule-set/\(escaped)",
            "https://testingcf.jsdelivr.net/gh/SagerNet/\(repo)@rule-set/\(escaped)",
            "https://cdn.jsdelivr.net/gh/SagerNet/\(repo)@rule-set/\(escaped)",
        ]
    }
}

/// Services that can leave through a region of their own (按服务分流).
public enum Service: String, CaseIterable, Codable, Sendable {
    case ai, youtube, netflix

    public var title: String {
        switch self {
        case .ai: return "AI 服务（ChatGPT、Claude、Gemini 等）"
        case .youtube: return "YouTube"
        case .netflix: return "Netflix"
        }
    }

    public var groupName: String {
        switch self {
        case .ai: return "🤖 AI 服务"
        case .youtube: return "▶️ YouTube"
        case .netflix: return "🎬 Netflix"
        }
    }

    public var ruleSet: RuleSet {
        switch self {
        case .ai: return .ai
        case .youtube: return .youtube
        case .netflix: return .netflix
        }
    }

    /// Where a service goes: "follow" (节点选择), "no-hk" (fastest node outside Hong Kong),
    /// a region code ("JP", "SG", …) or "direct".
    public static let follow = "follow"
    public static let noHK = "no-hk"
    public static let direct = "direct"

    public static func targetTitle(_ target: String) -> String {
        switch target {
        case follow: return "跟随节点选择"
        case noHK: return "自动（排除香港）"
        case direct: return "直连"
        default: return Region.all.first { $0.code == target }?.groupName ?? target
        }
    }

    public static var targets: [String] { [follow, noHK] + Region.all.map(\.code) + [direct] }
}

public struct CustomRule: Equatable, Sendable {
    public var set: RuleSet
    /// "direct", "proxy" or "reject"
    public var target: String
    public init(set: RuleSet, target: String) {
        self.set = set
        self.target = target
    }
}

/// Everything that shapes the generated sing-box config.
public struct CoreOptions: Equatable, Sendable {
    public var mixedPort = 7897
    public var allowLAN = false
    public var apiPort = 9097
    public var apiSecret = ""
    public var mode = "Rule" // Rule / Global / Direct
    public var blockAds = true
    /// Resolve domains no list knows about and send Chinese IPs direct (like Clash GEOIP,CN).
    /// Off by default: after `resolve`, sing-box hands the proxy server the IP instead of the
    /// domain, so the lookup goes through the remote (proxied) DNS to avoid polluted answers.
    public var smartIPRouting = false
    public var remoteDNS = "https://1.1.1.1/dns-query"
    public var localDNS = "https://223.5.5.5/dns-query"
    public var testURL = "https://www.gstatic.com/generate_204"
    /// Minutes between automatic latency tests (only while a group is in use).
    public var testIntervalMinutes = 10
    public var logLevel = "warn"
    public var logPath = ""
    public var rulesDirectory = ""
    public var cachePath = ""
    public var regionGroups = true
    /// Enhanced mode: a TUN interface captures all traffic (needs root; see the app's TUN helper).
    public var tun = false
    /// Serve an expired DNS answer at once and refresh it in the background (sing-box 1.14).
    public var optimisticDNS = true
    /// Service → target (see Service.targets); missing means "follow".
    public var serviceTargets: [String: String] = [:]

    /// Services that get a rule of their own.
    /// User rule-sets (自定义规则集) with where they send traffic: "direct", "proxy" or "reject".
    public var customRuleSets: [CustomRule] = []

    public var routedServices: [Service] {
        Service.allCases.filter { (serviceTargets[$0.rawValue] ?? Service.follow) != Service.follow }
    }
    /// Domains always sent direct / always proxied (user rules).
    public var directDomains: [String] = []
    public var proxyDomains: [String] = []

    public init() {}
}

public struct BuiltConfig {
    public let json: JSONValue
    /// Node tags in the order they appear in `outbounds` (index i ↔ outbounds[i + nodeOffset]).
    public let nodeTags: [String]
    public let nodeOffset: Int
    public let groups: [String]
    /// Tags of the backup subscription's nodes (a subset of nodeTags).
    public var backupTags: [String] = []
    /// Protocol label per node tag, for the node list.
    public var nodeProtocols: [String: String] = [:]

    public var data: Data { json.encoded() }
}

public enum ConfigBuilder {
    /// `backupNodes`: a second subscription used only when every primary node fails (the app
    /// switches 节点选择 to the 🛟 备用订阅 group; sing-box has no priority fallback of its own).
    public static func build(nodes rawNodes: [ProxyNode], backupNodes rawBackup: [ProxyNode] = [], options: CoreOptions) -> BuiltConfig {
        // Unique across both subscriptions, then split again.
        let all = NodeFilter.uniqued(rawNodes + rawBackup)
        let primaryAll = Array(all.prefix(rawNodes.count))
        let backupAll = Array(all.dropFirst(rawNodes.count))
        let realPrimary = NodeFilter.realNodes(primaryAll)
        let realBackup = backupAll.isEmpty ? [] : NodeFilter.realNodes(backupAll)
        let realNodes = realPrimary + realBackup
        let primaryTags = realPrimary.map(\.name)
        let backupTags = realBackup.map(\.name)
        let realTags = primaryTags + backupTags

        // Groups
        var groupOutbounds: [JSONValue] = []
        var regionNames: [String] = []
        if options.regionGroups {
            for region in Region.all {
                let members = realPrimary.filter { Region.of($0.name) == region }.map(\.name)
                guard members.count >= 2 else { continue }
                regionNames.append(region.groupName)
                groupOutbounds.append(urltest(region.groupName, members, options))
            }
        }
        // 按服务分流: each routed service gets its own fastest-node group (tested only while used).
        var serviceOutbound: [Service: String] = [:]
        for service in options.routedServices {
            let target = options.serviceTargets[service.rawValue] ?? Service.follow
            if target == Service.direct { serviceOutbound[service] = Groups.direct; continue }
            guard !primaryTags.isEmpty else { continue }
            var members: [String]
            if target == Service.noHK {
                members = realPrimary.filter { Region.of($0.name)?.code != "HK" }.map(\.name)
            } else {
                members = realPrimary.filter { Region.of($0.name)?.code == target }.map(\.name)
            }
            if members.isEmpty { members = primaryTags } // no node there: fall back to all
            groupOutbounds.append(urltest(service.groupName, members, options))
            serviceOutbound[service] = service.groupName
        }
        var selectorMembers: [String] = []
        if !primaryTags.isEmpty {
            selectorMembers.append(Groups.auto)
            groupOutbounds.insert(urltest(Groups.auto, primaryTags, options), at: 0)
        }
        selectorMembers += regionNames
        if !backupTags.isEmpty {
            selectorMembers.append(Groups.backup)
            groupOutbounds.append(urltest(Groups.backup, backupTags, options))
        }
        selectorMembers += realTags + [Groups.direct]
        let defaultMember = !primaryTags.isEmpty ? Groups.auto : (!backupTags.isEmpty ? Groups.backup : Groups.direct)
        let selector: JSONValue = [
            "type": "selector",
            "tag": .string(Groups.select),
            "outbounds": .array(selectorMembers.map(JSONValue.string)),
            "default": .string(defaultMember),
            "interrupt_exist_connections": true,
        ]

        var outbounds: [JSONValue] = [selector] + groupOutbounds
        let nodeOffset = outbounds.count
        for node in realNodes {
            var object = node.outbound
            object["tag"] = .string(node.name)
            outbounds.append(.object(object))
        }
        outbounds.append(["type": "direct", "tag": .string(Groups.direct)])

        // DNS
        let remote = dnsServer(options.remoteDNS, tag: "dns-remote", detour: realTags.isEmpty ? nil : Groups.select)
        let local = dnsServer(options.localDNS, tag: "dns-local", detour: nil)
        var dnsRules: [JSONValue] = [
            ["clash_mode": "Direct", "server": "dns-local"],
            ["clash_mode": "Global", "server": "dns-remote"],
        ]
        if !options.directDomains.isEmpty { dnsRules.append(["domain_suffix": strings(options.directDomains), "server": "dns-local"]) }
        if !options.proxyDomains.isEmpty { dnsRules.append(["domain_suffix": strings(options.proxyDomains), "server": "dns-remote"]) }
        for service in options.routedServices where serviceOutbound[service] != nil && serviceOutbound[service] != Groups.direct {
            dnsRules.append(["rule_set": [.string(service.ruleSet.tag)], "server": "dns-remote"])
        }
        dnsRules += [
            ["rule_set": [.string(RuleSet.geositeCN.tag)], "server": "dns-local"],
            ["rule_set": [.string(RuleSet.geositeNotCN.tag)], "server": "dns-remote"],
        ]
        var dns: [String: JSONValue] = [
            "servers": [remote, local, ["type": "udp", "tag": "dns-bootstrap", "server": "223.5.5.5"]],
            "rules": .array(dnsRules),
            // Unlisted domains use the fast local resolver; proxied traffic still carries the
            // domain name to the server, so a polluted answer cannot misroute it.
            "final": "dns-local",
            "strategy": "prefer_ipv4",
        ]
        if options.optimisticDNS { dns["optimistic"] = true }

        // Routing
        var rules: [JSONValue] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": .string(Groups.direct)],
            ["clash_mode": "Direct", "outbound": .string(Groups.direct)],
            ["clash_mode": "Global", "outbound": .string(Groups.select)],
        ]
        if !options.directDomains.isEmpty {
            rules.append(["domain_suffix": strings(options.directDomains), "outbound": .string(Groups.direct)])
        }
        if !options.proxyDomains.isEmpty {
            rules.append(["domain_suffix": strings(options.proxyDomains), "outbound": .string(Groups.select)])
        }
        for custom in options.customRuleSets {
            switch custom.target {
            case "reject": rules.append(["rule_set": [.string(custom.set.tag)], "action": "reject"])
            case "direct": rules.append(["rule_set": [.string(custom.set.tag)], "outbound": .string(Groups.direct)])
            default: rules.append(["rule_set": [.string(custom.set.tag)], "outbound": .string(Groups.select)])
            }
        }
        if options.blockAds { rules.append(["rule_set": [.string(RuleSet.ads.tag)], "action": "reject"]) }
        for service in options.routedServices {
            guard let outbound = serviceOutbound[service] else { continue }
            rules.append(["rule_set": [.string(service.ruleSet.tag)], "outbound": .string(outbound)])
        }
        rules += [
            ["rule_set": [.string(RuleSet.geositeCN.tag)], "outbound": .string(Groups.direct)],
            ["rule_set": [.string(RuleSet.geositeNotCN.tag)], "outbound": .string(Groups.select)],
        ]
        if options.smartIPRouting {
            rules.append(["action": "resolve", "server": "dns-remote", "strategy": "prefer_ipv4"])
        }
        rules.append(["rule_set": [.string(RuleSet.geoipCN.tag)], "outbound": .string(Groups.direct)])

        var usedRuleSets = [RuleSet.geositeCN, .geositeNotCN, .geoipCN] + (options.blockAds ? [RuleSet.ads] : [])
        usedRuleSets += options.routedServices.filter { serviceOutbound[$0] != nil }.map(\.ruleSet)
        usedRuleSets += options.customRuleSets.map(\.set)
        let ruleSets: [JSONValue] = usedRuleSets.map { set in
            ["type": "local", "tag": .string(set.tag), "format": .string(set.format), "path": .string(join(options.rulesDirectory, set.file))]
        }

        var log: [String: JSONValue] = ["level": .string(options.logLevel), "timestamp": true]
        if !options.logPath.isEmpty { log["output"] = .string(options.logPath) }

        var experimental: [String: JSONValue] = [
            "clash_api": [
                "external_controller": .string("127.0.0.1:\(options.apiPort)"),
                "secret": .string(options.apiSecret),
                "default_mode": .string(options.mode),
            ],
        ]
        if !options.cachePath.isEmpty {
            // Remembers the chosen node and the mode across restarts.
            experimental["cache_file"] = ["enabled": true, "path": .string(options.cachePath)]
        }

        let config: JSONValue = [
            "log": .object(log),
            "dns": .object(dns),
            "inbounds": .array(inbounds(options)),
            "outbounds": .array(outbounds),
            "route": [
                "rules": .array(rules),
                "rule_set": .array(ruleSets),
                "final": .string(Groups.select),
                "auto_detect_interface": true,
                "default_domain_resolver": "dns-local",
            ],
            "experimental": .object(experimental),
        ]
        var built = BuiltConfig(json: config, nodeTags: realTags, nodeOffset: nodeOffset,
                                groups: [Groups.select] + (primaryTags.isEmpty ? [] : [Groups.auto]) + regionNames
                                    + (backupTags.isEmpty ? [] : [Groups.backup])
                                    + options.routedServices.compactMap { serviceOutbound[$0] == $0.groupName ? $0.groupName : nil })
        built.backupTags = backupTags
        built.nodeProtocols = Dictionary(realNodes.map { ($0.name, $0.protocolLabel) }, uniquingKeysWith: { first, _ in first })
        return built
    }

    static func inbounds(_ options: CoreOptions) -> [JSONValue] {
        var inbounds: [JSONValue] = [[
            "type": "mixed",
            "tag": "mixed-in",
            "listen": .string(options.allowLAN ? "0.0.0.0" : "127.0.0.1"),
            "listen_port": .int(options.mixedPort),
        ]]
        if options.tun {
            // "mixed" stack: the system TCP stack (cheapest) with gVisor for UDP.
            inbounds.append([
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "auto_route": true,
                "stack": "mixed",
            ])
        }
        return inbounds
    }

    static func urltest(_ tag: String, _ members: [String], _ options: CoreOptions) -> JSONValue {
        [
            "type": "urltest",
            "tag": .string(tag),
            "outbounds": .array(members.map(JSONValue.string)),
            "url": .string(options.testURL),
            "interval": .string("\(max(1, options.testIntervalMinutes))m"),
            "tolerance": 50,
            // No background testing while the group is not used: saves battery and traffic.
            "idle_timeout": "30m",
            "interrupt_exist_connections": false,
        ]
    }

    /// "https://1.1.1.1/dns-query", "tls://8.8.8.8", "quic://dns.alidns.com", "223.5.5.5" → a sing-box DNS server.
    public static func dnsServer(_ address: String, tag: String, detour: String?) -> JSONValue {
        var text = address.trimmingCharacters(in: .whitespaces)
        var type = "udp"
        for (prefix, kind) in [("https://", "https"), ("h3://", "h3"), ("tls://", "tls"), ("quic://", "quic"), ("tcp://", "tcp"), ("udp://", "udp")]
            where text.lowercased().hasPrefix(prefix) {
            type = kind
            text = String(text.dropFirst(prefix.count))
        }
        var path: String?
        if let slash = text.firstIndex(of: "/") {
            path = String(text[slash...])
            text = String(text[..<slash])
        }
        var host = text
        var port: Int?
        if let colon = text.lastIndex(of: ":"), !text.hasSuffix("]"), let value = Int(text[text.index(after: colon)...]) {
            host = String(text[..<colon])
            port = value
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var server: [String: JSONValue] = ["type": .string(type), "tag": .string(tag), "server": .string(host)]
        if let port { server["server_port"] = .int(port) }
        if let path, type == "https" || type == "h3", path != "/dns-query" { server["path"] = .string(path) }
        if let detour { server["detour"] = .string(detour) }
        if !isIPAddress(host) { server["domain_resolver"] = "dns-bootstrap" }
        return .object(server)
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return host.contains(":") && host.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    static func join(_ directory: String, _ file: String) -> String {
        directory.isEmpty ? file : (directory as NSString).appendingPathComponent(file)
    }
}

/// Reads `sing-box check` errors to find which node broke the config.
public enum CheckError {
    /// "decode config at …: outbounds[12].transport: …" or "initialize outbound[12]: bad key length" → 12
    public static func outboundIndex(in message: String) -> Int? {
        guard let range = message.range(of: "outbounds?\\[[0-9]+\\]", options: .regularExpression) else { return nil }
        let text = message[range]
        guard let open = text.firstIndex(of: "[") else { return nil }
        return Int(text[text.index(after: open)...].dropLast())
    }

    /// "… outbound/vless[HK 01]: …" style messages name the tag.
    public static func outboundTag(in message: String, among tags: [String]) -> String? {
        tags.first { message.contains("[\($0)]") }
    }

    /// The last line of sing-box output without colour codes and the "FATAL[0000]" prefix.
    public static func readable(_ output: String) -> String {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let line = plain.split(whereSeparator: \.isNewline).last.map(String.init) ?? plain
        return line.replacingOccurrences(of: "^\\s*(FATAL|ERROR)\\[[0-9]+\\]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Builds a config and has sing-box check it; a node sing-box rejects (unknown option,
/// unsupported transport, bad key) is left out and the check repeated, so one broken
/// node cannot take a whole subscription down.
public enum CheckedBuild {
    public struct Outcome {
        public let built: BuiltConfig
        public let dropped: [(name: String, reason: String)]
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `check` receives each candidate config and returns sing-box's verdict.
    public static func build(nodes: [ProxyNode], backupNodes: [ProxyNode] = [], options: CoreOptions, maxDrops: Int = 25,
                             check: (BuiltConfig) throws -> (ok: Bool, output: String)) throws -> Outcome {
        // Name both lists jointly once, so a dropped tag can be found in either.
        let all = NodeFilter.uniqued(nodes + backupNodes)
        var primary = Array(all.prefix(nodes.count))
        var backup = Array(all.dropFirst(nodes.count))
        var dropped: [(name: String, reason: String)] = []
        for _ in 0...maxDrops {
            let built = ConfigBuilder.build(nodes: primary, backupNodes: backup, options: options)
            let result = try check(built)
            if result.ok { return Outcome(built: built, dropped: dropped) }
            let reason = CheckError.readable(result.output)
            var badTag: String?
            if let index = CheckError.outboundIndex(in: result.output) {
                let position = index - built.nodeOffset
                if position >= 0, position < built.nodeTags.count { badTag = built.nodeTags[position] }
            }
            if badTag == nil { badTag = CheckError.outboundTag(in: result.output, among: built.nodeTags) }
            guard let tag = badTag else { throw Failure(message: "sing-box 配置检查未通过：\(reason)") }
            if let position = primary.firstIndex(where: { $0.name == tag }) {
                primary.remove(at: position)
            } else if let position = backup.firstIndex(where: { $0.name == tag }) {
                backup.remove(at: position)
            } else {
                throw Failure(message: "sing-box 配置检查未通过：\(reason)")
            }
            dropped.append((tag, reason))
        }
        throw Failure(message: "被内核拒绝的节点太多（超过 \(maxDrops) 个），请检查订阅")
    }
}
