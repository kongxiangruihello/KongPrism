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

    public static let all: [RuleSet] = [geositeCN, geositeNotCN, ads, geoipCN]

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

    public var data: Data { json.encoded() }
}

public enum ConfigBuilder {
    public static func build(nodes rawNodes: [ProxyNode], options: CoreOptions) -> BuiltConfig {
        let nodes = NodeFilter.uniqued(rawNodes)
        let realNodes = NodeFilter.realNodes(nodes)
        let realTags = realNodes.map(\.name)

        // Groups
        var groupOutbounds: [JSONValue] = []
        var regionNames: [String] = []
        if options.regionGroups {
            for region in Region.all {
                let members = realNodes.filter { Region.of($0.name) == region }.map(\.name)
                guard members.count >= 2 else { continue }
                regionNames.append(region.groupName)
                groupOutbounds.append(urltest(region.groupName, members, options))
            }
        }
        var selectorMembers: [String] = []
        if !realTags.isEmpty {
            selectorMembers.append(Groups.auto)
            groupOutbounds.insert(urltest(Groups.auto, realTags, options), at: 0)
        }
        selectorMembers += regionNames + realTags + [Groups.direct]
        let selector: JSONValue = [
            "type": "selector",
            "tag": .string(Groups.select),
            "outbounds": .array(selectorMembers.map(JSONValue.string)),
            "default": .string(realTags.isEmpty ? Groups.direct : Groups.auto),
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
        dnsRules += [
            ["rule_set": [.string(RuleSet.geositeCN.tag)], "server": "dns-local"],
            ["rule_set": [.string(RuleSet.geositeNotCN.tag)], "server": "dns-remote"],
        ]
        let dns: JSONValue = [
            "servers": [remote, local, ["type": "udp", "tag": "dns-bootstrap", "server": "223.5.5.5"]],
            "rules": .array(dnsRules),
            // Unlisted domains use the fast local resolver; proxied traffic still carries the
            // domain name to the server, so a polluted answer cannot misroute it.
            "final": "dns-local",
            "strategy": "prefer_ipv4",
        ]

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
        if options.blockAds { rules.append(["rule_set": [.string(RuleSet.ads.tag)], "action": "reject"]) }
        rules += [
            ["rule_set": [.string(RuleSet.geositeCN.tag)], "outbound": .string(Groups.direct)],
            ["rule_set": [.string(RuleSet.geositeNotCN.tag)], "outbound": .string(Groups.select)],
        ]
        if options.smartIPRouting {
            rules.append(["action": "resolve", "server": "dns-remote", "strategy": "prefer_ipv4"])
        }
        rules.append(["rule_set": [.string(RuleSet.geoipCN.tag)], "outbound": .string(Groups.direct)])

        let usedRuleSets = RuleSet.all.filter { options.blockAds || $0 != RuleSet.ads }
        let ruleSets: [JSONValue] = usedRuleSets.map { set in
            ["type": "local", "tag": .string(set.tag), "format": "binary", "path": .string(join(options.rulesDirectory, set.file))]
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
            "dns": dns,
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
        return BuiltConfig(json: config, nodeTags: realTags, nodeOffset: nodeOffset,
                           groups: [Groups.select] + (realTags.isEmpty ? [] : [Groups.auto]) + regionNames)
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
    public static func build(nodes: [ProxyNode], options: CoreOptions, maxDrops: Int = 25,
                             check: (BuiltConfig) throws -> (ok: Bool, output: String)) throws -> Outcome {
        var remaining = NodeFilter.uniqued(nodes)
        var dropped: [(name: String, reason: String)] = []
        for _ in 0...maxDrops {
            let built = ConfigBuilder.build(nodes: remaining, options: options)
            let result = try check(built)
            if result.ok { return Outcome(built: built, dropped: dropped) }
            let reason = CheckError.readable(result.output)
            var badTag: String?
            if let index = CheckError.outboundIndex(in: result.output) {
                let position = index - built.nodeOffset
                if position >= 0, position < built.nodeTags.count { badTag = built.nodeTags[position] }
            }
            if badTag == nil { badTag = CheckError.outboundTag(in: result.output, among: built.nodeTags) }
            guard let tag = badTag, let position = remaining.firstIndex(where: { $0.name == tag }) else {
                throw Failure(message: "sing-box 配置检查未通过：\(reason)")
            }
            dropped.append((tag, reason))
            remaining.remove(at: position)
        }
        throw Failure(message: "被内核拒绝的节点太多（超过 \(maxDrops) 个），请检查订阅")
    }
}
