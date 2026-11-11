import Foundation

/// Decisions the app makes on its own, kept here so they are unit-tested.

/// 自动避开连不上的节点.
public enum NodeAvoidance {
    public struct Decision: Equatable {
        /// Node → until when it is left out of the automatic groups.
        public var avoided: [String: Date]
        /// Nodes added by this decision (for the log and the notice).
        public var newlyAvoided: [CoreLogStats.NodeFailures]
        /// Reload the core now: a newly avoided node is what an automatic group uses right now.
        public var reloadNow: Bool
    }

    public static let threshold = 5
    public static let window: TimeInterval = 15 * 60
    public static let duration: TimeInterval = 3600

    /// - Parameters:
    ///   - failing: nodes over the threshold in the last window (from CoreLogStats).
    ///   - current: the avoid list so far (expired entries are dropped).
    ///   - handPicked: the node chosen by hand in 节点选择 (never avoided: the user picked it).
    ///   - inUse: what the automatic groups are using right now.
    public static func decide(failing: [CoreLogStats.NodeFailures], current: [String: Date], handPicked: String?,
                              inUse: [String], now: Date = Date()) -> Decision {
        var avoided = current.filter { $0.value > now }
        var newly: [CoreLogStats.NodeFailures] = []
        for failure in failing where failure.node != handPicked && avoided[failure.node] == nil {
            avoided[failure.node] = now.addingTimeInterval(duration)
            newly.append(failure)
        }
        return Decision(avoided: avoided, newlyAvoided: newly, reloadNow: newly.contains { inUse.contains($0.node) })
    }
}

/// How long automatic subscription updates pause after the provider refused.
public enum UpdatePause {
    public static let fallback: TimeInterval = 3 * 3600

    /// The server's Retry-After when given, otherwise three hours; never less than ten minutes
    /// or more than a day.
    public static func duration(retryAfter: TimeInterval?) -> TimeInterval {
        min(24 * 3600, max(600, retryAfter ?? fallback))
    }
}

/// 更新后连续启动失败时退回上一个版本.
public enum LaunchHealth {
    /// A launch that follows an abnormal end of the same version adds one; any other launch resets.
    public static func abnormalCount(previous: Int, lastRunEndedAbnormally: Bool, previousVersion: String?, currentVersion: String) -> Int {
        guard lastRunEndedAbnormally, previousVersion == currentVersion else { return 0 }
        return previous + 1
    }

    /// Offer the rollback when this version never ran a full minute, ended abnormally twice in a
    /// row, and a backup of the last good version exists.
    public static func shouldOfferRollback(abnormalCount: Int, currentVersion: String, lastGoodVersion: String?, backupVersion: String?) -> Bool {
        guard abnormalCount >= 2, let lastGood = lastGoodVersion, lastGood != currentVersion, let backup = backupVersion else { return false }
        return backup == lastGood
    }
}

/// Server addresses in a log, replaced before the log leaves the Mac (问题报告).
public enum LogAnonymizer {
    /// Public IPv4 / IPv6 addresses become "ip-1", "ip-2"… (the same address keeps its number);
    /// private, loopback and link-local addresses stay, and so do domain names.
    public static func anonymize(_ text: String) -> String {
        var numbers: [String: Int] = [:]
        func replace(_ pattern: String, in text: String, keep: (String) -> Bool) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            let source = text as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let address = source.substring(with: match.range)
                output += source.substring(with: NSRange(location: last, length: match.range.location - last))
                if keep(address) {
                    output += address
                } else {
                    let number = numbers[address] ?? {
                        let next = numbers.count + 1
                        numbers[address] = next
                        return next
                    }()
                    output += "ip-\(number)"
                }
                last = match.range.location + match.range.length
            }
            return output + source.substring(from: last)
        }
        // IPv4 not part of a longer dotted number (versions like 1.14.4.1 are rare in logs).
        var result = replace(#"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])"#, in: text) { isPrivateIPv4($0) }
        // IPv6 inside brackets ([2001:db8::1]:443), with at least two colons (node names like [HK:1] stay).
        result = replace(#"(?<=\[)[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F:]*(?=\])"#, in: result) { isPrivateIPv6($0) }
        return result
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return true } // not an address: keep
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _): return true
        case (172, 16...31), (192, 168), (169, 254), (100, 64...127): return true
        case (198, 18...19): return true // sing-box fake-ip / benchmark range
        default: return false
        }
    }

    static func isPrivateIPv6(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower == "::1" || lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower == "::"
    }
}


/// Which update package to download (更新包瘦身).
public enum UpdatePlan: Equatable {
    case full(asset: String, sha256: String)
    /// Download the app without its core and put the installed (identical) core back in.
    case lite(asset: String, sha256: String)

    public static func choose(_ release: AppRelease, installedCoreSha256: String?) -> UpdatePlan {
        if let lite = release.liteAsset, let liteSha = release.liteSha256, let wanted = release.coreSha256,
           let installed = installedCoreSha256, installed.lowercased() == wanted.lowercased() {
            return .lite(asset: lite, sha256: liteSha)
        }
        return .full(asset: release.asset, sha256: release.sha256)
    }
}

/// 用电池时少测速.
public enum PowerPolicy {
    /// Minutes between automatic latency tests: on battery or Low Power Mode at least 30
    /// (three times the usual), otherwise the setting.
    public static func testInterval(base: Int, saving: Bool) -> Int {
        saving ? max(30, base * 3) : base
    }
}

/// Where AI services refuse to work (OpenAI's and Anthropic's published supported-regions lists
/// leave these out): an AI exit here means ChatGPT / Claude will show a region error.
public enum AIRegions {
    public static let unsupported: Set<String> = ["CN", "HK", "MO", "RU", "BY", "IR", "KP", "SY", "CU"]

    public static func isSupported(countryCode: String?) -> Bool? {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
        return !unsupported.contains(code)
    }
}
