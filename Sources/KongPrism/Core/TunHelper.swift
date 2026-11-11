import AppKit
import Darwin

/// Enhanced mode (TUN): sing-box must run as root to create the virtual interface and routes.
///
/// One administrator authorization installs:
///   • /Library/PrivilegedHelperTools/com.kongxiangrui.KongPrism.tun       — a small root-owned script (start/stop/status)
///   • /Library/PrivilegedHelperTools/com.kongxiangrui.KongPrism.sing-box  — a root-owned copy of the core
///   • /etc/sudoers.d/kongprism — lets this user run exactly those three helper commands without a password
///
/// The helper copies KongPrism's config into its own root-owned folder and forces every path the core
/// writes to (log, cache) into that folder, so the user-writable config cannot make root write elsewhere.
/// The root-owned core is only replaced through another administrator authorization.
enum TunHelper {
    static let helperPath = "/Library/PrivilegedHelperTools/com.kongxiangrui.KongPrism.tun"
    static let corePath = "/Library/PrivilegedHelperTools/com.kongxiangrui.KongPrism.sing-box"
    static let rootDirectory = "/Library/Application Support/KongPrismTUN"
    static let sudoersPath = "/etc/sudoers.d/kongprism"
    static var pidFile: String { rootDirectory + "/sing-box.pid" }
    static var coreLog: URL { URL(fileURLWithPath: rootDirectory + "/core.log") }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: helperPath) && fm.isExecutableFile(atPath: corePath) && fm.fileExists(atPath: sudoersPath)
    }

    /// True while the root sing-box is alive (kill(pid, 0) answers EPERM for another user's live process).
    static var isRunning: Bool {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Running (no password, through sudoers)

    static func start() throws {
        let result = Shell.run("/usr/bin/sudo", ["-n", helperPath, "start"], timeout: 20)
        guard result.ok else {
            if result.output.contains("password") || result.output.contains("sudo:") {
                throw Failure(message: "增强模式的辅助程序没有授权，请在 设置 › 网络 里重新安装")
            }
            throw Failure(message: "增强模式启动失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))")
        }
    }

    static func stop() {
        guard isInstalled else { return }
        Shell.run("/usr/bin/sudo", ["-n", helperPath, "stop"], timeout: 15)
    }

    // MARK: Installing (administrator authorization)

    /// Installs or refreshes the helper, the root-owned core and the sudoers rule.
    static func install(core: URL) throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw Failure(message: "用户名含有特殊字符，无法安装增强模式")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("kongprism-tun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let helper = staging.appendingPathComponent("helper")
        let sudoers = staging.appendingPathComponent("sudoers")
        try (try helperScript).write(to: helper, atomically: true, encoding: .utf8)
        let commands = ["start", "stop", "status"].map { "\(helperPath) \($0)" }.joined(separator: ", ")
        try "\(user) ALL=(root) NOPASSWD: \(commands)\n".write(to: sudoers, atomically: true, encoding: .utf8)

        let q = Shell.quote
        let script = [
            "set -e",
            "/usr/bin/install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools \(q(rootDirectory))",
            "/usr/bin/install -m 755 -o root -g wheel \(q(helper.path)) \(q(helperPath))",
            "/usr/bin/install -m 755 -o root -g wheel \(q(core.path)) \(q(corePath))",
            "/usr/bin/xattr -c \(q(corePath)) || true",
            "/usr/sbin/visudo -cf \(q(sudoers.path))",
            "/usr/bin/install -m 440 -o root -g wheel \(q(sudoers.path)) \(q(sudoersPath))",
        ].joined(separator: "; ")
        try runAsAdministrator(script, prompt: "KongPrism 要安装增强模式（TUN）的辅助程序。之后开关增强模式不再需要密码。")
        AppLog.write("增强模式辅助程序已安装")
    }

    /// Replaces the root-owned core after a core update (asks for the administrator password).
    static func refreshCore(from core: URL) throws {
        let q = Shell.quote
        try runAsAdministrator("set -e; /usr/bin/install -m 755 -o root -g wheel \(q(core.path)) \(q(corePath))",
                               prompt: "KongPrism 的内核已更新，增强模式需要同步更新它的内核副本。")
    }

    static func uninstall() throws {
        stop()
        let q = Shell.quote
        try runAsAdministrator("rm -f \(q(helperPath)) \(q(corePath)) \(q(sudoersPath)); rm -rf \(q(rootDirectory))",
                               prompt: "KongPrism 要移除增强模式的辅助程序。")
        AppLog.write("增强模式辅助程序已移除")
    }

    private static func runAsAdministrator(_ shell: String, prompt: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        var error: NSDictionary?
        let work = { _ = NSAppleScript(source: source)?.executeAndReturnError(&error) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "授权失败"
            throw Failure(message: message.contains("cancel") || message.contains("取消") ? "已取消授权" : message)
        }
    }

    // MARK: The root helper

    /// The root helper script (Resources/tun-helper.sh): takes only start / stop / status, reads the
    /// invoking user's config from its fixed place and confines what the core writes to its own folder.
    static var helperScript: String {
        get throws {
            guard let url = Bundle.main.url(forResource: "tun-helper", withExtension: "sh"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure(message: "应用包里缺少增强模式辅助程序")
            }
            return text
        }
    }
}
