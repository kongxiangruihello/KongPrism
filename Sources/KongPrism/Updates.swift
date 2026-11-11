import Foundation
import AppKit
import KongPrismCore

// MARK: - Subscriptions

enum SubscriptionFetcher {
    struct Fetched {
        let result: SubscriptionParser.Result
        let usage: SubscriptionUsage?
        let suggestedName: String?
    }

    /// Providers decide the format by User-Agent. Clash.Meta YAML is the most widely served,
    /// then sing-box JSON, then the v2rayN link list.
    static let agents = ["clash-verge/v2.3.1", "sing-box 1.14.4", "v2rayN/7.13.8"]

    static func fetch(url: String, userAgent: String?, routes: [Net.Route]) async throws -> Fetched {
        guard let address = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              address.scheme == "http" || address.scheme == "https" else {
            throw CoreManager.CoreError("订阅地址无效")
        }
        var lastError: Error = SubscriptionParser.Failure.empty
        var usage: SubscriptionUsage?
        var name: String?
        let candidates = userAgent.flatMap { $0.isEmpty ? nil : [$0] } ?? agents
        for agent in candidates {
            do {
                let (data, response) = try await Net.get(address, headers: ["User-Agent": agent], routes: routes, timeout: 20)
                if usage == nil, let header = response.value(forHTTPHeaderField: "subscription-userinfo") {
                    usage = SubscriptionUsage(header: header)
                }
                if name == nil { name = suggestedName(response) }
                let result = try SubscriptionParser.parse(data)
                AppLog.write("订阅 \(address.host ?? "")：\(result.format.rawValue)，\(result.nodes.count) 个节点（UA \(agent)）")
                return Fetched(result: result, usage: usage, suggestedName: name)
            } catch let error as Net.HTTPError {
                lastError = error
                if error.status == 404 || error.status == 401 { break }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// `profile-title` (plain or "base64:…") or the Content-Disposition file name.
    static func suggestedName(_ response: HTTPURLResponse) -> String? {
        if let title = response.value(forHTTPHeaderField: "profile-title") {
            if title.hasPrefix("base64:"), let decoded = Base64.decodeString(String(title.dropFirst(7))) { return decoded }
            return title
        }
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        if let range = disposition.range(of: "filename*=UTF-8''") {
            let value = disposition[range.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            return value.removingPercentEncoding.map { ($0 as NSString).deletingPathExtension }
        }
        if let range = disposition.range(of: "filename=") {
            let value = disposition[range.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            return (value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) as NSString).deletingPathExtension
        }
        return nil
    }
}

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

// MARK: - sing-box core

enum CoreUpdater {
    static var architecture: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // hw.optional.arm64 is 1 on Apple silicon, also when this process runs under Rosetta.
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return "arm64" }
        return "amd64"
    }

    /// Latest stable sing-box version, from GitHub's /releases/latest redirect (no API rate limit).
    static func latestVersion(routes: [Net.Route]) async throws -> String {
        let location = try await Net.redirectLocation(URL(string: "https://github.com/SagerNet/sing-box/releases/latest")!, routes: routes)
        guard let tag = Versions.tag(fromReleaseURL: location) else { throw CoreManager.CoreError("无法识别 sing-box 最新版本") }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Downloads, unpacks, signs and verifies a sing-box release, checks the current config
    /// with it, then installs it to Application Support (keeping the previous one for rollback).
    static func install(version: String, routes: [Net.Route], core: CoreManager, progress: @escaping @Sendable (Double) -> Void) async throws {
        let name = "sing-box-\(version)-darwin-\(architecture)"
        let url = URL(string: "https://github.com/SagerNet/sing-box/releases/download/v\(version)/\(name).tar.gz")!
        let archive = try await Net.download(url, routes: routes, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        let work = Paths.updates.appendingPathComponent("core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try await Shell.backgroundThrowing {
            let untar = Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path])
            guard untar.ok else { throw CoreManager.CoreError("解压失败：\(untar.output)") }
            let binary = work.appendingPathComponent(name).appendingPathComponent("sing-box")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw CoreManager.CoreError("压缩包里没有 sing-box") }
            Shell.run("/usr/bin/xattr", ["-cr", binary.path])
            Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
            guard let got = core.version(of: binary), got == version else { throw CoreManager.CoreError("新内核无法运行") }
            if FileManager.default.fileExists(atPath: Paths.config.path) {
                let check = core.check(Paths.config, with: binary)
                guard check.ok else { throw CoreManager.CoreError("新内核不接受当前配置，已放弃更新：\(check.output.suffix(300))") }
            }
            let fm = FileManager.default
            try? fm.removeItem(at: Paths.previousCore)
            if fm.fileExists(atPath: Paths.downloadedCore.path) { try fm.moveItem(at: Paths.downloadedCore, to: Paths.previousCore) }
            try fm.moveItem(at: binary, to: Paths.downloadedCore)
            return ()
        }.get()
        AppLog.write("sing-box 已更新到 \(version)")
    }

    static func rollback() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.previousCore.path) else { throw CoreManager.CoreError("没有可回退的旧内核") }
        try? fm.removeItem(at: Paths.downloadedCore)
        try fm.moveItem(at: Paths.previousCore, to: Paths.downloadedCore)
    }

    /// Goes back to the core shipped inside the app.
    static func useBundled() {
        try? FileManager.default.removeItem(at: Paths.downloadedCore)
        try? FileManager.default.removeItem(at: Paths.previousCore)
    }
}

private extension Shell {
    /// Runs throwing work off the main thread.
    static func backgroundThrowing<T>(_ work: @escaping () throws -> T) async -> Result<T, Error> {
        await background { () -> Result<T, Error> in Result { try work() } }
    }
}

// MARK: - KongPrism itself

enum AppUpdater {
    static let owner = "kongxiangruihello"
    static let repo = "KongPrism"

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    struct Found {
        let release: AppRelease
        /// API URL of the zip asset when a token is used, otherwise the public download URL.
        let assetURL: URL
    }

    /// Reads latest.json of the newest release. With a GitHub token (needed while the
    /// repository is private) it goes through the API; otherwise the public download link.
    static func check(token: String, routes: [Net.Route]) async throws -> Found {
        if token.isEmpty {
            let base = "https://github.com/\(owner)/\(repo)/releases/latest/download/"
            let (data, _) = try await Net.get(URL(string: base + "latest.json")!, routes: routes)
            let release = try decode(data)
            return Found(release: release, assetURL: URL(string: base + release.asset)!)
        }
        let headers = apiHeaders(token)
        let (data, _) = try await Net.get(URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!, headers: headers, routes: routes)
        let assets = JSONValue.parse(data)?["assets"]?.arrayValue ?? []
        func assetURL(_ name: String) -> URL? {
            assets.first { $0["name"]?.stringValue == name }?["url"]?.stringValue.flatMap(URL.init(string:))
        }
        guard let manifestURL = assetURL("latest.json") else { throw CoreManager.CoreError("最新发布里没有 latest.json") }
        var downloadHeaders = headers
        downloadHeaders["Accept"] = "application/octet-stream"
        let (manifest, _) = try await Net.get(manifestURL, headers: downloadHeaders, routes: routes)
        let release = try decode(manifest)
        guard let zip = assetURL(release.asset) else { throw CoreManager.CoreError("最新发布里没有 \(release.asset)") }
        return Found(release: release, assetURL: zip)
    }

    static func isNewer(_ release: AppRelease) -> Bool {
        if Versions.isNewer(release.version, than: version) { return true }
        if release.version == version, let build = release.build, let current = Int(self.build) { return build > current }
        return false
    }

    /// Downloads and verifies the update, then swaps the app after KongPrism quits and reopens it.
    /// `beforeQuit` runs on the main thread right before quitting (restores the system proxy).
    static func install(_ found: Found, token: String, routes: [Net.Route], progress: @escaping @Sendable (Double) -> Void,
                        beforeQuit: @escaping () -> Void) async throws {
        var headers: [String: String] = [:]
        if !token.isEmpty {
            headers = apiHeaders(token)
            headers["Accept"] = "application/octet-stream"
        }
        let zip = try await Net.download(found.assetURL, headers: headers, routes: routes, progress: progress)
        let digest = try Net.sha256(of: zip)
        guard digest.lowercased() == found.release.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: zip)
            throw CoreManager.CoreError("下载的文件校验失败（SHA-256 不一致），已放弃安装")
        }
        let work = Paths.updates.appendingPathComponent("app-\(found.release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let newApp = work.appendingPathComponent("KongPrism.app")
        let checked: Result<Void, Error> = await Shell.backgroundThrowing {
            defer { try? FileManager.default.removeItem(at: zip) }
            let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            guard unzip.ok, FileManager.default.fileExists(atPath: newApp.path) else { throw CoreManager.CoreError("解压更新失败") }
            Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            let bundle = Bundle(url: newApp)
            guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw CoreManager.CoreError("更新包不是 KongPrism") }
            let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
            guard verify.ok else { throw CoreManager.CoreError("更新包签名无效：\(verify.output)") }
            return ()
        }
        try checked.get()
        try await MainActor.run {
            beforeQuit()
            try relaunch(replacingWith: newApp)
        }
    }

    private static func decode(_ data: Data) throws -> AppRelease {
        do { return try JSONDecoder().decode(AppRelease.self, from: data) } catch { throw CoreManager.CoreError("latest.json 格式不对") }
    }

    private static func apiHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
         "User-Agent": "KongPrism/\(version)"]
    }

    /// A helper waits for KongPrism to quit, swaps the bundle (restoring the old one if
    /// copying fails), and opens the result. The old version is kept in updates/previous.
    private static func relaunch(replacingWith newApp: URL) throws {
        let target = Bundle.main.bundleURL.path
        let backup = Paths.updates.appendingPathComponent("previous/KongPrism.app").path
        let script = """
        #!/bin/bash
        pid="$1"; new="$2"; target="$3"; backup="$4"; log="$5"
        for i in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        {
          echo "$(date) 安装 $new -> $target"
          mkdir -p "$(dirname "$backup")"; rm -rf "$backup"
          if ditto "$target" "$backup" && rm -rf "$target" && ditto "$new" "$target"; then
            echo "安装完成"; rm -rf "$new"
          else
            echo "安装失败，恢复原版本"; rm -rf "$target"; ditto "$backup" "$target"
          fi
        } >> "$log" 2>&1
        open "$target"
        """
        let scriptURL = Paths.updates.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target, backup, Paths.appLog.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        AppLog.write("更新已就绪，KongPrism 即将重启")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
    }
}
