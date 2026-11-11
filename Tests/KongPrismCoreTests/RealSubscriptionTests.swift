import XCTest
@testable import KongPrismCore

/// The user's real subscription (anonymized by KongPrism's problem report, 2026-11-11):
/// ClashX-style YAML with "- " alone on a line before each proxy, 27 Trojan entries
/// (one information entry), multipliers in every name, ports 465 / 6001 / 6002.
final class RealSubscriptionTests: XCTestCase {
    static let yaml = V02Tests.fixtures.appendingPathComponent("real-clashx-trojan-2026-11.yaml")
    static let structure = V02Tests.fixtures.appendingPathComponent("real-node-structure-2026-11.json")

    func testParsesEveryEntry() throws {
        let result = try SubscriptionParser.parse(try Data(contentsOf: Self.yaml))
        XCTAssertEqual(result.nodes.count, 27)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertFalse(result.isRefusalPlaceholder)
        XCTAssertTrue(result.nodes.allSatisfy { $0.protocolLabel == "Trojan" })
        XCTAssertEqual(result.nodes.filter { NodeFilter.isInformational($0.name) }.map(\.name), ["有效期2029-11-09, 剩余 167.41 GB"])
        XCTAssertEqual(result.nodes[1].name, "中国香港-PRO-IPLC-HK1-1-流量倍率:1")
    }

    func testUsageMultipliersAndCountries() throws {
        let nodes = try SubscriptionParser.parse(try Data(contentsOf: Self.yaml)).nodes
        let usage = try XCTUnwrap(SubscriptionUsage.fromInformational(nodes.map(\.name)))
        XCTAssertEqual(usage.remaining, Int64(167.41 * 1024 * 1024 * 1024))
        XCTAssertNotNil(usage.expire)
        let real = NodeFilter.realNodes(nodes)
        XCTAssertEqual(real.count, 26)
        for node in real {
            XCTAssertNotNil(NodeFilter.multiplier(node.name), node.name)
            XCTAssertNotNil(NodeCountry.code(for: node.name), node.name)
        }
        XCTAssertEqual(Set(real.compactMap { NodeFilter.multiplier($0.name) }), [0.2, 0.5, 1])
        XCTAssertEqual(NodeCountry.code(for: "英国-PRO-FW-UK1-流量倍率:0.5"), "GB")
        XCTAssertEqual(NodeCountry.code(for: "中国台湾-PRO-TW1-流量倍率:1"), "TW")
    }

    func testConfigGroups() throws {
        let nodes = try SubscriptionParser.parse(try Data(contentsOf: Self.yaml)).nodes
        var options = CoreOptions()
        options.serviceTargets = [Service.ai.rawValue: Service.noHK]
        let built = ConfigBuilder.build(nodes: nodes, options: options)
        XCTAssertEqual(built.nodeTags.count, 26)
        let outbounds = built.json["outbounds"]?.arrayValue ?? []
        func members(_ group: String) -> [String] {
            outbounds.first { $0["tag"]?.stringValue == group }?["outbounds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        XCTAssertEqual(members("🇭🇰 香港").count, 3)
        XCTAssertEqual(members("🇯🇵 日本").count, 5)
        XCTAssertEqual(members("🇸🇬 新加坡").count, 2)
        XCTAssertEqual(members("🇺🇸 美国").count, 5)
        XCTAssertTrue(members("🇹🇼 台湾").isEmpty, "台湾只有 1 个节点")
        XCTAssertEqual(members(Service.ai.groupName).count, 23, "AI：排除 3 个香港节点")
        options.maxMultiplier = 0.5
        let cheap = ConfigBuilder.build(nodes: nodes, options: options)
        let auto = (cheap.json["outbounds"]?.arrayValue ?? []).first { $0["tag"]?.stringValue == Groups.auto }?["outbounds"]?.arrayValue ?? []
        XCTAssertEqual(auto.count, 15, "倍率 ≤ 0.5 的节点")
    }

    func testNodeStructureSample() throws {
        let result = try SubscriptionParser.parse(try Data(contentsOf: Self.structure))
        XCTAssertEqual(result.nodes.count, 26)
        XCTAssertFalse(result.isRefusalPlaceholder)
    }

    func testDirectIsNotANode() {
        let log = """
        +0800 2026-11-11 18:00:00 ERROR [1 5.0s] connection: open connection to api.dida365.com:443 using outbound/direct[直连]: dial tcp 192.0.2.1:443: i/o timeout
        +0800 2026-11-11 18:00:01 ERROR [2 5.0s] connection: open connection to claude.ai:443 using outbound/trojan[日本-PRO-JP2-流量倍率:0.2]: dial tcp 203.0.113.9:465: i/o timeout
        """
        let stats = CoreLogStats.summarize(log)
        XCTAssertEqual(stats.nodes.map(\.node), ["日本-PRO-JP2-流量倍率:0.2"])
        XCTAssertEqual(stats.directFailures, 1)
    }
}
