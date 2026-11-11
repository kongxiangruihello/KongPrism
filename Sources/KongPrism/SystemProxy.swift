import Foundation
import AppKit
import CFNetwork

/// Sets the macOS HTTP / HTTPS / SOCKS proxy of every enabled network service with
/// `networksetup`, after saving what was there so it can be put back exactly.
/// Admin accounts can usually do this without a password; if macOS refuses, KongPrism
/// asks once for administrator rights.
enum SystemProxy {
    private static let tool = "/usr/sbin/networksetup"
    static let defaultBypass = ["127.0.0.1", "localhost", "*.local", "::1", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                "169.254.0.0/16", "timestamp.apple.com", "sequoia.apple.com", "seed-sequoia.siri.apple.com"]

    struct Entry: Codable {
        struct Value: Codable { var enabled: Bool; var server: String; var port: Int }
        var service: String
        var web: Value
        var secure: Value
        var socks: Value
        var autoProxyEnabled: Bool
        var autoProxyURL: String
        var bypass: [String]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: State

    /// Whether the current system proxy points at KongPrism (read from SystemConfiguration, no subprocess).
    static func isPointing(to port: Int) -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        let enabled = (settings[kCFNetworkProxiesHTTPSEnable as String] as? Int) == 1
        let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String
        let proxyPort = settings[kCFNetworkProxiesHTTPSPort as String] as? Int
        return enabled && host == "127.0.0.1" && proxyPort == port
    }

    /// True when any HTTP / HTTPS / SOCKS / PAC proxy is set.
    static var hasAnyProxy: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesProxyAutoConfigEnable]
            .contains { (settings[$0 as String] as? Int) == 1 }
    }

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: Paths.proxyBackup.path) }

    // MARK: Changing

    static func enable(port: Int) throws {
        let services = try enabledServices()
        guard !services.isEmpty else { throw Failure(message: "找不到可用的网络服务") }
        if !hasBackup { Store.save(try services.map(capture), to: Paths.proxyBackup) }
        var commands: [[String]] = []
        for service in services {
            commands += [
                ["-setwebproxy", service, "127.0.0.1", String(port), "off"],
                ["-setsecurewebproxy", service, "127.0.0.1", String(port), "off"],
                ["-setsocksfirewallproxy", service, "127.0.0.1", String(port), "off"],
                ["-setautoproxystate", service, "off"],
                ["-setproxybypassdomains", service] + defaultBypass,
            ]
        }
        try apply(commands)
        AppLog.write("系统代理已指向 127.0.0.1:\(port)（\(services.joined(separator: "、"))）")
    }

    /// Puts back the saved settings. Without a backup, turns the three proxies off on every service that points at 127.0.0.1.
    static func restore(port: Int) throws {
        var commands: [[String]] = []
        if let entries = Store.load([Entry].self, from: Paths.proxyBackup) {
            for entry in entries {
                let service = entry.service
                for (kind, value) in [("webproxy", entry.web), ("securewebproxy", entry.secure), ("socksfirewallproxy", entry.socks)] {
                    if !value.server.isEmpty, value.port > 0 {
                        commands.append(["-set\(kind)", service, value.server, String(value.port), "off"])
                    }
                    commands.append(["-set\(kind)state", service, value.enabled ? "on" : "off"])
                }
                if !entry.autoProxyURL.isEmpty { commands.append(["-setautoproxyurl", service, entry.autoProxyURL]) }
                commands.append(["-setautoproxystate", service, entry.autoProxyEnabled ? "on" : "off"])
                commands.append(["-setproxybypassdomains", service] + (entry.bypass.isEmpty ? ["Empty"] : entry.bypass))
            }
        } else {
            for service in try enabledServices() {
                let web = value(run(["-getwebproxy", service]).output)
                guard web.server == "127.0.0.1", web.port == port else { continue }
                commands += [["-setwebproxystate", service, "off"], ["-setsecurewebproxystate", service, "off"],
                             ["-setsocksfirewallproxystate", service, "off"]]
            }
        }
        if !commands.isEmpty { try apply(commands) }
        try? FileManager.default.removeItem(at: Paths.proxyBackup)
        AppLog.write("系统代理已恢复")
    }

    // MARK: networksetup

    static func enabledServices() throws -> [String] {
        let result = run(["-listallnetworkservices"])
        guard result.ok else { throw Failure(message: "无法读取网络服务：\(result.output)") }
        // First line is a notice; "*" marks disabled services.
        return result.output.split(whereSeparator: \.isNewline).dropFirst().map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    private static func capture(_ service: String) throws -> Entry {
        let auto = keyValues(run(["-getautoproxyurl", service]).output)
        let bypassOutput = run(["-getproxybypassdomains", service]).output
        let bypass = bypassOutput.contains("There aren't any") ? [] : bypassOutput.split(whereSeparator: \.isNewline).map(String.init)
        return Entry(service: service,
                     web: value(run(["-getwebproxy", service]).output),
                     secure: value(run(["-getsecurewebproxy", service]).output),
                     socks: value(run(["-getsocksfirewallproxy", service]).output),
                     autoProxyEnabled: auto["Enabled"]?.lowercased() == "yes",
                     autoProxyURL: auto["URL"].flatMap { $0 == "(null)" ? nil : $0 } ?? "",
                     bypass: bypass)
    }

    /// Runs the commands directly; if macOS wants admin rights, runs them all in one authorized shell.
    private static func apply(_ commands: [[String]]) throws {
        var failed: [[String]] = []
        for command in commands {
            let result = run(command)
            if !result.ok || result.output.localizedCaseInsensitiveContains("admin") { failed.append(command) }
        }
        guard !failed.isEmpty else { return }
        AppLog.write("networksetup 需要管理员权限，改用授权方式执行 \(failed.count) 条命令")
        let script = failed.map { ([tool] + $0).map(Shell.quote).joined(separator: " ") }.joined(separator: "; ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let apple = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges with prompt \"KongPrism 需要修改系统代理设置。\"")
        if Thread.isMainThread {
            _ = apple?.executeAndReturnError(&error)
        } else {
            DispatchQueue.main.sync { _ = apple?.executeAndReturnError(&error) }
        }
        if let error {
            throw Failure(message: (error[NSAppleScript.errorMessage] as? String) ?? "授权失败，系统代理未修改")
        }
    }

    private static func run(_ arguments: [String]) -> Shell.Result { Shell.run(tool, arguments, timeout: 15) }

    private static func keyValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    private static func value(_ text: String) -> Entry.Value {
        let values = keyValues(text)
        return Entry.Value(enabled: values["Enabled"]?.lowercased() == "yes", server: values["Server"] ?? "", port: Int(values["Port"] ?? "") ?? 0)
    }
}
