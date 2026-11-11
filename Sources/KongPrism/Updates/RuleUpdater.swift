import Foundation
import AppKit
import KongPrismCore

// MARK: - Rule-sets

enum RuleUpdater {
    /// Copies the rule-sets shipped in the app when a file is missing.
    static func installBundledIfMissing() {
        guard let bundled = Paths.bundledRules else { return }
        for set in RuleSet.all {
            let target = Paths.rules.appendingPathComponent(set.file)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.copyItem(at: bundled.appendingPathComponent(set.file), to: target)
        }
    }

    /// Downloads every rule-set; files are replaced only after they look like sing-box
    /// binary rule-sets. sing-box reloads local rule-set files by itself when they change.
    static func update(routes: [Net.Route]) async throws -> Int {
        var updated = 0
        var failures: [String] = []
        for set in RuleSet.all {
            var done = false
            for source in set.urls {
                guard let url = URL(string: source) else { continue }
                do {
                    let (data, _) = try await Net.get(url, routes: routes, timeout: 30)
                    guard data.count > 64, data.prefix(3) == Data("SRS".utf8) else { continue }
                    let target = Paths.rules.appendingPathComponent(set.file)
                    if (try? Data(contentsOf: target)) != data {
                        try data.write(to: target, options: .atomic)
                        updated += 1
                    }
                    done = true
                    break
                } catch {
                    continue
                }
            }
            if !done { failures.append(set.tag) }
        }
        if !failures.isEmpty, failures.count == RuleSet.all.count {
            throw CoreManager.CoreError("规则集全部下载失败（GitHub 和 jsDelivr 都连不上）")
        }
        AppLog.write("规则集更新：\(updated) 个有变化\(failures.isEmpty ? "" : "，失败 \(failures.joined(separator: "、"))")")
        return updated
    }
}
