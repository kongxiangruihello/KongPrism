import AppKit
import Carbon
import KongPrismCore

// MARK: - iCloud 云盘同步

/// Keeps subscriptions and custom rules in iCloud Drive (~/Library/Mobile Documents/com~apple~CloudDocs/KongPrism),
/// so another Mac signed in to the same Apple ID picks them up. Ports, secrets and tokens are not synced.
/// Merging only adds: a subscription deleted on one Mac is not deleted on the others.
enum ICloudSync {
    struct Payload: Codable {
        struct Entry: Codable {
            var id: UUID
            var name: String
            var url: String?
            var userAgent: String?
            var workingUserAgent: String?
            /// Local (pasted) profiles carry their nodes; remote ones are downloaded again.
            var nodes: [ProxyNode]?
        }
        var version = 1
        var updatedAt: Date
        var device: String
        var profiles: [Entry]
        var directDomains: [String]
        var proxyDomains: [String]
        var rulesChangedAt: Date?
        /// 0.6: these follow rulesChangedAt too (absent in files written by older versions).
        struct RuleSetEntry: Codable {
            var id: UUID
            var name: String
            var url: String
            var target: String
            var enabled: Bool
        }
        var favoriteNodes: [String]? = nil
        var serviceTargets: [String: String]? = nil
        var customRuleSets: [RuleSetEntry]? = nil
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/KongPrism", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("sync.json") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
    }

    static func write(_ bundle: Payload) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(to: file, options: .atomic)
    }

    static func read() -> Payload? {
        // An iCloud placeholder (not downloaded yet) is named .sync.json.icloud; ask for it.
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
