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
        /// The response as downloaded (for 问题报告's anonymized sample).
        var data = Data()
    }

    /// The subscription as downloaded, with the same User-Agent fallbacks as an update.
    static func raw(url: String, userAgent: String?, remembered: String?, routes: [Net.Route]) async throws -> (data: Data, agent: String) {
        let fetched = try await fetch(url: url, userAgent: userAgent, remembered: remembered, routes: routes)
        return (fetched.data, fetched.agent)
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
        // The client named in the URL first: a provider answered Clash.Meta with "访问受限"
        // for a …/clashx/… link and accepted ClashX (problem report, 2026-11-11).
        return [first] + agents.filter { $0 != first }
    }

    /// The provider refused (403 / 401 / 429 or a "访问受限" placeholder) — automatic updates pause.
    struct Refused: LocalizedError {
        let message: String
        let retryAfter: TimeInterval?
        var errorDescription: String? { message }
    }

    /// `automatic`: a scheduled update tries only a few identities (the remembered one first), so a
    /// provider that limits request rates is not hit a dozen times in a row.
    static func fetch(url: String, userAgent: String?, remembered: String? = nil, routes: [Net.Route], automatic: Bool = false) async throws -> Fetched {
        guard let address = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              address.scheme == "http" || address.scheme == "https" else {
            throw CoreManager.CoreError("订阅地址无效")
        }
        var lastError: Error = SubscriptionParser.Failure.empty
        var usage: SubscriptionUsage?
        var name: String?
        var refusals = 0
        var serverSays: String?
        // The user's own choice first, then the one that worked last time, then the usual list.
        var candidates: [String] = []
        for agent in [userAgent, remembered].compactMap({ $0 }) + agents(for: address) where !agent.isEmpty && !candidates.contains(agent) {
            candidates.append(agent)
        }
        if automatic { candidates = Array(candidates.prefix(remembered == nil ? 3 : 2)) }
        var retryAfter: TimeInterval?
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
                return Fetched(result: result, usage: usage, suggestedName: name, agent: agent, data: data)
            } catch let error as Net.HTTPError {
                lastError = error
                if [401, 403, 429].contains(error.status) { refusals += 1 }
                if let wait = error.retryAfter { retryAfter = max(retryAfter ?? 0, wait) }
                // Too many requests: another identity will not help, stop here.
                if error.status == 429 {
                    throw Refused(message: "订阅服务器表示请求太频繁（HTTP 429）" + (error.detail.map { "：\($0)" } ?? "") + "，稍后会自动再试", retryAfter: retryAfter)
                }
                AppLog.write("订阅 \(address.host ?? "")：UA \(agent) → HTTP \(error.status)\(error.detail.map { "（\($0)）" } ?? "")")
                if let detail = error.detail { serverSays = detail }
                if error.status == 404 { break }
                // A server error says nothing about the client identity: stop and let the caller retry later.
                if (500...599).contains(error.status) { throw error }
            } catch let error as URLError {
                // A network failure will not change with another User-Agent.
                throw error
            } catch {
                lastError = error
            }
        }
        if refusals > 0 {
            throw Refused(message: "订阅服务器拒绝了 KongPrism 尝试的 \(candidates.count) 种客户端身份（HTTP 403 / 访问受限）。"
                + (serverSays.map { "服务器说：“\($0)”。" } ?? "")
                + "请在 设置 › 订阅 › 右键“编辑…”里，把 User-Agent 填成你能正常使用的那个客户端的名称（例如 ClashX 或 Clash Verge），再点“立即更新”"
                + (automatic ? "。自动更新会暂停一段时间，避免被机场判定为请求过多" : ""), retryAfter: retryAfter)
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
