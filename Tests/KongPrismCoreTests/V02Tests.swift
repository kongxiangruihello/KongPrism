import XCTest
@testable import KongPrismCore

final class V02Tests: XCTestCase {
    static var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var fixtures: URL { repo.appendingPathComponent("Tests/KongPrismCoreTests/Fixtures") }

    func testSpeedText() {
        XCTAssertEqual(SpeedText.compact(0), "0B")
        XCTAssertEqual(SpeedText.compact(860), "860B")
        XCTAssertEqual(SpeedText.compact(12 * 1024), "12K")
        XCTAssertEqual(SpeedText.compact(1_258_291), "1.2M")
        XCTAssertEqual(SpeedText.compact(15 * 1024 * 1024), "15M")
    }

    func testExitInfo() throws {
        let sb = try XCTUnwrap(ExitInfo(json: ["ip": "203.0.113.5", "country_code": "HK", "country": "Hong Kong", "organization": "Example Networks"]))
        XCTAssertEqual(sb.summary, "🇭🇰 香港 · 203.0.113.5 · Example Networks")
        let ipinfo = try XCTUnwrap(ExitInfo(json: ["ip": "198.51.100.7", "country": "JP", "city": "Tokyo", "org": "AS64500 Example"]))
        XCTAssertEqual(ipinfo.countryCode, "JP")
        XCTAssertTrue(ipinfo.summary.hasPrefix("🇯🇵 日本"))
        XCTAssertNil(ExitInfo(json: ["error": "x"]))
    }

    func testAnonymizerKeepsStructureAndRemovesSecrets() throws {
        let original = SubscriptionTests.clashYAML
        let anonymized = SubscriptionSample.anonymize(original)
        for secret in ["hk1.example.com", "bf000d23-0752-40b4-affe-68f7707a9661", "it''s", "\"0123\"", "us.example.com", "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0X"] {
            XCTAssertFalse(anonymized.contains(secret), "仍包含 \(secret)")
        }
        let before = try SubscriptionParser.parse(Data(original.utf8))
        let after = try SubscriptionParser.parse(Data(anonymized.utf8))
        XCTAssertEqual(after.nodes.map(\.name), before.nodes.map(\.name))
        XCTAssertEqual(after.nodes.map(\.type), before.nodes.map(\.type))
        XCTAssertEqual(after.skipped, before.skipped)
    }

    func testAnonymizerHandlesLinks() {
        let links = "trojan://secret@real.example.net:443?sni=real.example.net&type=ws#HK%2001\nanytls://pw@x.example.net:8443#B"
        let anonymized = SubscriptionSample.anonymize(Data(links.utf8).base64EncodedString())
        XCTAssertFalse(anonymized.contains("secret"))
        XCTAssertFalse(anonymized.contains("real.example.net"))
        XCTAssertEqual(ShareLinks.parseList(anonymized).nodes.map(\.name), ["HK 01", "B"])
    }

    func testTunInbound() throws {
        var options = CoreOptions()
        options.tun = true
        let inbounds = ConfigBuilder.build(nodes: [], options: options).json["inbounds"]?.arrayValue ?? []
        XCTAssertEqual(inbounds.compactMap { $0["type"]?.stringValue }, ["mixed", "tun"])
        XCTAssertEqual(inbounds.last?["auto_route"], true)
        XCTAssertEqual(ConfigBuilder.build(nodes: [], options: CoreOptions()).json["inbounds"]?.arrayValue?.count, 1)
    }

    /// Every sample in Fixtures/ must keep working (the bugs of 0.1.x only showed with real subscriptions).
    func testFixtures() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil)
            .filter { ["yaml", "yml", "json", "txt"].contains($0.pathExtension) }
        XCTAssertFalse(files.isEmpty)
        let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        for file in files {
            let result = try SubscriptionParser.parse(try Data(contentsOf: file))
            if file.lastPathComponent.hasPrefix("refused") {
                XCTAssertTrue(result.isRefusalPlaceholder, file.lastPathComponent)
                continue
            }
            XCTAssertFalse(result.isRefusalPlaceholder, file.lastPathComponent)
            for tun in [false, true] {
                var options = CoreOptions()
                options.tun = tun
                options.rulesDirectory = Self.repo.appendingPathComponent("Resources/rules").path
                let built = ConfigBuilder.build(nodes: result.nodes, options: options)
                XCTAssertFalse(built.nodeTags.isEmpty, "\(file.lastPathComponent)：配置里没有节点")
                XCTAssertEqual(built.nodeTags.count, result.nodes.filter { !NodeFilter.isInformational($0.name) }.count, file.lastPathComponent)
                guard let binary else { continue }
                let config = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).json")
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
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, "\(file.lastPathComponent)（TUN \(tun)）：\(output)")
            }
        }
    }
}
