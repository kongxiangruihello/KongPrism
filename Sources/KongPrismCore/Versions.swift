import Foundation

public enum Versions {
    /// Compares "1.14.4", "v1.15.0-alpha.3", "0.2" numerically; a pre-release sorts before its release.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (numbersA, preA) = split(a)
        let (numbersB, preB) = split(b)
        for index in 0..<max(numbersA.count, numbersB.count) {
            let x = index < numbersA.count ? numbersA[index] : 0
            let y = index < numbersB.count ? numbersB[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (preA, preB) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x == y ? .orderedSame : (x.compare(y, options: .numeric) == .orderedAscending ? .orderedAscending : .orderedDescending)
        }
    }

    static func split(_ version: String) -> ([Int], String?) {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return (numbers, parts.count > 1 ? parts[1] : nil)
    }

    /// "sing-box version 1.14.4\n\nEnvironment: …" → "1.14.4"
    public static func singBoxVersion(fromOutput output: String) -> String? {
        guard let range = output.range(of: "version [0-9][0-9A-Za-z.\\-]*", options: .regularExpression) else { return nil }
        return String(output[range].dropFirst("version ".count))
    }

    /// The tag in a GitHub ".../releases/tag/v1.14.4" URL.
    public static func tag(fromReleaseURL url: String) -> String? {
        guard let range = url.range(of: "/releases/tag/") else { return nil }
        let tag = url[range.upperBound...].split(separator: "/").first.map(String.init)
        return tag?.removingPercentEncoding ?? tag
    }
}

/// `latest.json`, published next to each KongPrism release by the release workflow.
public struct AppRelease: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int?
    public var notes: String?
    /// Asset file name of the zipped app, e.g. "KongPrism-0.2.0.zip".
    public var asset: String
    public var sha256: String
    public var minimumSystemVersion: String?

    public init(version: String, build: Int?, notes: String?, asset: String, sha256: String, minimumSystemVersion: String?) {
        self.version = version
        self.build = build
        self.notes = notes
        self.asset = asset
        self.sha256 = sha256
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public enum ShellExports {
    /// Lines to paste into Terminal so command-line tools use the proxy.
    public static func command(port: Int) -> String {
        "export https_proxy=http://127.0.0.1:\(port) http_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)"
    }
}
