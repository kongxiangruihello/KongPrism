import Foundation
import AppKit
import KongPrismCore

// MARK: - Subscriptions

enum SubscriptionFetcher {
    struct Fetched {
        let result: SubscriptionParser.Result
        let usage: SubscriptionUsage?
        let suggestedName: String?
        /// The User-Agent the provider accepted.
        let agent: String
    }

    /// Providers decide the format by User-Agent, and many only answer clients they know
    /// (others get HTTP 403 and a fake "访问受限" node). Clash.Meta first: it is what KongBabel
    /// sends successfully and gets the richest format; then other Clash clients, sing-box, v2rayN.
    static let agents = [
        "Clash.Meta", "ClashX/1.118.0", "ClashMetaForAndroid/2.11.16.Meta", "ClashforWindows/0.20.39",
        "mihomo/1.19.30", "clash-verge/v2.3.1", "sing-box 1.14.4", "v2rayN/7.13.8",
    ]

    /// The URL often says which client it was made for (…/clashx/…, …?flag=singbox).
    static func agents(for url: URL) -> [String] {
        let text = url.absoluteString.lowercased()
        var first: String?
        if text.contains("clashx") { first = "ClashX/1.118.0" }
        else if text.contains("sing-box") || text.contains("singbox") { first = "sing-box 1.14.4" }
        else if text.contains("v2ray") || text.contains("shadowrocket") { first = "v2rayN/7.13.8" }
        guard let first else { return agents }
        return ["Clash.Meta", first] + agents.filter { $0 != first && $0 != "Clash.Meta" }
    }

    static func fetch(url: String, userAgent: String?, remembered: String? = nil, routes: [Net.Route]) async throws -> Fetched {
        guard let address = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              address.scheme == "http" || address.scheme == "https" else {
            throw CoreManager.CoreError("订阅地址无效")
        }
        var lastError: Error = SubscriptionParser.Failure.empty
        var usage: SubscriptionUsage?
        var name: String?
        var refusals = 0
        // The user's own choice first, then the one that worked last time, then the usual list.
        var candidates: [String] = []
        for agent in [userAgent, remembered].compactMap({ $0 }) + agents(for: address) where !agent.isEmpty && !candidates.contains(agent) {
            candidates.append(agent)
        }
        for agent in candidates {
            do {
                let (data, response) = try await Net.get(address, headers: headers(agent: agent, url: address), routes: routes, timeout: 20)
                if usage == nil, let header = response.value(forHTTPHeaderField: "subscription-userinfo") {
                    usage = SubscriptionUsage(header: header)
                }
                if name == nil { name = suggestedName(response) }
                let result = try SubscriptionParser.parse(data)
                if result.isRefusalPlaceholder {
                    refusals += 1
                    AppLog.write("订阅 \(address.host ?? "")：UA \(agent) 被拒绝（返回占位节点）")
                    continue
                }
                AppLog.write("订阅 \(address.host ?? "")：\(result.format.rawValue)，\(result.nodes.count) 个节点（UA \(agent)）")
                return Fetched(result: result, usage: usage, suggestedName: name, agent: agent)
            } catch let error as Net.HTTPError {
                lastError = error
                if error.status == 403 || error.status == 401 { refusals += 1 }
                AppLog.write("订阅 \(address.host ?? "")：UA \(agent) → HTTP \(error.status)")
                if error.status == 404 { break }
            } catch let error as URLError {
                // A network failure will not change with another User-Agent.
                throw error
            } catch {
                lastError = error
            }
        }
        if refusals > 0 {
            throw CoreManager.CoreError("订阅服务器拒绝了 KongPrism 尝试的 \(candidates.count) 种客户端身份（HTTP 403 / 访问受限）。"
                + "请在 设置 › 订阅 › 右键“编辑…”里，把 User-Agent 填成你能正常使用的那个客户端的名称（例如 ClashX 或 Clash Verge），再点“立即更新”")
        }
        throw lastError
    }

    /// The headers a desktop Clash client sends (some panels check more than the User-Agent).
    static func headers(agent: String, url: URL) -> [String: String] {
        var headers = [
            "User-Agent": agent,
            "Accept": "application/yaml, text/yaml, text/plain, application/json, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "Cache-Control": "no-cache",
        ]
        if let scheme = url.scheme, let host = url.host {
            headers["Referer"] = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/"
        }
        return headers
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
    static func backgroundThrowing<T>(_ work: @escaping () throws -> T) async -> Swift.Result<T, Error> {
        await background { () -> Swift.Result<T, Error> in Swift.Result { try work() } }
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
        let newApp = try await stage(found, token: token, routes: routes, progress: progress)
        try await MainActor.run {
            UserDefaults.standard.set(found.release.version, forKey: "updatingTo")
            beforeQuit()
            try relaunch(replacingWith: newApp, reopen: true)
        }
    }

    /// Downloads, checks (SHA-256, bundle identifier, signature) and unpacks an update; returns the new app.
    static func stage(_ found: Found, token: String, routes: [Net.Route], progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
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
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw CoreManager.CoreError("更新包不是 KongPrism") }
            let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
            guard verify.ok else { throw CoreManager.CoreError("更新包签名无效：\(verify.output)") }
            return ()
        }
        try checked.get()
        return newApp
    }

    /// Installs a staged update now and reopens KongPrism.
    @MainActor
    static func installStaged(_ newApp: URL, version: String, beforeQuit: () -> Void) throws {
        UserDefaults.standard.set(version, forKey: "updatingTo")
        beforeQuit()
        try relaunch(replacingWith: newApp, reopen: true)
    }

    /// While KongPrism is quitting anyway: swap in a staged update without reopening.
    static func installStagedOnQuit(_ newApp: URL, version: String) {
        UserDefaults.standard.set(version, forKey: "updatingTo")
        try? relaunch(replacingWith: newApp, reopen: false, quit: false)
    }

    private static func decode(_ data: Data) throws -> AppRelease {
        do { return try JSONDecoder().decode(AppRelease.self, from: data) } catch { throw CoreManager.CoreError("latest.json 格式不对") }
    }

    private static func apiHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
         "User-Agent": "KongPrism/\(version)"]
    }

    static let releasesPage = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    private static var resultFile: URL { Paths.updates.appendingPathComponent("last-install.txt") }

    /// Where the update is installed. A copy that runs translocated (opened straight from
    /// Downloads, macOS runs it from a random read-only folder) or sits in a folder we cannot
    /// write cannot be replaced, so it goes to /Applications instead.
    static var installTarget: String {
        let current = Bundle.main.bundleURL.path
        let parent = (current as NSString).deletingLastPathComponent
        if current.contains("/AppTranslocation/") || !current.hasSuffix(".app") || !FileManager.default.isWritableFile(atPath: parent) {
            return "/Applications/KongPrism.app"
        }
        return current
    }

    static var isTranslocatedOrOutsideApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/AppTranslocation/") || !path.hasPrefix("/Applications/")
    }

    /// A helper waits for KongPrism to quit, swaps the bundle (restoring the old one if
    /// copying fails), writes the outcome for the next launch, and opens the result.
    private static func relaunch(replacingWith newApp: URL, reopen: Bool, quit: Bool = true) throws {
        let target = installTarget
        let backup = Paths.updates.appendingPathComponent("previous/KongPrism.app").path
        try? FileManager.default.removeItem(at: resultFile)
        let script = """
        #!/bin/bash
        pid="$1"; new="$2"; target="$3"; backup="$4"; log="$5"; result="$6"; reopen="$7"
        for i in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        {
          echo "$(date) 安装 $new -> $target"
          mkdir -p "$(dirname "$backup")"; rm -rf "$backup"
          [ -d "$target" ] && ditto "$target" "$backup"
          if rm -rf "$target" && ditto "$new" "$target"; then
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            echo "安装完成"; echo "ok $target" > "$result"; rm -rf "$new"
          else
            echo "安装失败，恢复原版本"; echo "fail 无法写入 $target" > "$result"
            rm -rf "$target"; [ -d "$backup" ] && ditto "$backup" "$target"
          fi
        } >> "$log" 2>&1
        [ "$reopen" = 1 ] && open "$target"
        """
        let scriptURL = Paths.updates.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target, backup,
                            Paths.appLog.path, resultFile.path, reopen ? "1" : "0"]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        AppLog.write("更新已就绪，安装到 \(target)" + (reopen ? "，KongPrism 即将重启" : "（退出后生效）"))
        if quit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) } }
    }

    /// Called at launch: says whether the update just attempted took effect.
    @MainActor
    static func reportLastUpdate(controller: AppController) {
        let defaults = UserDefaults.standard
        guard let wanted = defaults.string(forKey: "updatingTo") else { return }
        defaults.removeObject(forKey: "updatingTo")
        let result = (try? String(contentsOf: resultFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "没有安装记录"
        if version == wanted {
            controller.appTask = .done("已更新到 \(version)")
            AppLog.write("已更新到 \(version)")
            return
        }
        AppLog.write("更新到 \(wanted) 没有生效：\(result)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "更新到 \(wanted) 没有装上"
        alert.informativeText = "当前仍是 \(version)。原因：\(result)\n\n可以在浏览器里下载新版，解压后把 KongPrism 拖进“应用程序”文件夹替换旧版。"
        alert.addButton(withTitle: "在浏览器中下载")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
    }

    /// Offers once to move a copy running from Downloads (or translocated) into /Applications,
    /// where updates can replace it.
    @MainActor
    static func offerMoveToApplications() {
        let defaults = UserDefaults.standard
        guard isTranslocatedOrOutsideApplications, !defaults.bool(forKey: "declinedMoveToApplications") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "把 KongPrism 移到“应用程序”文件夹？"
        alert.informativeText = "KongPrism 现在不在“应用程序”文件夹里运行（例如直接从“下载”打开），这样在线更新无法替换它。移过去后会自动重新打开。"
        alert.addButton(withTitle: "移过去")
        alert.addButton(withTitle: "不用了")
        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(true, forKey: "declinedMoveToApplications")
            return
        }
        moveToApplications()
    }

    /// Copies this bundle to /Applications/KongPrism.app, quits and reopens from there.
    @MainActor
    static func moveToApplications() {
        let target = "/Applications/KongPrism.app"
        let source = Bundle.main.bundleURL.path
        let script = """
        #!/bin/bash
        pid="$1"; source="$2"; target="$3"
        for i in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        rm -rf "$target" && ditto "$source" "$target" && xattr -dr com.apple.quarantine "$target" 2>/dev/null
        open "$target"
        """
        do {
            let url = Paths.updates.appendingPathComponent("move.sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), source, target]
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            AppLog.write("移到应用程序文件夹：\(source) -> \(target)")
            AppController.shared.shutdown()
            NSApp.terminate(nil)
        } catch {
            AppLog.write("移动失败：\(error.localizedDescription)")
        }
    }
}
