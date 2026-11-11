import XCTest
@testable import KongPrismCore

final class MessagesTests: XCTestCase {
    func testFailureKind() {
        XCTAssertEqual(FailureKind.classify(httpStatus: 429), .refused)
        XCTAssertEqual(FailureKind.classify(httpStatus: 403), .refused)
        XCTAssertEqual(FailureKind.classify(httpStatus: 502), .transient)
        XCTAssertEqual(FailureKind.classify(httpStatus: 404), .other)
        XCTAssertEqual(FailureKind.classify(urlErrorCode: -1200), .transient, "TLS 失败（报告里 18:12 那次）")
        XCTAssertEqual(FailureKind.classify(urlErrorCode: -1001), .transient)
        XCTAssertEqual(FailureKind.classify(urlErrorCode: -1002), .other, "地址无效不是一时的")
        XCTAssertEqual(FailureKind.classify(refused: true), .refused)
    }

    func testErrorSummary() {
        XCTAssertEqual(ErrorSummary.short("订阅服务器表示请求太频繁（HTTP 429）：Too Many Requests，稍后会自动再试"), "被机场限流")
        XCTAssertEqual(ErrorSummary.short("订阅服务器拒绝了 KongPrism 尝试的 3 种客户端身份（HTTP 403 / 访问受限）。"), "被拒绝访问")
        XCTAssertEqual(ErrorSummary.short("TLS错误导致安全连接失败。"), "安全连接失败")
        XCTAssertEqual(ErrorSummary.short("请求超时。"), "连接超时")
        XCTAssertEqual(ErrorSummary.short("服务器返回 HTTP 502（example.com）"), "服务器返回 HTTP 502")
        XCTAssertEqual(ErrorSummary.short("订阅内容为空"), "订阅里没有节点")
        XCTAssertEqual(ErrorSummary.short("一个很长很长很长很长很长很长很长很长的未知错误"), "一个很长很长很长很长很长很长很长很长…")
    }

    func testWhatsNew() {
        let items = WhatsNew.items(after: "0.6.0", upTo: "0.8.0")
        XCTAssertEqual(Set(items.map(\.version)), ["0.7.0", "0.8.0"])
        XCTAssertEqual(items.first?.version, "0.8.0", "最新的在前")
        XCTAssertTrue(WhatsNew.items(after: "0.8.0", upTo: "0.8.0").isEmpty)
        XCTAssertFalse(WhatsNew.items(after: "0.7.0", upTo: "0.8.0").contains { $0.version == "0.7.0" })
        let tabs: Set<String> = ["profiles", "nodes", "rules", "network", "stats", "general", "updates"]
        for item in WhatsNew.all { if let tab = item.tab { XCTAssertTrue(tabs.contains(tab), item.text) } }
    }
}
