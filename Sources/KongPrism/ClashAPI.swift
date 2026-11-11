import Foundation
import KongPrismCore

/// sing-box's Clash-compatible controller on 127.0.0.1 (only queried while a menu is
/// open or the user acts, so it costs nothing in the background).
struct ClashAPI {
    let port: Int
    let secret: String

    struct Group: Equatable {
        let name: String
        let type: String
        let now: String?
        let all: [String]
    }

    struct Snapshot: Equatable {
        var groups: [String: Group] = [:]
        /// Last measured delay per outbound, in ms (0 = timed out).
        var delays: [String: Int] = [:]
        var types: [String: String] = [:]
    }

    private static let session = Net.session(.direct, timeout: 5)

    private func request(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval = 5) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        components.percentEncodedPath = parts[0]
        if parts.count > 1 { components.percentEncodedQuery = parts[1] }
        guard let url = components.url else { throw CoreManager.CoreError("无效的接口地址 \(path)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body.encoded(pretty: false)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreManager.CoreError("内核接口返回错误：\(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    /// Percent-encodes everything but ASCII unreserved characters (".alphanumerics" would keep Chinese).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
    }

    func isReady() async -> Bool { (try? await request("/version", timeout: 1)) != nil }

    /// Waits up to `seconds` for the controller to answer.
    func waitUntilReady(seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await isReady() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func snapshot() async throws -> Snapshot {
        let data = try await request("/proxies")
        guard let proxies = JSONValue.parse(data)?["proxies"]?.objectValue else { return Snapshot() }
        var snapshot = Snapshot()
        for (name, value) in proxies {
            let type = value["type"]?.stringValue ?? ""
            snapshot.types[name] = type
            if let history = value["history"]?.arrayValue, let last = history.last, let delay = last["delay"]?.intValue {
                snapshot.delays[name] = delay
            }
            if let all = value["all"]?.arrayValue {
                snapshot.groups[name] = Group(name: name, type: type, now: value["now"]?.stringValue, all: all.compactMap(\.stringValue))
            }
        }
        return snapshot
    }

    func select(_ name: String, in group: String) async throws {
        _ = try await request("/proxies/\(Self.escape(group))", method: "PUT", body: ["name": .string(name)])
    }

    func setMode(_ mode: String) async throws {
        _ = try await request("/configs", method: "PATCH", body: ["mode": .string(mode)])
    }

    /// Tests every member of a group at once; returns name → delay (absent = failed).
    func testGroup(_ group: String, url: String, timeoutMs: Int = 5000) async throws -> [String: Int] {
        let target = Self.escape(url)
        let data = try await request("/group/\(Self.escape(group))/delay?url=\(target)&timeout=\(timeoutMs)", timeout: Double(timeoutMs) / 1000 + 5)
        var result: [String: Int] = [:]
        for (name, value) in JSONValue.parse(data)?.objectValue ?? [:] { if let delay = value.intValue { result[name] = delay } }
        return result
    }

    /// Delay of one outbound in ms; throws when it fails.
    func testProxy(_ name: String, url: String, timeoutMs: Int = 5000) async throws -> Int {
        let data = try await request("/proxies/\(Self.escape(name))/delay?url=\(Self.escape(url))&timeout=\(timeoutMs)",
                                     timeout: Double(timeoutMs) / 1000 + 3)
        guard let delay = JSONValue.parse(data)?["delay"]?.intValue, delay > 0 else { throw CoreManager.CoreError("超时") }
        return delay
    }

    struct Connection: Identifiable, Equatable {
        let id: String
        let host: String
        let network: String
        let process: String
        let rule: String
        let chain: String
        let upload: Int64
        let download: Int64
        let start: Date?
    }

    func connections() async throws -> (connections: [Connection], upload: Int64, download: Int64) {
        let data = try await request("/connections")
        guard let json = JSONValue.parse(data) else { return ([], 0, 0) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let list = (json["connections"]?.arrayValue ?? []).compactMap { item -> Connection? in
            guard let id = item["id"]?.stringValue else { return nil }
            let meta = item["metadata"]
            let host = meta?["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? meta?["destinationIP"]?.stringValue ?? "?"
            let port = meta?["destinationPort"]?.stringValue ?? ""
            let chains = item["chains"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var rule = item["rule"]?.stringValue ?? ""
            if let payload = item["rulePayload"]?.stringValue, !payload.isEmpty { rule += " " + payload }
            let process = (meta?["processPath"]?.stringValue).map { ($0 as NSString).lastPathComponent } ?? ""
            return Connection(id: id, host: port.isEmpty ? host : "\(host):\(port)", network: meta?["network"]?.stringValue ?? "",
                              process: process, rule: rule, chain: chains.reversed().joined(separator: " → "),
                              upload: Int64(item["upload"]?.intValue ?? 0), download: Int64(item["download"]?.intValue ?? 0),
                              start: item["start"]?.stringValue.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) })
        }
        return (list, Int64(json["uploadTotal"]?.intValue ?? 0), Int64(json["downloadTotal"]?.intValue ?? 0))
    }

    func closeConnection(_ id: String) async {
        _ = try? await request("/connections/\(Self.escape(id))", method: "DELETE")
    }

    /// Closes open connections (after switching nodes or modes).
    func closeConnections() async {
        _ = try? await request("/connections", method: "DELETE")
    }
}
