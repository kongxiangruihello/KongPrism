import XCTest
@testable import KongPrismCore

final class V03Tests: XCTestCase {
    func testHostExtraction() {
        XCTAssertEqual(RouteExplainer.host(from: "https://Scholar.Google.com/scholar?q=x"), "scholar.google.com")
        XCTAssertEqual(RouteExplainer.host(from: "www.cnki.net:8080/a"), "www.cnki.net")
        XCTAssertEqual(RouteExplainer.host(from: "[2001:db8::1]:443"), "2001:db8::1")
        XCTAssertEqual(RouteExplainer.host(from: "  example.org.  "), "example.org")
    }

    func testRuleOrder() {
        var options = CoreOptions()
        options.directDomains = ["example.cn"]
        options.proxyDomains = ["example.org"]
        let cn: Set<String> = ["www.baidu.com"], notCN: Set<String> = ["www.google.com"], ads: Set<String> = ["ads.example.net"]
        let matcher: (RuleSet, String) -> Bool = { set, host in
            switch set.tag {
            case RuleSet.geositeCN.tag: return cn.contains(host)
            case RuleSet.geositeNotCN.tag: return notCN.contains(host)
            case RuleSet.ads.tag: return ads.contains(host)
            case RuleSet.geoipCN.tag: return host == "114.114.114.114"
            default: return false
            }
        }
        func target(_ host: String, _ options: CoreOptions = options) -> RouteExplainer.Target {
            RouteExplainer.explain(host, options: options, inRuleSet: matcher).target
        }
        XCTAssertEqual(target("https://www.baidu.com"), .direct)
        XCTAssertEqual(target("www.google.com"), .proxy)
        XCTAssertEqual(target("ads.example.net"), .reject)
        XCTAssertEqual(target("a.example.cn"), .direct)
        XCTAssertEqual(target("deep.sub.example.org"), .proxy)
        XCTAssertEqual(target("unknown.example"), .proxy)
        XCTAssertEqual(target("192.168.1.1"), .direct)
        XCTAssertEqual(target("114.114.114.114"), .direct)
        XCTAssertEqual(target("8.8.8.8"), .proxy)
        var smart = options
        smart.smartIPRouting = true
        XCTAssertEqual(target("unknown.example", smart), .byIP)
        var global = options
        global.mode = "Global"
        XCTAssertEqual(target("www.baidu.com", global), .proxy)
    }

    func testBackupSubscriptionGroups() throws {
        let primary = try ["HK 01", "HK 02", "JP 01"].map { try ShareLinks.parse("trojan://pw@p.example.com:443#\($0.replacingOccurrences(of: " ", with: "%20"))") }
        let backup = try ["HK 01", "US 01"].map { try ShareLinks.parse("anytls://pw@b.example.com:443#\($0.replacingOccurrences(of: " ", with: "%20"))") }
        let built = ConfigBuilder.build(nodes: primary, backupNodes: backup, options: CoreOptions())
        let outbounds = try XCTUnwrap(built.json["outbounds"]?.arrayValue)
        let tags = outbounds.compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(Set(tags).count, tags.count, "两份订阅的同名节点必须改名")
        XCTAssertEqual(built.backupTags, ["HK 01 2", "US 01"])
        let auto = try XCTUnwrap(outbounds.first { $0["tag"] == .string(Groups.auto) })
        XCTAssertEqual(auto["outbounds"]?.arrayValue?.count, 3, "自动选择只含主用订阅")
        let backupGroup = try XCTUnwrap(outbounds.first { $0["tag"] == .string(Groups.backup) })
        XCTAssertEqual(backupGroup["outbounds"], ["HK 01 2", "US 01"])
        XCTAssertEqual(outbounds.first?["default"], .string(Groups.auto))
        for (index, tag) in built.nodeTags.enumerated() { XCTAssertEqual(outbounds[built.nodeOffset + index]["tag"]?.stringValue, tag) }
        XCTAssertEqual(built.nodeProtocols["US 01"], "AnyTLS")
        XCTAssertEqual(built.json["dns"]?["optimistic"], true)
    }

    func testCheckedBuildDropsFromEitherList() throws {
        let primary = [try ShareLinks.parse("trojan://pw@p.example.com:443#Good")]
        let backup = [ProxyNode(name: "BadBackup", outbound: ["type": "vless", "server": "x", "server_port": 1, "uuid": "u", "transport": ["type": "xhttp"]])]
        var calls = 0
        let outcome = try CheckedBuild.build(nodes: primary, backupNodes: backup, options: CoreOptions()) { built in
            calls += 1
            if built.nodeTags.contains("BadBackup") {
                return (false, "decode config: outbounds[\(built.nodeOffset + built.nodeTags.firstIndex(of: "BadBackup")!)].transport: unknown transport type: xhttp")
            }
            return (true, "")
        }
        XCTAssertEqual(outcome.dropped.map { $0.name }, ["BadBackup"])
        XCTAssertEqual(outcome.built.nodeTags, ["Good"])
        XCTAssertEqual(calls, 2)
    }

    /// The app asks `sing-box rule-set match` and looks for "match rules" in its output.
    func testRouteLookupWithRealRuleFiles() throws {
        guard let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("KONGPRISM_SINGBOX 未设置")
        }
        let rules = V02Tests.repo.appendingPathComponent("Resources/rules")
        func matches(_ set: RuleSet, _ host: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["rule-set", "match", "-f", "binary", rules.appendingPathComponent(set.file).path, host, "--disable-color"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return process.terminationStatus == 0 && output.contains("match rules")
        }
        let options = CoreOptions()
        XCTAssertEqual(RouteExplainer.explain("https://www.baidu.com", options: options, inRuleSet: matches).target, .direct)
        XCTAssertEqual(RouteExplainer.explain("www.google.com", options: options, inRuleSet: matches).target, .proxy)
        XCTAssertEqual(RouteExplainer.explain("114.114.114.114", options: options, inRuleSet: matches).target, .direct)
        XCTAssertEqual(RouteExplainer.explain("8.8.8.8", options: options, inRuleSet: matches).target, .proxy)
    }
}
