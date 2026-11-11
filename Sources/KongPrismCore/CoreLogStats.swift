import Foundation

/// Reads sing-box's error log (`warn` level) and tells node failures apart from the bursts
/// that every client logs while the Mac sleeps or changes networks.
///
/// - Node failure: `dial tcp …: i/o timeout`, `operation timed out`, `context deadline exceeded`,
///   `connection refused`, a TLS / handshake error — the node did not answer.
/// - Network down: `network is unreachable`, `no route to internet`, `no route to host`,
///   `can't assign requested address` — the Mac had no usable network at that moment.
public enum CoreLogStats {
    public struct NodeFailures: Equatable {
        public var node: String
        public var count: Int
        /// Most affected destinations, most frequent first.
        public var hosts: [String]
    }

    public struct Summary: Equatable {
        public var nodes: [NodeFailures] = []
        public var networkDown = 0
        /// Failed connections that went out directly (not through a node).
        public var directFailures = 0
        public var firstTime: String?
        public var lastTime: String?
    }

    static let networkDownMarkers = ["network is unreachable", "no route to internet", "no route to host", "can't assign requested address"]
    static let nodeFailureMarkers = ["i/o timeout", "operation timed out", "context deadline exceeded", "connection refused",
                                     "connection reset by peer", "handshake", "tls:", "EOF"]

    /// "+0800 2026-11-11 15:47:10" (sing-box writes the zone offset first).
    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "Z yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func date(ofLine line: String) -> Date? {
        guard let range = line.range(of: #"([+-]\d{4} )?\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
        let stamp = String(line[range])
        return stamp.first == "+" || stamp.first == "-" ? stampFormatter.date(from: stamp) : localFormatter.date(from: stamp)
    }

    /// Nodes with at least `threshold` failed connections since `since` (自动避开).
    public static func failingNodes(_ log: String, since: Date, threshold: Int) -> [NodeFailures] {
        summarize(log, since: since).nodes.filter { $0.count >= threshold }
    }

    /// `since`: only lines at or after this moment (lines without a time are skipped then).
    public static func summarize(_ log: String, since: Date? = nil) -> Summary {
        var summary = Summary()
        var counts: [String: Int] = [:]
        var hosts: [String: [String: Int]] = [:]
        let outbound = try? NSRegularExpression(pattern: #"using outbound/([a-z0-9-]+)\[(.+?)\]: "#)
        let destination = try? NSRegularExpression(pattern: #"open connection to (\S+?)(?::\d+)? using"#)
        let time = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#)
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.contains("ERROR") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let since {
                guard let stamp = Self.date(ofLine: line), stamp >= since else { continue }
            }
            if let match = time?.firstMatch(in: line, range: range), let r = Range(match.range, in: line) {
                if summary.firstTime == nil { summary.firstTime = String(line[r]) }
                summary.lastTime = String(line[r])
            }
            let down = networkDownMarkers.contains { line.contains($0) }
            let failed = nodeFailureMarkers.contains { line.contains($0) }
            // A line listing several attempts counts as network-down only if no attempt timed out.
            if down && !line.contains("i/o timeout") { summary.networkDown += 1; continue }
            guard failed, let match = outbound?.firstMatch(in: line, range: range),
                  let typeRange = Range(match.range(at: 1), in: line), let r = Range(match.range(at: 2), in: line) else { continue }
            // 直连 / 拦截 are not nodes: a failed direct connection is the website's or the network's problem.
            if ["direct", "block", "dns"].contains(String(line[typeRange])) { summary.directFailures += 1; continue }
            let node = String(line[r])
            counts[node, default: 0] += 1
            if let match = destination?.firstMatch(in: line, range: range), let h = Range(match.range(at: 1), in: line) {
                hosts[node, default: [:]][String(line[h]), default: 0] += 1
            }
        }
        summary.nodes = counts.map { node, count in
            let top = (hosts[node] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
            return NodeFailures(node: node, count: count, hosts: top)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.node < $1.node }
        return summary
    }
}

/// The nodes as sing-box outbounds with every secret replaced: a regression sample that works
/// even when the subscription itself cannot be downloaded (it comes from the local copy).
public enum NodeSample {
    public static func anonymizedJSON(nodes: [ProxyNode]) -> String {
        let built = ConfigBuilder.build(nodes: nodes, options: CoreOptions())
        let tags = Set(built.nodeTags)
        let outbounds = (built.json["outbounds"]?.arrayValue ?? []).filter { tags.contains($0["tag"]?.stringValue ?? "") }
        let json: JSONValue = ["outbounds": .array(outbounds)]
        return SubscriptionSample.anonymizeStructured(String(decoding: json.encoded(pretty: true), as: UTF8.self))
    }
}
