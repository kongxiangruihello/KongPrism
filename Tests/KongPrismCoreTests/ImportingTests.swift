import XCTest
@testable import KongPrismCore

final class ImportingTests: XCTestCase {
    func testClashImportLink() {
        let link = "clash://install-config?url=https%3A%2F%2Fpanel.example.com%2Fapi%2Fv1%2Fclient%2Fsubscribe%3Ftoken%3Dabc%26flag%3Dclash&name=%E6%88%91%E7%9A%84%E6%9C%BA%E5%9C%BA"
        let profile = ImportSource.remoteProfile(fromImportLink: link)
        XCTAssertEqual(profile?.url, "https://panel.example.com/api/v1/client/subscribe?token=abc&flag=clash")
        XCTAssertEqual(profile?.name, "我的机场")
    }

    func testSingBoxImportLink() {
        let link = "sing-box://import-remote-profile?url=https%3A%2F%2Fsub.example.com%2Fs%2Fxyz#Example%20Air"
        let profile = ImportSource.remoteProfile(fromImportLink: link)
        XCTAssertEqual(profile?.url, "https://sub.example.com/s/xyz")
        XCTAssertEqual(profile?.name, "Example Air")
    }

    func testDoubleEncodedAndRejected() {
        let twice = "kongprism://install-config?url=https%253A%252F%252Fa.example.com%252Fsub"
        XCTAssertEqual(ImportSource.remoteProfile(fromImportLink: twice)?.url, "https://a.example.com/sub")
        XCTAssertNil(ImportSource.remoteProfile(fromImportLink: "clash://install-config?url=file%3A%2F%2F%2Fetc%2Fpasswd"))
        XCTAssertNil(ImportSource.remoteProfile(fromImportLink: "https://example.com"))
    }

    func testClipboardClassification() {
        let sub = "https://panel.example.com/api/v1/client/subscribe?token=abc"
        XCTAssertEqual(ImportSource.classify(clipboard: sub), .subscription(.init(url: sub, name: nil)))
        XCTAssertNil(ImportSource.classify(clipboard: sub, knownURLs: [sub]), "已添加的订阅不再提示")
        XCTAssertNil(ImportSource.classify(clipboard: "https://www.apple.com/macbook-air/"), "普通网址不提示")
        XCTAssertEqual(ImportSource.classify(clipboard: "trojan://pw@a.example.com:443#A\nanytls://pw@b.example.com:443#B"), .nodes(count: 2))
        XCTAssertNil(ImportSource.classify(clipboard: "随便一段文字"))
        XCTAssertEqual(ImportSource.classify(clipboard: "clash://install-config?url=https%3A%2F%2Fx.example.com%2Fa"),
                       .subscription(.init(url: "https://x.example.com/a", name: nil)))
    }

    func testUsageWarnings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SubscriptionUsage(upload: 0, download: 95, total: 100, expire: nil).warning(now: now), "流量已用 95%")
        XCTAssertEqual(SubscriptionUsage(upload: 0, download: 10, total: 100, expire: now.addingTimeInterval(2.5 * 86_400)).warning(now: now),
                       "订阅 3 天后到期")
        XCTAssertEqual(SubscriptionUsage(upload: 0, download: 10, total: 100, expire: now.addingTimeInterval(-10)).warning(now: now), "订阅已过期")
        XCTAssertNil(SubscriptionUsage(upload: 0, download: 10, total: 100, expire: now.addingTimeInterval(30 * 86_400)).warning(now: now))
    }

    func testMerging() throws {
        let a = [try ShareLinks.parse("trojan://pw@a.example.com:443#HK 01")]
        let b = [try ShareLinks.parse("trojan://pw@b.example.com:443#HK 01")]
        let merged = NodeMerging.merge([(name: "甲", nodes: a), (name: "乙", nodes: b)])
        XCTAssertEqual(merged.map(\.name), ["甲｜HK 01", "乙｜HK 01"])
        XCTAssertEqual(Region.of(merged[1].name)?.code, "HK")
        XCTAssertEqual(NodeMerging.merge([(name: "甲", nodes: a)]).map(\.name), ["HK 01"])
    }
}
