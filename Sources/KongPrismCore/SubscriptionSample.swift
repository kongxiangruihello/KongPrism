import Foundation

/// Makes a subscription safe to share for debugging: server addresses, passwords, UUIDs,
/// keys and SNI become placeholders, while the structure (keys, nesting, quoting, node
/// names, protocols, transports) stays exactly as the provider wrote it.
public enum SubscriptionSample {
    static let secretKeys = ["server", "password", "uuid", "sni", "servername", "host", "Host", "public-key", "short-id",
                             "obfs-password", "auth", "auth-str", "auth_str", "private-key", "username", "server_name",
                             "public_key", "short_id", "obfs_password", "plugin-opts-host"]

    public static func anonymize(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://"), !trimmed.contains("proxies:"), !trimmed.hasPrefix("{"),
           let decoded = Base64.decodeString(trimmed), decoded.contains("://") {
            trimmed = decoded
        }
        if trimmed.contains("proxies:") || trimmed.hasPrefix("{") {
            return anonymizeStructured(trimmed)
        }
        return anonymizeLinks(trimmed)
    }

    /// YAML (block and flow) and JSON: replace the value after each secret key.
    static func anonymizeStructured(_ text: String) -> String {
        var servers: [String: String] = [:]
        var result = text
        for key in secretKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            // key: value   |   "key": "value"   (value quoted or up to , } ] or end of line)
            let pattern = "((?:^|[\\s{,])\"?\(escaped)\"?\\s*:\\s*)(\"[^\"\\n]*\"|'[^'\\n]*'|[^,}\\]\\n]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            let source = result as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                let valueRange = match.range(at: 2)
                output += source.substring(with: NSRange(location: last, length: valueRange.location - last))
                let original = source.substring(with: valueRange)
                let quote = original.first.flatMap { $0 == "\"" || $0 == "'" ? String($0) : nil } ?? ""
                let bare = original.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                let replacement: String
                switch key {
                case "server":
                    replacement = servers[bare] ?? {
                        let value = "server-\(servers.count + 1).example.com"
                        servers[bare] = value
                        return value
                    }()
                case "uuid": replacement = "00000000-0000-4000-8000-000000000000"
                case "public-key", "public_key": replacement = "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"
                case "short-id", "short_id": replacement = "0123abcd"
                case "sni", "servername", "host", "Host", "server_name": replacement = "sni.example.com"
                default: replacement = "redacted"
                }
                output += quote + replacement + quote
                if original.hasSuffix(" "), quote.isEmpty { output += " " }
                last = valueRange.location + valueRange.length
            }
            output += source.substring(from: last)
            result = output
        }
        return result
    }

    /// Link lists: rebuild each link with placeholder host and credentials.
    static func anonymizeLinks(_ text: String) -> String {
        var lines: [String] = []
        var index = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = line.range(of: "://") else { continue }
            index += 1
            let scheme = line[..<separator.lowerBound]
            var rest = String(line[separator.upperBound...])
            var fragment = ""
            if let hash = rest.firstIndex(of: "#") {
                fragment = String(rest[hash...])
                rest = String(rest[..<hash])
            }
            if scheme == "vmess" {
                lines.append("vmess://<redacted-json>\(fragment)")
                continue
            }
            var query = ""
            if let mark = rest.firstIndex(of: "?") {
                query = String(rest[mark...])
                rest = String(rest[..<mark])
            }
            let port = rest.split(separator: ":").last.map(String.init) ?? "443"
            let cleanedQuery = query.replacingOccurrences(of: "(sni|host|pbk|sid|peer|obfs-password|auth)=[^&]*",
                                                          with: "$1=redacted", options: .regularExpression)
            lines.append("\(scheme)://redacted@server-\(index).example.com:\(port.filter { $0.isNumber || $0 == "," || $0 == "-" })\(cleanedQuery)\(fragment)")
        }
        return lines.joined(separator: "\n")
    }
}
