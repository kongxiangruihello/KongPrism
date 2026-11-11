import Foundation

/// Turns a downloaded subscription (sing-box JSON, Clash YAML, base64 or plain link list)
/// into nodes.
public enum SubscriptionParser {
    public enum Format: String, Codable, Sendable {
        case singBox = "sing-box"
        case clash = "Clash"
        case links = "节点链接"
    }

    public struct Result: Equatable {
        public var nodes: [ProxyNode]
        public var format: Format
        /// Entries that could not be converted (unsupported protocol or transport, malformed).
        public var skipped: Int
        public var skippedReasons: [String]

        /// Providers that refuse a client often still answer with a single fake node
        /// ("访问受限 REF: …", server 127.0.0.1, port 1). Such a result is a refusal, not a subscription.
        public var isRefusalPlaceholder: Bool {
            !nodes.isEmpty && nodes.allSatisfy { node in
                let server = node.server.lowercased()
                return ["127.0.0.1", "0.0.0.0", "localhost", "::1", ""].contains(server) || node.port <= 1
                    || node.name.range(of: "访问受限|禁止访问|拒绝访问|请更新客户端|blocked|forbidden", options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case empty
        case noNodes(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "订阅内容为空"
            case .noNodes(let detail): return "没有找到可用节点（\(detail)）"
            }
        }
    }

    public static func parse(_ data: Data) throws -> Result {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw Failure.empty }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.isEmpty else { throw Failure.empty }

        // 1. sing-box JSON
        if text.hasPrefix("{"), let json = JSONValue.parse(Data(text.utf8)), let outbounds = json["outbounds"]?.arrayValue {
            return try finish(fromSingBox: outbounds)
        }
        // 2. Clash YAML
        if text.range(of: "(^|\\n)proxies:", options: .regularExpression) != nil {
            let yaml = try MiniYAML.parse(text)
            guard let proxies = yaml["proxies"]?.arrayValue else { throw Failure.noNodes("Clash 配置里没有 proxies") }
            return try finish(fromClash: proxies)
        }
        // 3. Base64 link list, or 4. a plain link list
        if !text.contains("://"), let decoded = Base64.decodeString(text), decoded.contains("://") {
            text = decoded
        }
        let (nodes, skipped) = ShareLinks.parseList(text)
        guard !nodes.isEmpty else {
            throw Failure.noNodes(skipped > 0 ? "\(skipped) 个链接都无法识别" : "无法识别的格式")
        }
        return Result(nodes: NodeFilter.uniqued(nodes), format: .links, skipped: skipped,
                      skippedReasons: skipped > 0 ? ["\(skipped) 个链接无法识别或协议不受支持"] : [])
    }

    static func finish(fromSingBox outbounds: [JSONValue]) throws -> Result {
        var nodes: [ProxyNode] = []
        var skipped = 0
        for outbound in outbounds {
            guard var object = outbound.objectValue, let type = object["type"]?.stringValue else { continue }
            guard NodeTypes.supported.contains(type) else { continue } // selectors, direct, block, dns…
            guard object["server"] != nil else { skipped += 1; continue }
            let name = object["tag"]?.stringValue ?? "\(object["server"]?.stringValue ?? "?"):\(object["server_port"]?.intValue ?? 0)"
            // Chains and resolvers refer to tags in the provider's own config.
            for key in ["tag", "detour", "domain_resolver", "domain_strategy", "bind_interface"] { object[key] = nil }
            nodes.append(ProxyNode(name: name, outbound: object))
        }
        guard !nodes.isEmpty else { throw Failure.noNodes("sing-box 配置里没有代理节点") }
        return Result(nodes: NodeFilter.uniqued(nodes), format: .singBox, skipped: skipped, skippedReasons: [])
    }

    static func finish(fromClash proxies: [JSONValue]) throws -> Result {
        var nodes: [ProxyNode] = []
        var reasons: [String: Int] = [:]
        for proxy in proxies {
            guard let object = proxy.objectValue else { continue }
            do {
                nodes.append(try ClashConverter.convert(object))
            } catch let failure as ClashConverter.Failure {
                switch failure {
                case .unsupported(let what): reasons["不支持 \(what)", default: 0] += 1
                case .missing(let key): reasons["缺少 \(key)", default: 0] += 1
                }
            } catch {
                reasons["无法转换", default: 0] += 1
            }
        }
        let skipped = reasons.values.reduce(0, +)
        guard !nodes.isEmpty else {
            throw Failure.noNodes(reasons.isEmpty ? "proxies 为空" : reasons.keys.sorted().joined(separator: "，"))
        }
        return Result(nodes: NodeFilter.uniqued(nodes), format: .clash, skipped: skipped,
                      skippedReasons: reasons.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value) 个" })
    }
}

/// The `subscription-userinfo` response header: upload=…; download=…; total=…; expire=…
public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Date?

    public init(upload: Int64, download: Int64, total: Int64, expire: Date?) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    public init?(header: String) {
        var values: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if let number = Int64(pair[1]) ?? Double(pair[1]).map({ Int64($0) }) { values[pair[0].lowercased()] = number }
        }
        guard values["total"] != nil || values["download"] != nil else { return nil }
        upload = values["upload"] ?? 0
        download = values["download"] ?? 0
        total = values["total"] ?? 0
        expire = values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }

    public var used: Int64 { upload + download }

    /// "已用 12.3 GB / 200 GB · 2027-01-31 到期"
    public var summary: String {
        var text = "已用 \(Self.bytes(used))"
        if total > 0 { text += " / \(Self.bytes(total))" }
        if let expire {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd"
            text += " · \(formatter.string(from: expire)) 到期"
        }
        return text
    }

    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }
}
