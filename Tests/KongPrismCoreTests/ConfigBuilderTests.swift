import XCTest
@testable import KongPrismCore

final class ConfigBuilderTests: XCTestCase {
    func nodes() throws -> [ProxyNode] {
        try SubscriptionParser.parse(Data(SubscriptionTests.clashYAML.utf8)).nodes
    }

    func testGroupsAndNodes() throws {
        var options = CoreOptions()
        options.apiSecret = "s"
        let built = ConfigBuilder.build(nodes: try nodes(), options: options)
        let outbounds = try XCTUnwrap(built.json["outbounds"]?.arrayValue)
        let tags = outbounds.compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(tags.first, Groups.select)
        XCTAssertTrue(tags.contains(Groups.auto))
        XCTAssertTrue(tags.contains("🇭🇰 香港"), "两个香港节点应生成地区组")
        XCTAssertFalse(tags.contains("🇯🇵 日本"), "只有一个节点的地区不建组")
        XCTAssertFalse(tags.contains("剩余流量：100 GB"), "信息条目不进配置")
        XCTAssertEqual(tags.last, Groups.direct)
        XCTAssertEqual(Set(tags).count, tags.count, "tag 必须唯一")
        // nodeOffset/nodeTags line up with outbounds, for mapping `sing-box check` errors back to nodes.
        for (index, tag) in built.nodeTags.enumerated() {
            XCTAssertEqual(outbounds[built.nodeOffset + index]["tag"]?.stringValue, tag)
        }
        let selector = try XCTUnwrap(outbounds.first)
        XCTAssertEqual(selector["default"], .string(Groups.auto))
        XCTAssertEqual(built.json["experimental"]?["clash_api"]?["secret"], "s")
        XCTAssertEqual(built.json["inbounds"]?.arrayValue?.first?["listen"], "127.0.0.1")
    }

    func testEmptyProfileStillBuilds() {
        let built = ConfigBuilder.build(nodes: [], options: CoreOptions())
        let tags = built.json["outbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(tags, [Groups.select, Groups.direct])
        XCTAssertNil(built.json["dns"]?["servers"]?.arrayValue?.first?["detour"])
    }

    func testDNSServerParsing() {
        XCTAssertEqual(ConfigBuilder.dnsServer("https://1.1.1.1/dns-query", tag: "r", detour: "p"),
                       ["type": "https", "tag": "r", "server": "1.1.1.1", "detour": "p"])
        XCTAssertEqual(ConfigBuilder.dnsServer("223.5.5.5", tag: "l", detour: nil),
                       ["type": "udp", "tag": "l", "server": "223.5.5.5"])
        XCTAssertEqual(ConfigBuilder.dnsServer("tls://dns.google:853", tag: "t", detour: nil),
                       ["type": "tls", "tag": "t", "server": "dns.google", "server_port": 853, "domain_resolver": "dns-bootstrap"])
        XCTAssertEqual(ConfigBuilder.dnsServer("https://doh.pub/custom", tag: "c", detour: nil)["path"], "/custom")
    }

    func testCheckErrorParsing() {
        XCTAssertEqual(CheckError.outboundIndex(in: "FATAL decode config at c.json: outbounds[12].transport: unknown type"), 12)
        XCTAssertEqual(CheckError.outboundIndex(in: "\u{1B}[31mFATAL\u{1B}[0m[0000] initialize outbound[9]: bad key length, required 16, got 32"), 9)
        XCTAssertEqual(CheckError.readable("\u{1B}[31mFATAL\u{1B}[0m[0000] initialize outbound[9]: bad key length"), "initialize outbound[9]: bad key length")
        XCTAssertNil(CheckError.outboundIndex(in: "nothing"))
        XCTAssertEqual(CheckError.outboundTag(in: "initialize outbound[3]: outbound/vless[HK 01]: bad", among: ["HK 0", "HK 01"]), "HK 01")
    }

    func testRegionMatching() {
        XCTAssertEqual(Region.of("🇭🇰 香港 IEPL 01")?.code, "HK")
        XCTAssertEqual(Region.of("US-LA 02")?.code, "US")
        XCTAssertNil(Region.of("RUSSIA 01"), "US inside a word must not match")
        XCTAssertEqual(Region.of("日本东京")?.code, "JP")
        XCTAssertTrue(NodeFilter.isInformational("套餐到期：2027-01-01"))
        XCTAssertFalse(NodeFilter.isInformational("🇸🇬 新加坡 01"))
    }

    /// Bad nodes (wrong key length, transport sing-box lacks) are dropped one by one by the real `sing-box check`.
    func testBrokenNodesAreDropped() throws {
        guard let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("KONGPRISM_SINGBOX 未设置")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongprism-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var nodes = [
            try ShareLinks.parse("trojan://pw@good.example.com:443#Good"),
            try ShareLinks.parse("ss://2022-blake3-aes-128-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D@1.2.3.4:443#BadKey"),
        ]
        nodes.append(ProxyNode(name: "BadTransport", outbound: ["type": "vless", "server": "x.example.com", "server_port": 443, "uuid": "u",
                                                                "transport": ["type": "xhttp"]]))
        var options = CoreOptions()
        options.rulesDirectory = repo.appendingPathComponent("Resources/rules").path
        let config = directory.appendingPathComponent("config.json")
        let outcome = try CheckedBuild.build(nodes: nodes, options: options) { built in
            try built.data.write(to: config)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["check", "-c", config.path, "--disable-color"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        XCTAssertEqual(Set(outcome.dropped.map { $0.name }), ["BadKey", "BadTransport"])
        XCTAssertEqual(outcome.built.nodeTags, ["Good"])
    }

    /// Runs the real `sing-box check` on a generated config when KONGPRISM_SINGBOX points to a
    /// sing-box binary (the build script and CI set it).
    func testSingBoxAcceptsGeneratedConfig() throws {
        guard let binary = ProcessInfo.processInfo.environment["KONGPRISM_SINGBOX"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("KONGPRISM_SINGBOX 未设置")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongprism-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var all = try nodes()
        let links = [
            "ss://2022-blake3-aes-128-gcm:8JCsPssfgS8tiRwiMlhARg%3D%3D@1.2.3.4:443#SS2022",
            "ss://2022-blake3-aes-256-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D@1.2.3.5:443#SS2022-256",
            "vless://bf000d23-0752-40b4-affe-68f7707a9661@203.0.113.9:443?flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=6ba85179e30d4fc2#R",
            "vless://bf000d23-0752-40b4-affe-68f7707a9661@a.com:443?security=tls&type=ws&path=%2Fws%3Fed%3D2048&host=a.com#WS",
            "hy2://pw@hy.example.com:443,20000-30000/?sni=hy.example.com&obfs=salamander&obfs-password=xyz#HY",
            "tuic://bf000d23-0752-40b4-affe-68f7707a9661:p@tu.example.com:443?congestion_control=bbr&alpn=h3#TU",
            "anytls://pw@any.example.com:443?sni=any.example.com#ANY",
            "trojan://pw@tr.example.com:443?type=grpc&serviceName=g#TRG",
        ]
        all += try links.map(ShareLinks.parse)
        var options = CoreOptions()
        options.apiSecret = "x"
        options.rulesDirectory = repo.appendingPathComponent("Resources/rules").path
        options.cachePath = directory.appendingPathComponent("cache.db").path
        options.directDomains = ["example.cn"]
        options.proxyDomains = ["example.org"]
        let built = ConfigBuilder.build(nodes: all, options: options)
        let config = directory.appendingPathComponent("config.json")
        try built.data.write(to: config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["check", "-c", config.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertFalse(output.contains("deprecated"), output)
    }
}
