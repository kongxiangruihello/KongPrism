import Foundation

/// What kind of failure a subscription download was, which decides what happens next.
public enum FailureKind: Equatable {
    /// The provider said no (401 / 403 / 429 / a "访问受限" placeholder): automatic updates pause.
    case refused
    /// The network had a moment (timeout, TLS, lost connection, 5xx): try again in ten minutes.
    case transient
    /// Anything else (bad address, unreadable content): wait for the next scheduled update.
    case other

    /// URLError codes that say nothing about the subscription itself.
    static let transientURLErrors: Set<Int> = [
        -1001, // timedOut
        -1003, // cannotFindHost
        -1004, // cannotConnectToHost
        -1005, // networkConnectionLost
        -1006, // dnsLookupFailed
        -1009, // notConnectedToInternet
        -1018, // internationalRoamingOff
        -1020, // dataNotAllowed
        -1200, // secureConnectionFailed (TLS)
        -1201, -1202, -1203, -1204, -1205, -1206, // certificate trouble, often a middlebox for a moment
    ]

    public static func classify(httpStatus: Int? = nil, urlErrorCode: Int? = nil, refused: Bool = false) -> FailureKind {
        if refused { return .refused }
        if let status = httpStatus {
            if [401, 403, 429].contains(status) { return .refused }
            if (500...599).contains(status) || status == 408 { return .transient }
            return .other
        }
        if let code = urlErrorCode, transientURLErrors.contains(code) { return .transient }
        return .other
    }

    public static let retryDelay: TimeInterval = 10 * 60
}

/// Short wording of a long error, for the menu (the full text stays in the tooltip).
public enum ErrorSummary {
    public static func short(_ message: String) -> String {
        let lower = message.lowercased()
        if message.contains("HTTP 429") || message.contains("太频繁") { return "被机场限流" }
        if message.contains("HTTP 403") || message.contains("HTTP 401") || message.contains("访问受限") || message.contains("拒绝") { return "被拒绝访问" }
        if message.contains("TLS") || message.contains("安全连接") || lower.contains("ssl") || message.contains("证书") { return "安全连接失败" }
        if message.contains("超时") || lower.contains("timed out") { return "连接超时" }
        if message.contains("找不到") || lower.contains("could not be found") || lower.contains("cannot find host") { return "找不到服务器" }
        if message.contains("未连接到互联网") || lower.contains("offline") || lower.contains("not connected") { return "没有网络" }
        if let status = message.range(of: #"HTTP \d{3}"#, options: .regularExpression) { return "服务器返回 \(message[status])" }
        if message.contains("没有节点") || message.contains("内容为空") { return "订阅里没有节点" }
        return message.count > 18 ? String(message.prefix(18)) + "…" : message
    }
}

/// 更新后的“新功能”: highlights per version, each pointing at where to find it.
public enum WhatsNew {
    public struct Item: Equatable {
        public let version: String
        public let text: String
        /// SettingsTab raw value, or nil when there is nothing to open.
        public let tab: String?
    }

    public static let all: [Item] = [
        Item(version: "0.6.0", text: "自动避开连不上的节点：自动选择会暂时避开近 15 分钟频繁连不上的节点", tab: "nodes"),
        Item(version: "0.6.0", text: "识别流量倍率，可设定自动选择只用低倍率节点", tab: "nodes"),
        Item(version: "0.6.0", text: "节点页显示每个节点近 24 小时的失败次数", tab: "nodes"),
        Item(version: "0.6.0", text: "iCloud 同步收藏节点、按服务分流和自定义规则集", tab: "general"),
        Item(version: "0.7.0", text: "新版本连续启动失败时，可一键退回上一个版本", tab: "updates"),
        Item(version: "0.7.0", text: "菜单精简：诊断、问题报告等收进“工具”；按服务分流状态在“节点”里", tab: nil),
        Item(version: "0.7.0", text: "问题报告里的日志会把服务器地址换成代号", tab: "updates"),
        Item(version: "0.8.0", text: "订阅链接和 GitHub 令牌改存在钥匙串里", tab: "profiles"),
        Item(version: "0.8.0", text: "网络一时出错时，订阅 10 分钟后自动重试；出错时间一目了然", tab: "profiles"),
        Item(version: "0.8.0", text: "内核日志轮换保留上一份，节点统计不再因日志清理而中断", tab: "nodes"),
    ]

    /// Highlights of every version after `old` up to and including `new`, newest first.
    public static func items(after old: String, upTo new: String) -> [Item] {
        all.filter { Versions.isNewer($0.version, than: old) && !Versions.isNewer($0.version, than: new) }
            .sorted { Versions.isNewer($0.version, than: $1.version) }
    }
}
