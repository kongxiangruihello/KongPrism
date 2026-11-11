import XCTest
@testable import KongPrismCore

final class V051Tests: XCTestCase {
    /// Node names as the user's provider writes them (from the 2026-11-11 problem report).
    func testColonNamesFromReport() throws {
        let data = try Data(contentsOf: V02Tests.fixtures.appendingPathComponent("panel-trojan-colon-names.yaml"))
        let result = try SubscriptionParser.parse(data)
        XCTAssertEqual(result.nodes.count, 9)
        XCTAssertTrue(result.nodes.allSatisfy { $0.protocolLabel == "Trojan" })
        XCTAssertEqual(result.nodes[4].name, "日本-PRO-JP1-流量倍率:0.2", "流式写法里不加引号的冒号要保留在名称里")
        XCTAssertEqual(result.nodes[1].name, "中国香港-PRO-IPLC-HK1-1-流量倍率:1")
        XCTAssertTrue(NodeFilter.isInformational(result.nodes[0].name))
        XCTAssertEqual(result.nodes.filter { NodeFilter.isInformational($0.name) }.count, 1)
        let built = ConfigBuilder.build(nodes: result.nodes, options: CoreOptions())
        XCTAssertEqual(built.nodeTags.count, 8)
        let outbounds = built.json["outbounds"]?.arrayValue ?? []
        func members(_ group: String) -> [String] {
            outbounds.first { $0["tag"]?.stringValue == group }?["outbounds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        XCTAssertEqual(members("🇭🇰 香港").count, 3)
        XCTAssertEqual(members("🇯🇵 日本"), ["日本-PRO-JP1-流量倍率:0.2", "日本-PRO-FW-JP2-流量倍率:0.2"])
        XCTAssertTrue(members("🇸🇬 新加坡").isEmpty, "只有 1 个节点的地区不单独分组")
    }

    /// Lines in the format of the report's core.log (addresses replaced).
    static let coreLog = """
    +0800 2026-11-11 15:47:10 ERROR [111 5.0s] connection: open connection to claude.ai:443 using outbound/trojan[日本-PRO-FW-JP2-流量倍率:0.2]: dial tcp 203.0.113.52:465: i/o timeout
    +0800 2026-11-11 15:47:12 ERROR [112 5.0s] connection: open connection to claude.ai:443 using outbound/trojan[日本-PRO-FW-JP2-流量倍率:0.2]: dial tcp 203.0.113.52:465: i/o timeout
    +0800 2026-11-11 15:47:13 ERROR [113 5.0s] connection: open connection to chatgpt.com:443 using outbound/trojan[日本-PRO-FW-JP2-流量倍率:0.2]: context deadline exceeded
    +0800 2026-11-11 16:03:01 ERROR [114 5.0s] connection: open connection to calendar.google.com:443 using outbound/trojan[中国香港-PRO-HK1-流量倍率:1]: dial tcp 198.51.100.97:465: i/o timeout
    +0800 2026-11-11 16:07:00 ERROR [115 1ms] connection: open connection to claude.ai:443 using outbound/trojan[日本-PRO-FW-JP2-流量倍率:0.2]: dial tcp 203.0.113.52:465: connect: network is unreachable
    +0800 2026-11-11 16:07:00 ERROR [116 1ms] connection: open connection to api.dida365.com:443 using outbound/direct[直连]: (dial tcp 192.0.2.1:443: no route to internet | dial tcp 192.0.2.2:443: no route to internet)
    +0800 2026-11-11 16:07:01 ERROR [117 2ms] connection: connection download closed: read tcp 10.0.0.2:50980->203.0.113.52:465: read: can't assign requested address
    +0800 2026-11-11 17:01:34 ERROR [118 162ms] connection: open connection to ab.chatgpt.com:443 using outbound/trojan[日本-PRO-FW-JP2-流量倍率:0.2]: (dial tcp 203.0.113.52:465: i/o timeout | dial tcp 203.0.113.53:465: connect: network is unreachable)
    """

    func testCoreLogStats() {
        let stats = CoreLogStats.summarize(Self.coreLog)
        XCTAssertEqual(stats.nodes.first?.node, "日本-PRO-FW-JP2-流量倍率:0.2")
        XCTAssertEqual(stats.nodes.first?.count, 4, "超时 3 次 + 含超时的多次尝试 1 次；网络不可用那条不算")
        XCTAssertEqual(stats.nodes.first?.hosts.first, "claude.ai")
        XCTAssertEqual(stats.nodes.dropFirst().first?.node, "中国香港-PRO-HK1-流量倍率:1")
        XCTAssertEqual(stats.networkDown, 3)
        XCTAssertEqual(stats.firstTime, "2026-11-11 15:47:10")
        XCTAssertEqual(stats.lastTime, "2026-11-11 17:01:34")
        XCTAssertEqual(CoreLogStats.summarize("").nodes, [])
    }

    func testResponseSnippet() {
        XCTAssertEqual(ResponseSnippet.make(Data("<html><head><title>403 Forbidden</title></head><body><h1>访问受限</h1></body></html>".utf8)), "403 Forbidden 访问受限")
        XCTAssertEqual(ResponseSnippet.make(Data("  访问受限，请使用官方客户端  ".utf8)), "访问受限，请使用官方客户端")
        XCTAssertNil(ResponseSnippet.make(Data(repeating: 0x41, count: 120)), "长串无空格的不是提示文字")
        XCTAssertNil(ResponseSnippet.make(Data()))
        XCTAssertEqual(ResponseSnippet.make(Data(String(repeating: "错误 ", count: 60).utf8), limit: 10)?.count, 11)
    }

    func testNodeSampleIsAnonymizedAndParses() throws {
        let data = try Data(contentsOf: V02Tests.fixtures.appendingPathComponent("panel-trojan-colon-names.yaml"))
        let nodes = try SubscriptionParser.parse(data).nodes
        let sample = NodeSample.anonymizedJSON(nodes: nodes)
        XCTAssertFalse(sample.contains("placeholder-password"))
        XCTAssertFalse(sample.contains("hk1.example.com"))
        XCTAssertTrue(sample.contains("日本-PRO-FW-JP2-流量倍率:0.2"))
        XCTAssertTrue(sample.contains("465"))
        let again = try SubscriptionParser.parse(Data(sample.utf8))
        XCTAssertEqual(again.nodes.count, 8, "样本可以直接放进 Fixtures 作回归测试")
        XCTAssertFalse(again.isRefusalPlaceholder)
    }
}
