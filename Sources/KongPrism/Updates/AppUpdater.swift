import Foundation
import AppKit
import KongPrismCore

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

    /// The copy of the previous version kept by the last installation (see relaunch's script).
    static var backupApp: URL { Paths.updates.appendingPathComponent("previous/KongPrism.app") }
    static var backupVersion: String? {
        NSDictionary(contentsOf: backupApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Puts the backup of the previous version back in place and reopens it.
    @MainActor
    static func rollbackToPrevious() throws {
        guard let previous = backupVersion else { throw CoreManager.CoreError("没有找到上一个版本的备份") }
        let copy = Paths.updates.appendingPathComponent("rollback/KongPrism.app")
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = Shell.run("/usr/bin/ditto", [backupApp.path, copy.path])
        guard result.ok else { throw CoreManager.CoreError("复制上一个版本失败：\(result.output)") }
        AppLog.write("退回上一个版本 \(previous)（当前 \(version) 连续启动失败）")
        UserDefaults.standard.set(previous, forKey: "updatingTo")
        try relaunch(replacingWith: copy, reopen: true)
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
