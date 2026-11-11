import Foundation

/// Answers “这个网站走哪条线？” by walking the same rules, in the same order, as the config
/// ConfigBuilder writes. Rule-set membership is asked through `inRuleSet` (the app runs
/// `sing-box rule-set match`), so the answer comes from the real rule files.
public enum RouteExplainer {
    public enum Target: Equatable {
        case direct
        case proxy
        case reject
        /// Decided after resolving the IP (smart IP routing): Chinese IPs direct, others proxy.
        case byIP
    }

    public struct Answer: Equatable {
        public let host: String
        public let target: Target
        /// The rule that decided, in words.
        public let reason: String
    }

    /// "https://www.example.com:8443/a?b" → "www.example.com"
    public static func host(from input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasPrefix("[") , let close = text.firstIndex(of: "]") {
            return String(text[text.index(after: text.startIndex)..<close])
        }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public static func explain(_ input: String, options: CoreOptions, inRuleSet: (RuleSet, String) -> Bool) -> Answer {
        let host = host(from: input)
        func answer(_ target: Target, _ reason: String) -> Answer { Answer(host: host, target: target, reason: reason) }
        switch options.mode.lowercased() {
        case "direct": return answer(.direct, "出站模式是“直连”，所有流量都直连")
        case "global": return answer(.proxy, "出站模式是“全局”，所有流量都走节点")
        default: break
        }
        let isIP = ConfigBuilder.isIPAddress(host)
        if isIP, isPrivate(host) { return answer(.direct, "局域网 / 本机地址，总是直连") }
        if let suffix = matchingSuffix(host, options.directDomains) { return answer(.direct, "命中你的“总是直连”：\(suffix)") }
        if let suffix = matchingSuffix(host, options.proxyDomains) { return answer(.proxy, "命中你的“总是走代理”：\(suffix)") }
        if !isIP {
            if options.blockAds, inRuleSet(.ads, host) { return answer(.reject, "在广告域名列表里（geosite-category-ads-all），会被拦截") }
            if inRuleSet(.geositeCN, host) { return answer(.direct, "在国内域名列表里（geosite-cn），直连") }
            if inRuleSet(.geositeNotCN, host) { return answer(.proxy, "在国外域名列表里（geosite-geolocation-!cn），走节点") }
            if options.smartIPRouting {
                return answer(.byIP, "不在任何域名列表里；已开启“按 IP 归属分流”，会先解析 IP：国内 IP 直连，否则走节点")
            }
            return answer(.proxy, "不在任何域名列表里，按最后一条规则走节点")
        }
        if inRuleSet(.geoipCN, host) { return answer(.direct, "是国内 IP（geoip-cn），直连") }
        return answer(.proxy, "不是国内 IP，走节点")
    }

    static func matchingSuffix(_ host: String, _ suffixes: [String]) -> String? {
        suffixes.first { suffix in
            let s = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return !s.isEmpty && (host == s || host.hasSuffix("." + s))
        }
    }

    static func isPrivate(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254) || parts[0] == 0
        }
        return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
}
