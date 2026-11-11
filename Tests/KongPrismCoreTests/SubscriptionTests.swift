import XCTest
@testable import KongPrismCore

final class SubscriptionTests: XCTestCase {
    static let clashYAML = """
    # 机场订阅示例
    mixed-port: 7890
    allow-lan: false
    proxies:
      - {name: "🇭🇰 香港 01", type: ss, server: hk1.example.com, port: 30001, cipher: aes-128-gcm, password: "0123", udp: true}
      - {name: 🇭🇰 香港 02, type: vmess, server: hk2.example.com, port: 443, uuid: bf000d23-0752-40b4-affe-68f7707a9661, alterId: 0, cipher: auto, tls: true, servername: hk2.example.com, network: ws, ws-opts: {path: /ws, headers: {Host: hk2.example.com}}}
      - name: "🇯🇵 日本 Reality"
        type: vless
        server: 203.0.113.7
        port: 443
        uuid: bf000d23-0752-40b4-affe-68f7707a9661
        network: grpc
        tls: true
        servername: www.microsoft.com
        client-fingerprint: chrome
        flow: ""
        reality-opts:
          public-key: jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0
          short-id: 0123abcd # 注释
        grpc-opts:
          grpc-service-name: "grpc"
      - name: 🇺🇸 美国 Hy2
        type: hysteria2
        server: us.example.com
        port: 443
        ports: 20000-30000
        password: 'it''s'
        up: "50 Mbps"
        down: 200
        sni: us.example.com
        skip-cert-verify: true
      - name: 🇸🇬 新加坡 TUIC
        type: tuic
        server: sg.example.com
        port: 8443
        uuid: 2DD61D93-75D8-4DA4-AC0E-6AECE7EAC365
        password: hello
        alpn: [h3]
        congestion-controller: bbr
        udp-relay-mode: native
      - {name: 剩余流量：100 GB, type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: x}
      - {name: WG, type: wireguard, server: 1.1.1.1, port: 51820, private-key: x}
      - name: Trojan
        type: trojan
        server: tr.example.com
        port: 443
        password: secret
        sni: tr.example.com
        alpn:
          - h2
          - http/1.1
    proxy-groups:
      - name: 节点选择
        type: select
        proxies: [🇭🇰 香港 01, DIRECT]
    rules:
      - MATCH,节点选择
    """

    func testMiniYAMLBasics() throws {
        let value = try MiniYAML.parse("""
        a: 1
        b: "x # not a comment"
        c: 0123
        d:
          - one
          - two: 2
            three: [3, "4", {five: 5}]
        e: |
          line1
          line2
        f: 'single ''quoted'''
        g: true # comment
        """)
        XCTAssertEqual(value["a"], 1)
        XCTAssertEqual(value["b"], "x # not a comment")
        XCTAssertEqual(value["c"], "0123")
        XCTAssertEqual(value["d"]?.arrayValue?.first, "one")
        XCTAssertEqual(value["d"]?.arrayValue?.last?["two"], 2)
        XCTAssertEqual(value["d"]?.arrayValue?.last?["three"], [3, "4", ["five": 5]])
        XCTAssertEqual(value["e"], "line1\nline2")
        XCTAssertEqual(value["f"], "single 'quoted'")
        XCTAssertEqual(value["g"], true)
    }

    func testMiniYAMLSequenceAtKeyIndent() throws {
        let value = try MiniYAML.parse("proxies:\n- name: a\n  type: ss\n- name: b\nother: 1\n")
        XCTAssertEqual(value["proxies"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["proxies"]?.arrayValue?.first?["type"], "ss")
        XCTAssertEqual(value["other"], 1)
    }

    func testMiniYAMLMultilineFlow() throws {
        let value = try MiniYAML.parse("proxies:\n  - {name: a, type: ss,\n     server: s, port: 1}\n")
        XCTAssertEqual(value["proxies"]?.arrayValue?.first?["server"], "s")
    }

    func testClashSubscription() throws {
        let result = try SubscriptionParser.parse(Data(Self.clashYAML.utf8))
        XCTAssertEqual(result.format, .clash)
        XCTAssertEqual(result.skipped, 1) // wireguard
        let byName = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.name, $0) })
        XCTAssertEqual(byName["🇭🇰 香港 01"]?.outbound["password"], "0123")
        XCTAssertEqual(byName["🇭🇰 香港 02"]?.outbound["transport"]?["headers"]?["Host"], "hk2.example.com")
        let reality = try XCTUnwrap(byName["🇯🇵 日本 Reality"])
        XCTAssertEqual(reality.outbound["tls"]?["reality"]?["short_id"], "0123abcd")
        XCTAssertEqual(reality.outbound["transport"]?["service_name"], "grpc")
        XCTAssertNil(reality.outbound["flow"])
        let hy2 = try XCTUnwrap(byName["🇺🇸 美国 Hy2"])
        XCTAssertEqual(hy2.outbound["password"], "it's")
        XCTAssertEqual(hy2.outbound["server_ports"], ["20000:30000"])
        XCTAssertEqual(hy2.outbound["up_mbps"], 50)
        XCTAssertEqual(hy2.outbound["down_mbps"], 200)
        XCTAssertEqual(byName["Trojan"]?.outbound["tls"]?["alpn"], ["h2", "http/1.1"])
        XCTAssertNotNil(byName["剩余流量：100 GB"])
    }

    func testBase64LinkList() throws {
        let links = """
        trojan://pw@a.example.com:443#A
        vless://u@b.example.com:443?security=tls&type=xhttp#Unsupported
        anytls://pw@c.example.com:443#C
        """
        let result = try SubscriptionParser.parse(Data(Data(links.utf8).base64EncodedString().utf8))
        XCTAssertEqual(result.format, .links)
        XCTAssertEqual(result.nodes.map(\.name), ["A", "C"])
        XCTAssertEqual(result.skipped, 1)
    }

    func testSingBoxSubscription() throws {
        let json = """
        {"outbounds":[
          {"type":"selector","tag":"proxy","outbounds":["a"]},
          {"type":"shadowsocks","tag":"a","server":"1.1.1.1","server_port":1,"method":"aes-128-gcm","password":"p","detour":"x"},
          {"type":"direct","tag":"direct"},
          {"type":"vless","tag":"a","server":"2.2.2.2","server_port":2,"uuid":"u"}
        ]}
        """
        let result = try SubscriptionParser.parse(Data(json.utf8))
        XCTAssertEqual(result.format, .singBox)
        XCTAssertEqual(result.nodes.map(\.name), ["a", "a 2"])
        XCTAssertNil(result.nodes[0].outbound["detour"])
        XCTAssertNil(result.nodes[0].outbound["tag"])
    }

    func testGarbageFails() {
        XCTAssertThrowsError(try SubscriptionParser.parse(Data("<html>login</html>".utf8)))
        XCTAssertThrowsError(try SubscriptionParser.parse(Data()))
    }

    func testUsageHeader() throws {
        let usage = try XCTUnwrap(SubscriptionUsage(header: "upload=1073741824; download=2147483648; total=107374182400; expire=1798675200"))
        XCTAssertEqual(usage.used, 3_221_225_472)
        XCTAssertTrue(usage.summary.hasPrefix("已用 3.0 GB / 100 GB"))
        XCTAssertNotNil(usage.expire)
        XCTAssertNil(SubscriptionUsage(header: "foo=bar"))
    }

    func testVersions() {
        XCTAssertTrue(Versions.isNewer("1.14.10", than: "1.14.4"))
        XCTAssertTrue(Versions.isNewer("v0.2.0", than: "0.1.9"))
        XCTAssertFalse(Versions.isNewer("1.15.0-alpha.1", than: "1.15.0"))
        XCTAssertTrue(Versions.isNewer("1.15.0", than: "1.15.0-rc.2"))
        XCTAssertFalse(Versions.isNewer("1.0", than: "1.0.0"))
        XCTAssertEqual(Versions.singBoxVersion(fromOutput: "sing-box version 1.14.4\n\nEnvironment: go1.26"), "1.14.4")
        XCTAssertEqual(Versions.tag(fromReleaseURL: "https://github.com/SagerNet/sing-box/releases/tag/v1.14.4"), "v1.14.4")
    }
}
