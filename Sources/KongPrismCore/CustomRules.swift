import Foundation

/// Turns a downloaded rule list into something sing-box can load as a local rule-set.
///
/// Accepted inputs:
/// - sing-box binary rule-set (.srs, starts with the bytes "SRS");
/// - sing-box source rule-set (JSON object with a "rules" array);
/// - Clash / mihomo rule providers in YAML (`payload:` list) or plain text, both in the
///   `domain` behaviour (`+.google.com`, `.google.com`, `*.google.com`, `google.com`),
///   the `ipcidr` behaviour (`1.2.3.0/24`) and the `classical` behaviour
///   (`DOMAIN-SUFFIX,google.com`, `IP-CIDR,1.2.3.0/24,no-resolve`, …).
///
/// Clash semantics are kept: a bare `google.com` matches only that domain, `+.` matches the
/// domain and its subdomains, `.` matches subdomains only and `*.` exactly one label.
public enum CustomRuleSource {
    public enum Converted: Equatable {
        case binary(Data)
        case source(Data)

        public var fileExtension: String {
            switch self {
            case .binary: return "srs"
            case .source: return "json"
            }
        }

        public var data: Data {
            switch self {
            case .binary(let data), .source(let data): return data
            }
        }
    }

    public struct Summary: Equatable {
        public var domains = 0
        public var suffixes = 0
        public var keywords = 0
        public var regexes = 0
        public var cidrs = 0
        public var skipped = 0
        public var total: Int { domains + suffixes + keywords + regexes + cidrs }
    }

    public static func convert(_ data: Data) -> (converted: Converted, summary: Summary?)? {
        if data.count > 16, data.prefix(3) == Data("SRS".utf8) { return (.binary(data), nil) }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["rules"] is [Any] {
            return (.source(data), nil)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var domain: [String] = [], suffix: [String] = [], keyword: [String] = [], regex: [String] = [], cidr: [String] = []
        var summary = Summary()
        let hasPayload = text.range(of: #"(?m)^payload\s*:"#, options: .regularExpression) != nil
        var inPayload = !hasPayload
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if hasPayload {
                if line.hasPrefix("payload") { inPayload = true; continue }
                guard inPayload else { continue }
                guard line.hasPrefix("-") else {
                    // Another top-level key ends the list.
                    if !raw.hasPrefix(" ") && line.contains(":") { inPayload = false }
                    continue
                }
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.contains(",") {
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2 else { summary.skipped += 1; continue }
                let value = parts[1]
                switch parts[0].uppercased() {
                case "DOMAIN": domain.append(value.lowercased())
                case "DOMAIN-SUFFIX": suffix.append(value.lowercased())
                case "DOMAIN-KEYWORD": keyword.append(value.lowercased())
                case "DOMAIN-REGEX": regex.append(value)
                case "IP-CIDR", "IP-CIDR6": if isCIDR(value) { cidr.append(value) } else { summary.skipped += 1 }
                default: summary.skipped += 1
                }
                continue
            }
            if isCIDR(line) { cidr.append(line); continue }
            let lower = line.lowercased()
            if lower.hasPrefix("+.") {
                suffix.append(String(lower.dropFirst(2)))
            } else if lower.hasPrefix("*.") {
                let rest = String(lower.dropFirst(2))
                guard isDomain(rest) else { summary.skipped += 1; continue }
                regex.append("^[^.]+\\." + NSRegularExpression.escapedPattern(for: rest) + "$")
            } else if lower.hasPrefix(".") {
                guard isDomain(String(lower.dropFirst())) else { summary.skipped += 1; continue }
                suffix.append(lower)
            } else if isDomain(lower) {
                domain.append(lower)
            } else {
                summary.skipped += 1
            }
        }
        summary.domains = domain.count
        summary.suffixes = suffix.count
        summary.keywords = keyword.count
        summary.regexes = regex.count
        summary.cidrs = cidr.count
        guard summary.total > 0 else { return nil }

        var rule: [String: Any] = [:]
        if !domain.isEmpty { rule["domain"] = unique(domain) }
        if !suffix.isEmpty { rule["domain_suffix"] = unique(suffix) }
        if !keyword.isEmpty { rule["domain_keyword"] = unique(keyword) }
        if !regex.isEmpty { rule["domain_regex"] = unique(regex) }
        if !cidr.isEmpty { rule["ip_cidr"] = unique(cidr) }
        let object: [String: Any] = ["version": 2, "rules": [rule]]
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return (.source(json), summary)
    }

    /// Tag and file name for a custom rule-set id (stable across updates).
    public static func tag(for id: UUID) -> String { "custom-" + id.uuidString.prefix(8).lowercased() }

    static func isCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        let address = String(parts[0])
        if address.contains(":") { return bits >= 0 && bits <= 128 && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return bits >= 0 && bits <= 32 && octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static func isDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253, !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
