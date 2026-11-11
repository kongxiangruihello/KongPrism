import XCTest
@testable import KongPrismCore

final class V04Tests: XCTestCase {
    func nodes() throws -> [ProxyNode] {
        try ["🇭🇰 香港 01", "🇭🇰 香港 02", "🇯🇵 日本 01", "🇯🇵 日本 02", "🇺🇸 美国 01", "🇸🇬 新加坡 01"].map {
            try ShareLinks.parse("trojan://pw@s.example.com:443#" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0))
        }
    }

    func testServiceGroups() throws {
        var options = CoreOptions()
        options.serviceTargets = ["ai": Service.noHK, "youtube": "JP", "netflix": Service.direct]
        let built = ConfigBuilder.build(nodes: try nodes(), options: options)
        let outbounds = try XCTUnwrap(built.json["outbounds"]?.arrayValue)
        let ai = try XCTUnwrap(outbounds.first { $0["tag"] == .string(Service.ai.groupName) })
        XCTAssertEqual(ai["type"], "urltest")
        XCTAssertFalse(ai["outbounds"]?.arrayValue?.contains("🇭🇰 香港 01") ?? true, "AI 组不含香港节点")
        XCTAssertEqual(ai["outbounds"]?.arrayValue?.count, 4)
        let youtube = try XCTUnwrap(outbounds.first { $0["tag"] == .string(Service.youtube.groupName) })
        XCTAssertEqual(youtube["outbounds"], ["🇯🇵 日本 01", "🇯🇵 日本 02"])
        XCTAssertNil(outbounds.first { $0["tag"] == .string(Service.netflix.groupName) }, "直连不建组")

        let rules = try XCTUnwrap(built.json["route"]?["rules"]?.arrayValue)
        let index = { (tag: String) in rules.firstIndex { $0["rule_set"]?.arrayValue?.first?.stringValue == tag } }
        XCTAssertLessThan(try XCTUnwrap(index(RuleSet.ai.tag)), try XCTUnwrap(index(RuleSet.geositeCN.tag)), "服务规则在国内列表之前")
        XCTAssertEqual(rules[try XCTUnwrap(index(RuleSet.netflix.tag))]["outbound"], .string(Groups.direct))
        let declared = built.json["route"]?["rule_set"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []
        XCTAssertTrue(declared.contains(RuleSet.ai.tag))
        XCTAssertTrue(built.groups.contains(Service.ai.groupName))
    }

    func testServiceRegionWithoutNodesFallsBack() throws {
        var options = CoreOptions()
        options.serviceTargets = ["ai": "KR"]
        let built = ConfigBuilder.build(nodes: try nodes(), options: options)
        let ai = built.json["outbounds"]?.arrayValue?.first { $0["tag"] == .string(Service.ai.groupName) }
        XCTAssertEqual(ai?["outbounds"]?.arrayValue?.count, 6, "没有韩国节点时用全部节点")
    }

    func testNoServicesMeansNoExtraRuleSets() throws {
        let built = ConfigBuilder.build(nodes: try nodes(), options: CoreOptions())
        let declared = built.json["route"]?["rule_set"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []
        XCTAssertFalse(declared.contains(RuleSet.ai.tag))
        XCTAssertFalse(declared.contains(RuleSet.youtube.tag))
    }

    func testExplainerKnowsServices() {
        var options = CoreOptions()
        options.serviceTargets = ["ai": "US"]
        let answer = RouteExplainer.explain("https://chatgpt.com", options: options) { set, host in
            set == .ai && host == "chatgpt.com" || set == .geositeNotCN
        }
        XCTAssertEqual(answer.target, .service(Service.ai.groupName))
    }

    /// The real sing-box accepts service routing (and the rule files exist in the app).
    func testSingBoxAcceptsServiceRouting() throws {
        guard let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("KONGPRISM_SINGBOX 未设置")
        }
        var options = CoreOptions()
        options.serviceTargets = ["ai": Service.noHK, "youtube": "JP", "netflix": Service.direct]
        options.rulesDirectory = V02Tests.repo.appendingPathComponent("Resources/rules").path
        let built = ConfigBuilder.build(nodes: try nodes(), options: options)
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("services-\(UUID().uuidString).json")
        try built.data.write(to: config)
        defer { try? FileManager.default.removeItem(at: config) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["check", "-c", config.path, "--disable-color"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
