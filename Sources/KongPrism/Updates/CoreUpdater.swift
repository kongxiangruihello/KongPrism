import Foundation
import AppKit
import KongPrismCore

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

extension Shell {
    /// Runs throwing work off the main thread.
    static func backgroundThrowing<T>(_ work: @escaping () throws -> T) async -> Swift.Result<T, Error> {
        await background { () -> Swift.Result<T, Error> in Swift.Result { try work() } }
    }
}
