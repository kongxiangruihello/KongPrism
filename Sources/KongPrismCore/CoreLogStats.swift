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
        public var firstTime: String?
        public var lastTime: String?
    }

    static let networkDownMarkers = ["network is unreachable", "no route to internet", "no route to host", "can't assign requested address"]
    static let nodeFailureMarkers = ["i/o timeout", "operation timed out", "context deadline exceeded", "connection refused",
                                     "connection reset by peer", "handshake", "tls:", "EOF"]

    public static func summarize(_ log: String) -> Summary {
        var summary = Summary()
        var counts: [String: Int] = [:]
        var hosts: [String: [String: Int]] = [:]
        let outbound = try? NSRegularExpression(pattern: #"using outbound/[a-z0-9-]+\[(.+?)\]: "#)
        let destination = try? NSRegularExpression(pattern: #"open connection to (\S+?)(?::\d+)? using"#)
        let time = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#)
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.contains("ERROR") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = time?.firstMatch(in: line, range: range), let r = Range(match.range, in: line) {
                if summary.firstTime == nil { summary.firstTime = String(line[r]) }
                summary.lastTime = String(line[r])
            }
            let down = networkDownMarkers.contains { line.contains($0) }
            let failed = nodeFailureMarkers.contains { line.contains($0) }
            // A line listing several attempts counts as network-down only if no attempt timed out.
            if down && !line.contains("i/o timeout") { summary.networkDown += 1; continue }
            guard failed, let match = outbound?.firstMatch(in: line, range: range), let r = Range(match.range(at: 1), in: line) else { continue }
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
