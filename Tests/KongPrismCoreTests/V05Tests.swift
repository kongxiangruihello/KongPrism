import XCTest
@testable import KongPrismCore

final class V05Tests: XCTestCase {
    func customSet(directory: URL) throws -> RuleSet {
        let file = "custom-test.json"
        try #"{"version": 2, "rules": [{"domain_suffix": ["example.org"]}]}"#.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return RuleSet(tag: "custom-test", file: file, urls: ["https://example.com/rules.json"])
    }

    func testCustomRuleSetInConfig() throws {
        let set = RuleSet(tag: "custom-a", file: "custom-a.srs", urls: [])
        var options = CoreOptions()
        options.customRuleSets = [CustomRule(set: set, target: "direct"), CustomRule(set: RuleSet(tag: "custom-b", file: "custom-b.json", urls: []), target: "reject")]
        let built = ConfigBuilder.build(nodes: [], options: options)
        let declared = built.json["route"]?["rule_set"]?.arrayValue ?? []
        XCTAssertEqual(declared.first { $0["tag"] == "custom-a" }?["format"], "binary")
        XCTAssertEqual(declared.first { $0["tag"] == "custom-b" }?["format"], "source")
        let rules = built.json["route"]?["rules"]?.arrayValue ?? []
        let a = try XCTUnwrap(rules.firstIndex { $0["rule_set"]?.arrayValue?.first == "custom-a" })
        let cn = try XCTUnwrap(rules.firstIndex { $0["rule_set"]?.arrayValue?.first == .string(RuleSet.geositeCN.tag) })
        XCTAssertLessThan(a, cn, "自定义规则集在内置列表之前")
        XCTAssertEqual(rules[a]["outbound"], .string(Groups.direct))
        XCTAssertEqual(rules.first { $0["rule_set"]?.arrayValue?.first == "custom-b" }?["action"], "reject")
        let answer = RouteExplainer.explain("www.example.org", options: options) { set, _ in set.tag == "custom-b" }
        XCTAssertEqual(answer.target, .reject)
    }

    func testSingBoxAcceptsCustomSourceRuleSet() throws {
        guard let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("KONGPRISM_SINGBOX 未设置")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in try FileManager.default.contentsOfDirectory(atPath: V02Tests.repo.appendingPathComponent("Resources/rules").path) {
            try FileManager.default.copyItem(at: V02Tests.repo.appendingPathComponent("Resources/rules/\(file)"), to: directory.appendingPathComponent(file))
        }
        var options = CoreOptions()
        options.rulesDirectory = directory.path
        options.customRuleSets = [CustomRule(set: try customSet(directory: directory), target: "proxy")]
        let config = directory.appendingPathComponent("config.json")
        try ConfigBuilder.build(nodes: [], options: options).data.write(to: config)
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

    static let clashYAML = """
    # Loyalsoldier style
    payload:
      - '+.google.com'
      - '.sub.org'
      - '*.one.net'
      - 'exact.net'
      - '1.2.3.0/24'
      - 'DOMAIN-KEYWORD,kw'
      - 'IP-CIDR6,2001:db8::/32,no-resolve'
      - 'PROCESS-NAME,curl'
    """

    func testConvertClashProvider() throws {
        let result = try XCTUnwrap(CustomRuleSource.convert(Data(Self.clashYAML.utf8)))
        guard case .source(let data) = result.converted else { return XCTFail("应转换成 source") }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rule = try XCTUnwrap((object["rules"] as? [[String: Any]])?.first)
        XCTAssertEqual(rule["domain_suffix"] as? [String], ["google.com", ".sub.org"])
        XCTAssertEqual(rule["domain"] as? [String], ["exact.net"])
        XCTAssertEqual(rule["domain_keyword"] as? [String], ["kw"])
        XCTAssertEqual(rule["domain_regex"] as? [String], [#"^[^.]+\.one\.net$"#])
        XCTAssertEqual(rule["ip_cidr"] as? [String], ["1.2.3.0/24", "2001:db8::/32"])
        XCTAssertEqual(result.summary?.skipped, 1)
        XCTAssertEqual(result.converted.fileExtension, "json")
    }

    func testConvertOtherFormats() throws {
        XCTAssertEqual(CustomRuleSource.convert(Data("SRS".utf8) + Data(repeating: 1, count: 40))?.converted.fileExtension, "srs")
        let json = Data(#"{"version": 3, "rules": [{"domain": ["a.com"]}]}"#.utf8)
        XCTAssertEqual(CustomRuleSource.convert(json)?.converted, .source(json))
        let text = CustomRuleSource.convert(Data("# list\nexample.com\n10.0.0.0/8\n".utf8))
        XCTAssertEqual(text?.summary?.domains, 1)
        XCTAssertEqual(text?.summary?.cidrs, 1)
        XCTAssertNil(CustomRuleSource.convert(Data("<html><body>404</body></html>".utf8)))
        XCTAssertNil(CustomRuleSource.convert(Data()))
        XCTAssertEqual(CustomRuleSource.tag(for: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!), "custom-abcdef12")
    }

    func testSingBoxMatchesConvertedClashProvider() throws {
        guard let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("KONGPRISM_SINGBOX 未设置")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try XCTUnwrap(CustomRuleSource.convert(Data(Self.clashYAML.utf8))).converted.data.write(to: file)
        func matches(_ host: String) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["rule-set", "match", "-f", "source", file.path, host, "--disable-color"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("match rules")
        }
        for host in ["google.com", "www.google.com", "a.sub.org", "x.one.net", "exact.net", "akwb.com", "1.2.3.4"] {
            XCTAssertTrue(try matches(host), host)
        }
        for host in ["notgoogle.com", "sub.org", "a.b.one.net", "www.exact.net", "5.6.7.8"] {
            XCTAssertFalse(try matches(host), host)
        }
    }
}
