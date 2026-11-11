import Foundation

public enum SpeedText {
    /// Bytes per second as a short menu bar label: "0B", "860B", "12K", "1.2M", "15M".
    public static func compact(_ bytesPerSecond: Int64) -> String {
        let value = Double(max(0, bytesPerSecond))
        if value < 1000 { return "\(Int(value))B" }
        let units = ["K", "M", "G"]
        var amount = value / 1024
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return amount < 10 ? String(format: "%.1f%@", amount, units[unit]) : "\(Int(amount.rounded()))\(units[unit])"
    }
}

/// Where traffic leaves the proxy, from an IP lookup service.
public struct ExitInfo: Equatable, Sendable {
    public var ip: String
    public var countryCode: String?
    public var country: String?
    public var city: String?
    public var organization: String?

    public init(ip: String, countryCode: String?, country: String?, city: String?, organization: String?) {
        self.ip = ip
        self.countryCode = countryCode
        self.country = country
        self.city = city
        self.organization = organization
    }

    /// Reads api.ip.sb/geoip or ipinfo.io/json responses.
    public init?(json: JSONValue) {
        guard let ip = json["ip"]?.stringValue, !ip.isEmpty else { return nil }
        self.ip = ip
        countryCode = (json["country_code"] ?? json["country"])?.stringValue.flatMap { $0.count == 2 ? $0.uppercased() : nil }
        country = json["country"]?.stringValue.flatMap { $0.count == 2 ? nil : $0 }
        city = json["city"]?.stringValue
        organization = (json["organization"] ?? json["org"] ?? json["isp"])?.stringValue
    }

    static let chineseNames: [String: String] = [
        "HK": "香港", "TW": "台湾", "MO": "澳门", "CN": "中国大陆", "JP": "日本", "KR": "韩国", "SG": "新加坡", "US": "美国",
        "GB": "英国", "DE": "德国", "FR": "法国", "NL": "荷兰", "CA": "加拿大", "AU": "澳大利亚", "RU": "俄罗斯", "IN": "印度",
        "MY": "马来西亚", "TH": "泰国", "VN": "越南", "PH": "菲律宾", "ID": "印度尼西亚", "TR": "土耳其", "AE": "阿联酋",
    ]

    public var flag: String {
        guard let code = countryCode, code.count == 2 else { return "🌐" }
        return code.unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }.map { String($0) }.joined()
    }

    /// "🇭🇰 香港 · 203.0.113.5 · Example Networks"
    public var summary: String {
        let place = countryCode.flatMap { Self.chineseNames[$0] } ?? country ?? countryCode ?? "未知地区"
        var parts = ["\(flag) \(place)", ip]
        if let organization, !organization.isEmpty { parts.append(organization.count > 28 ? String(organization.prefix(28)) + "…" : organization) }
        return parts.joined(separator: " · ")
    }
}

/// The readable part of an error page ("访问受限：请使用官方客户端" from a 403), for logs and
/// error messages. HTML tags are dropped, whitespace collapsed, at most `limit` characters.
public enum ResponseSnippet {
    public static func make(_ data: Data, limit: Int = 80) -> String? {
        guard !data.isEmpty, data.count < 200_000, var text = String(data: data, encoding: .utf8) else { return nil }
        if let title = text.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) {
            let inner = String(text[title]).replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
            let body = text.replacingOccurrences(of: "(?is)<(script|style|head)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            text = inner + " " + body
        }
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // A long unbroken token (a key or a base64 blob) is not a message.
        if text.count > 40, !text.contains(" "), text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) == nil { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
