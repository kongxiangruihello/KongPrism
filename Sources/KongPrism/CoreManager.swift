import Foundation
import Darwin
import KongPrismCore

/// Runs sing-box as a child process.
final class CoreManager: @unchecked Sendable {
    struct CoreError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Prepared {
        let built: BuiltConfig
        /// Nodes left out because sing-box rejected them.
        let dropped: [String]
    }

    private var process: Process?
    private var stopping = false
    private let lock = NSLock()
    /// Called on the main queue when sing-box exits without being asked to.
    var onUnexpectedExit: ((Int32) -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    // MARK: Binary

    /// The newer of the downloaded core (Application Support) and the one inside the app.
    func binary() -> URL? {
        let fm = FileManager.default
        let downloaded = fm.isExecutableFile(atPath: Paths.downloadedCore.path) ? Paths.downloadedCore : nil
        let bundled = Paths.bundledCore.flatMap { fm.isExecutableFile(atPath: $0.path) ? $0 : nil }
        switch (downloaded, bundled) {
        case let (d?, b?):
            guard let dv = version(of: d) else { return b }
            guard let bv = version(of: b) else { return d }
            return Versions.compare(dv, bv) == .orderedAscending ? b : d
        case let (d?, nil): return d
        case let (nil, b?): return b
        default: return nil
        }
    }

    private var versionCache: [String: (Date, String)] = [:]

    func version(of binary: URL) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: binary.path)[.modificationDate] as? Date) ?? .distantPast
        lock.lock()
        if let cached = versionCache[binary.path], cached.0 == modified { lock.unlock(); return cached.1 }
        lock.unlock()
        let result = Shell.run(binary.path, ["version"], timeout: 10)
        guard result.ok, let version = Versions.singBoxVersion(fromOutput: result.output) else { return nil }
        lock.lock(); versionCache[binary.path] = (modified, version); lock.unlock()
        return version
    }

    var currentVersion: String? { binary().flatMap(version(of:)) }

    // MARK: Config

    func check(_ config: URL, with binary: URL) -> Shell.Result {
        Shell.run(binary.path, ["check", "-c", config.path, "-D", Paths.runtime.path, "--disable-color"], timeout: 30)
    }

    /// Writes the config and runs `sing-box check`, leaving out nodes sing-box rejects.
    func prepare(nodes: [ProxyNode], options: CoreOptions) throws -> Prepared {
        guard let binary = binary() else { throw CoreError("找不到 sing-box 内核（应用包内和 Application Support 里都没有）") }
        let outcome = try CheckedBuild.build(nodes: nodes, options: options) { built in
            try built.data.write(to: Paths.config, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
            let result = check(Paths.config, with: binary)
            return (result.ok, result.output)
        }
        for (name, reason) in outcome.dropped { AppLog.write("跳过节点 \(name)：\(reason)") }
        return Prepared(built: outcome.built, dropped: outcome.dropped.map { $0.name })
    }

    // MARK: Process

    func start() throws {
        guard let binary = binary() else { throw CoreError("找不到 sing-box 内核") }
        stop()
        Self.killStale()
        trimLog()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-c", Paths.config.path, "-D", Paths.runtime.path, "--disable-color"]
        process.currentDirectoryURL = Paths.runtime
        // Logs go to core.log (set in the config); nothing is read from these pipes.
        process.standardOutput = FileHandle.nullDevice
        let errorLog = try? FileHandle(forWritingTo: Self.ensureFile(Paths.coreLog))
        errorLog?.seekToEndOfFile()
        process.standardError = errorLog ?? FileHandle.nullDevice
        process.qualityOfService = .utility
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            let expected = self.stopping || self.process !== finished
            if self.process === finished { self.process = nil }
            self.lock.unlock()
            try? FileManager.default.removeItem(at: Paths.pidFile)
            if !expected {
                let status = finished.terminationStatus
                AppLog.write("sing-box 意外退出，状态 \(status)")
                DispatchQueue.main.async { self.onUnexpectedExit?(status) }
            }
        }
        lock.lock()
        stopping = false
        self.process = process
        lock.unlock()
        try process.run()
        try? String(process.processIdentifier).write(to: Paths.pidFile, atomically: true, encoding: .utf8)
        AppLog.write("sing-box 已启动（\(binary.path)，PID \(process.processIdentifier)）")
    }

    /// Stops sing-box: SIGTERM, then SIGKILL after two seconds.
    func stop() {
        lock.lock()
        guard let process, process.isRunning else { self.process = nil; lock.unlock(); return }
        stopping = true
        lock.unlock()
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        lock.lock(); self.process = nil; lock.unlock()
        try? FileManager.default.removeItem(at: Paths.pidFile)
        AppLog.write("sing-box 已停止")
    }

    /// A sing-box left running by a crashed KongPrism would hold the ports.
    static func killStale() {
        guard let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0 else { return }
        let name = Shell.run("/bin/ps", ["-p", String(pid), "-o", "comm="], timeout: 5).output
        guard name.contains("sing-box") else { return }
        kill(pid, SIGTERM)
        usleep(300_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        AppLog.write("已结束残留的 sing-box（PID \(pid)）")
    }

    private func trimLog() {
        let url = Paths.coreLog
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func ensureFile(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        return url
    }

    // MARK: Ports

    /// True when nothing listens on 127.0.0.1:`port` (we can bind it ourselves).
    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
