import XCTest
@testable import KongPrismCore

final class V06Tests: XCTestCase {
    func testMultiplier() {
        XCTAssertEqual(NodeFilter.multiplier("中国香港-PRO-IPLC-HK1-1-流量倍率:1"), 1)
        XCTAssertEqual(NodeFilter.multiplier("日本-PRO-FW-JP2-流量倍率:0.2"), 0.2)
        XCTAssertEqual(NodeFilter.multiplier("🇺🇸 美国 01 | 0.5x 流量"), 0.5)
        XCTAssertEqual(NodeFilter.multiplier("香港 2倍"), 2)
        XCTAssertEqual(NodeFilter.multiplier("HK 01 [1.5x]"), 1.5)
        XCTAssertEqual(NodeFilter.multiplier("新加坡 x2"), 2)
        XCTAssertEqual(NodeFilter.multiplier("香港 IEPL 01 ×0.8"), 0.8)
        for name in ["香港 01", "Netflix2 HK", "4K 美国", "IPv6 日本", "HK1-1", "中国香港-PRO-IPLC-HK1-1"] {
            XCTAssertNil(NodeFilter.multiplier(name), name)
        }
    }

    private func node(_ name: String) -> ProxyNode {
        try! ShareLinks.parse("trojan://secret@\(UUID().uuidString.prefix(8).lowercased()).example.com:465?sni=sni.example.com#\(name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!)")
    }

    private func members(_ built: BuiltConfig, _ group: String) -> [String] {
        (built.json["outbounds"]?.arrayValue ?? []).first { $0["tag"]?.stringValue == group }?["outbounds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func testAutomaticGroupsSkipAvoidedAndExpensive() {
        let nodes = ["香港 01 倍率:1", "香港 02 倍率:2", "日本 01 倍率:0.2", "日本 02 倍率:0.2"].map(node)
        var options = CoreOptions()
        options.serviceTargets = [Service.ai.rawValue: "JP"]
        options.avoidNodes = ["日本 02 倍率:0.2"]
        options.maxMultiplier = 1
        let built = ConfigBuilder.build(nodes: nodes, options: options)
        XCTAssertEqual(members(built, Groups.auto), ["香港 01 倍率:1", "日本 01 倍率:0.2"])
        XCTAssertEqual(members(built, "🇭🇰 香港"), ["香港 01 倍率:1"])
        XCTAssertEqual(members(built, Service.ai.groupName), ["日本 01 倍率:0.2"])
        XCTAssertEqual(built.nodeTags.count, 4, "手选列表里仍有全部节点")
        XCTAssertTrue(members(built, Groups.select).contains("日本 02 倍率:0.2"))

        // Never empty a group: when every member would be skipped, keep them all.
        options.avoidNodes = ["日本 01 倍率:0.2", "日本 02 倍率:0.2"]
        let fallback = ConfigBuilder.build(nodes: nodes, options: options)
        XCTAssertEqual(members(fallback, Service.ai.groupName), ["日本 01 倍率:0.2", "日本 02 倍率:0.2"])
    }

    func testUsageFromInformationalEntries() throws {
        let usage = try XCTUnwrap(SubscriptionUsage.fromInformational(["有效期2029-11-09, 剩余 168.16 GB", "中国香港-PRO-HK1-流量倍率:1"]))
        XCTAssertEqual(usage.remaining, Int64(168.16 * 1024 * 1024 * 1024))
        XCTAssertEqual(usage.total, 0)
        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: try XCTUnwrap(usage.expire))
        XCTAssertEqual([day.year, day.month, day.day], [2029, 11, 9])
        XCTAssertTrue(usage.summary.hasPrefix("剩余 168"), usage.summary)
        XCTAssertNil(usage.warning(now: Date(timeIntervalSince1970: 1_800_000_000)))

        let other = try XCTUnwrap(SubscriptionUsage.fromInformational(["剩余流量：186.42 GB", "套餐到期：2027-03-01", "总流量：200 GB"]))
        XCTAssertEqual(other.total, 200 * 1024 * 1024 * 1024)
        XCTAssertEqual(other.used, Int64(200 * 1024 * 1024 * 1024) - Int64(186.42 * 1024 * 1024 * 1024))
        XCTAssertNil(other.remaining)

        let low = try XCTUnwrap(SubscriptionUsage.fromInformational(["剩余 512 MB"]))
        XCTAssertEqual(low.warning(), "流量只剩 512 MB")
        XCTAssertNil(SubscriptionUsage.fromInformational(["香港 01", "日本 02"]))
    }

    func testNodeCountry() {
        XCTAssertEqual(NodeCountry.code(for: "中国香港-PRO-IPLC-HK1-1-流量倍率:1"), "HK")
        XCTAssertEqual(NodeCountry.code(for: "德国-PRO-FW-DE1-流量倍率:0.5"), "DE")
        XCTAssertEqual(NodeCountry.code(for: "澳大利亚-PRO-FW-AU2-流量倍率:0.5"), "AU")
        XCTAssertEqual(NodeCountry.code(for: "🇩🇪 Frankfurt 01"), "DE")
        XCTAssertEqual(NodeCountry.code(for: "日本-PRO-FW-JP2"), "JP")
        XCTAssertNil(NodeCountry.code(for: "Premium 01"))
    }

    func testLogStatsWindow() throws {
        let log = V051Tests.coreLog
        let since = try XCTUnwrap(CoreLogStats.date(ofLine: "+0800 2026-11-11 16:00:00"))
        let recent = CoreLogStats.summarize(log, since: since)
        XCTAssertEqual(Set(recent.nodes.map(\.node)), ["中国香港-PRO-HK1-流量倍率:1", "日本-PRO-FW-JP2-流量倍率:0.2"])
        XCTAssertEqual(recent.nodes.first { $0.node.hasPrefix("日本") }?.count, 1, "16:00 之后只有 17:01 那一条")
        XCTAssertEqual(recent.nodes.first { $0.node.hasPrefix("中国香港") }?.count, 1)
        XCTAssertEqual(CoreLogStats.failingNodes(log, since: Date.distantPast, threshold: 4).map(\.node), ["日本-PRO-FW-JP2-流量倍率:0.2"])
        XCTAssertTrue(CoreLogStats.failingNodes(log, since: Date.distantPast, threshold: 5).isEmpty)
        // The zone offset is honoured: 16:00 +0800 is 08:00 UTC.
        let utc = try XCTUnwrap(CoreLogStats.date(ofLine: "+0800 2026-11-11 16:00:00"))
        XCTAssertEqual(Int(utc.timeIntervalSince1970) % 86_400, 8 * 3600)
    }
}
