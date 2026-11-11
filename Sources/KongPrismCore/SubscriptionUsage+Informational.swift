import Foundation

extension SubscriptionUsage {
    /// Reads expiry and traffic from a provider's information entries ("有效期2029-11-09, 剩余 168.16 GB",
    /// "套餐到期：2027-03-01", "剩余流量：186.42 GB", "已用 12 GB / 总 200 GB"), for providers that do
    /// not send the subscription-userinfo header.
    public static func fromInformational(_ names: [String]) -> SubscriptionUsage? {
        var expire: Date?
        var remaining: Int64?
        var used: Int64?
        var total: Int64?
        for name in names where NodeFilter.isInformational(name) || name.contains("剩余") || name.contains("到期") {
            if expire == nil, let match = first(#"(?:有效期|到期时间|过期时间|套餐到期|到期|expire[sd]?)[^0-9]{0,8}(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#, in: name) {
                var components = DateComponents()
                components.year = Int(match[0]); components.month = Int(match[1]); components.day = Int(match[2])
                components.hour = 23; components.minute = 59
                expire = Calendar(identifier: .gregorian).date(from: components)
            }
            let size = #"([0-9]+(?:\.[0-9]+)?)\s*(TB|GB|MB|KB|T|G|M|K)(?:i?B)?"#
            if remaining == nil, let match = first(#"(?:剩余流量|流量剩余|剩余|remaining)[^0-9]{0,8}"# + size, in: name) { remaining = bytes(match[0], match[1]) }
            if used == nil, let match = first(#"(?:已用流量|已用|used)[^0-9]{0,8}"# + size, in: name) { used = bytes(match[0], match[1]) }
            if total == nil, let match = first(#"(?:总流量|套餐流量|总计|total)[^0-9]{0,8}"# + size, in: name) { total = bytes(match[0], match[1]) }
        }
        guard expire != nil || remaining != nil || total != nil else { return nil }
        var usage = SubscriptionUsage(upload: 0, download: used ?? 0, total: total ?? 0, expire: expire)
        if let total, total > 0, used == nil, let remaining { usage.download = max(0, total - remaining) }
        if total == nil { usage.remaining = remaining }
        return usage
    }

    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func bytes(_ number: String, _ unit: String) -> Int64? {
        guard let value = Double(number) else { return nil }
        let power: Double
        switch unit.uppercased().prefix(1) {
        case "T": power = 4
        case "G": power = 3
        case "M": power = 2
        default: power = 1
        }
        return Int64(value * pow(1024, power))
    }
}
