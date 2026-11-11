import XCTest
@testable import KongPrismCore

final class V09Tests: XCTestCase {
    private func node(_ name: String) -> ProxyNode {
        try! ShareLinks.parse("trojan://secret@\(UUID().uuidString.prefix(8).lowercased()).example.com:465?sni=sni.example.com#\(name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!)")
    }

    func testAICheckInbound() throws {
        var options = CoreOptions()
        options.aiCheckPort = 9100
        options.serviceTargets = [Service.ai.rawValue: Service.noHK]
        let built = ConfigBuilder.build(nodes: ["香港 01", "日本 01", "日本 02"].map(node), options: options)
        let inbound = try XCTUnwrap(built.json["inbounds"]?.arrayValue?.first { $0["tag"] == "ai-check" })
        XCTAssertEqual(inbound["listen"], "127.0.0.1", "只在本机")
        XCTAssertEqual(inbound["listen_port"], 9100)
        let rules = built.json["route"]?["rules"]?.arrayValue ?? []
        let index = try XCTUnwrap(rules.firstIndex { $0["inbound"]?.arrayValue?.first == "ai-check" })
        XCTAssertEqual(rules[index]["outbound"], .string(Service.ai.groupName))
        let privateIndex = try XCTUnwrap(rules.firstIndex { $0["ip_is_private"] == true })
        XCTAssertLessThan(index, privateIndex, "检测规则在其他规则之前")

        options.serviceTargets = [:]
        let follow = ConfigBuilder.build(nodes: ["香港 01"].map(node), options: options)
        XCTAssertEqual(follow.json["route"]?["rules"]?.arrayValue?.first { $0["inbound"] != nil }?["outbound"], .string(Groups.select),
                       "AI 跟随节点选择时，检测也走节点选择")
        options.aiCheckPort = nil
        XCTAssertNil(ConfigBuilder.build(nodes: [], options: options).json["inbounds"]?.arrayValue?.first { $0["tag"] == "ai-check" })
    }

    func testUpdatePlan() throws {
        var release = AppRelease(version: "0.9.1", build: 50, notes: nil, asset: "KongPrism-0.9.1.zip", sha256: "AA", minimumSystemVersion: "13.0")
        XCTAssertEqual(UpdatePlan.choose(release, installedCoreSha256: "cc"), .full(asset: "KongPrism-0.9.1.zip", sha256: "AA"), "旧格式没有精简包")
        release.liteAsset = "KongPrism-0.9.1-lite.zip"
        release.liteSha256 = "BB"
        release.coreSha256 = "CC"
        XCTAssertEqual(UpdatePlan.choose(release, installedCoreSha256: "cc"), .lite(asset: "KongPrism-0.9.1-lite.zip", sha256: "BB"))
        XCTAssertEqual(UpdatePlan.choose(release, installedCoreSha256: "dd"), .full(asset: "KongPrism-0.9.1.zip", sha256: "AA"), "内核变了要下完整包")
        XCTAssertEqual(UpdatePlan.choose(release, installedCoreSha256: nil), .full(asset: "KongPrism-0.9.1.zip", sha256: "AA"))
        // latest.json written by 0.8 (no lite fields) still decodes.
        let old = try JSONDecoder().decode(AppRelease.self, from: Data(#"{"version":"0.8.0","build":42,"asset":"KongPrism-0.8.0.zip","sha256":"x"}"#.utf8))
        XCTAssertNil(old.liteAsset)
    }

    func testPowerPolicy() {
        XCTAssertEqual(PowerPolicy.testInterval(base: 10, saving: false), 10)
        XCTAssertEqual(PowerPolicy.testInterval(base: 10, saving: true), 30)
        XCTAssertEqual(PowerPolicy.testInterval(base: 15, saving: true), 45)
        XCTAssertEqual(PowerPolicy.testInterval(base: 3, saving: true), 30)
    }

    func testAIRegions() {
        XCTAssertEqual(AIRegions.isSupported(countryCode: "JP"), true)
        XCTAssertEqual(AIRegions.isSupported(countryCode: "hk"), false)
        XCTAssertEqual(AIRegions.isSupported(countryCode: "CN"), false)
        XCTAssertEqual(AIRegions.isSupported(countryCode: "TW"), true)
        XCTAssertNil(AIRegions.isSupported(countryCode: nil))
    }
}
