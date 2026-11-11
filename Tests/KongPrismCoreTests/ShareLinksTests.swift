import XCTest
@testable import KongPrismCore

final class ShareLinksTests: XCTestCase {
    func testShadowsocksSIP002Base64() throws {
        let userinfo = Data("aes-256-gcm:pa:ss/w0rd".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let node = try ShareLinks.parse("ss://\(userinfo)@hk.example.com:8388#%F0%9F%87%AD%F0%9F%87%B0%20%E9%A6%99%E6%B8%AF%2001")
        XCTAssertEqual(node.name, "🇭🇰 香港 01")
        XCTAssertEqual(node.outbound["type"], "shadowsocks")
        XCTAssertEqual(node.outbound["server"], "hk.example.com")
        XCTAssertEqual(node.outbound["server_port"], 8388)
        XCTAssertEqual(node.outbound["method"], "aes-256-gcm")
        XCTAssertEqual(node.outbound["password"], "pa:ss/w0rd")
    }

    func testShadowsocks2022PercentEncoded() throws {
        let node = try ShareLinks.parse("ss://2022-blake3-aes-128-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D@1.2.3.4:443#JP")
        XCTAssertEqual(node.outbound["method"], "2022-blake3-aes-128-gcm")
        XCTAssertEqual(node.outbound["password"], "YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI=")
    }

    func testShadowsocksStandardBase64WithSlashInUserinfo() throws {
        // "chacha20-ietf-poly1305:a?>?" encodes with a "/" in standard base64.
        let encoded = Data("chacha20-ietf-poly1305:a?>?".utf8).base64EncodedString()
        XCTAssertTrue(encoded.contains("/"))
        let node = try ShareLinks.parse("ss://\(encoded)@5.6.7.8:1234/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dbing.com#X")
        XCTAssertEqual(node.outbound["password"], "a?>?")
        XCTAssertEqual(node.outbound["server"], "5.6.7.8")
        XCTAssertEqual(node.outbound["plugin"], "obfs-local")
        XCTAssertEqual(node.outbound["plugin_opts"], "obfs=http;obfs-host=bing.com")
    }

    func testShadowsocksLegacy() throws {
        let encoded = Data("rc4-md5:secret@9.9.9.9:8000".utf8).base64EncodedString()
        let node = try ShareLinks.parse("ss://\(encoded)#Old")
        XCTAssertEqual(node.name, "Old")
        XCTAssertEqual(node.outbound["server"], "9.9.9.9")
        XCTAssertEqual(node.outbound["server_port"], 8000)
        XCTAssertEqual(node.outbound["password"], "secret")
    }

    func testVMessJSON() throws {
        let json = """
        {"v":"2","ps":"🇺🇸 US 02","add":"us.example.com","port":"443","id":"bf000d23-0752-40b4-affe-68f7707a9661","aid":"0",
         "scy":"auto","net":"ws","type":"none","host":"cdn.example.com","path":"/ray?ed=2048","tls":"tls","sni":"cdn.example.com","fp":"chrome"}
        """
        let node = try ShareLinks.parse("vmess://" + Data(json.utf8).base64EncodedString())
        XCTAssertEqual(node.name, "🇺🇸 US 02")
        XCTAssertEqual(node.outbound["server_port"], 443)
        XCTAssertEqual(node.outbound["transport"]?["type"], "ws")
        XCTAssertEqual(node.outbound["transport"]?["path"], "/ray")
        XCTAssertEqual(node.outbound["transport"]?["max_early_data"], 2048)
        XCTAssertEqual(node.outbound["transport"]?["headers"]?["Host"], "cdn.example.com")
        XCTAssertEqual(node.outbound["tls"]?["server_name"], "cdn.example.com")
        XCTAssertEqual(node.outbound["tls"]?["utls"]?["fingerprint"], "chrome")
    }

    func testVLESSReality() throws {
        let link = "vless://bf000d23-0752-40b4-affe-68f7707a9661@203.0.113.9:443?encryption=none&flow=xtls-rprx-vision&security=reality"
            + "&sni=www.apple.com&fp=safari&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=6ba85179e30d4fc2&type=tcp#SG%20Reality"
        let node = try ShareLinks.parse(link)
        XCTAssertEqual(node.name, "SG Reality")
        XCTAssertEqual(node.outbound["flow"], "xtls-rprx-vision")
        XCTAssertNil(node.outbound["transport"])
        XCTAssertEqual(node.outbound["tls"]?["reality"]?["public_key"], "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0")
        XCTAssertEqual(node.outbound["tls"]?["reality"]?["short_id"], "6ba85179e30d4fc2")
        XCTAssertEqual(node.outbound["tls"]?["utls"]?["fingerprint"], "safari")
        XCTAssertEqual(node.protocolLabel, "VLESS·Reality")
    }

    func testVLESSGrpcAndIPv6() throws {
        let node = try ShareLinks.parse("vless://uuid-1@[2001:db8::1]:8443?security=tls&type=grpc&serviceName=gun&sni=a.com#v6")
        XCTAssertEqual(node.outbound["server"], "2001:db8::1")
        XCTAssertEqual(node.outbound["server_port"], 8443)
        XCTAssertEqual(node.outbound["transport"]?["service_name"], "gun")
    }

    func testUnsupportedTransportThrows() {
        XCTAssertThrowsError(try ShareLinks.parse("vless://u@h.com:443?security=tls&type=xhttp#x"))
        XCTAssertThrowsError(try ShareLinks.parse("ssr://abc"))
        XCTAssertThrowsError(try ShareLinks.parse("vless://u@h.com:443?encryption=mlkem768x25519plus.native.0rtt.abc&security=tls#x"))
        XCTAssertNoThrow(try ShareLinks.parse("vless://u@h.com:443?encryption=none&security=tls#x"))
    }

    func testTrojan() throws {
        let node = try ShareLinks.parse("trojan://p%40ss@t.example.com:443?sni=t.example.com&allowInsecure=1&type=ws&path=%2Fws#Trojan")
        XCTAssertEqual(node.outbound["password"], "p@ss")
        XCTAssertEqual(node.outbound["tls"]?["insecure"], true)
        XCTAssertEqual(node.outbound["transport"]?["path"], "/ws")
    }

    func testHysteria2PortHopping() throws {
        let node = try ShareLinks.parse("hy2://letmein@hy.example.com:443,20000-30000/?sni=hy.example.com&obfs=salamander&obfs-password=xyz&insecure=1#HY2")
        XCTAssertEqual(node.outbound["type"], "hysteria2")
        XCTAssertEqual(node.outbound["server_port"], 443)
        XCTAssertEqual(node.outbound["server_ports"], ["20000:30000"])
        XCTAssertEqual(node.outbound["password"], "letmein")
        XCTAssertEqual(node.outbound["obfs"]?["type"], "salamander")
        XCTAssertEqual(node.outbound["tls"]?["alpn"], ["h3"])
    }

    func testTUIC() throws {
        let node = try ShareLinks.parse("tuic://uuid-x:pass-y@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com&udp_relay_mode=native#TUIC")
        XCTAssertEqual(node.outbound["uuid"], "uuid-x")
        XCTAssertEqual(node.outbound["password"], "pass-y")
        XCTAssertEqual(node.outbound["udp_relay_mode"], "native")
    }

    func testAnyTLS() throws {
        let node = try ShareLinks.parse("anytls://secret@a.example.com:443?sni=a.example.com#A")
        XCTAssertEqual(node.outbound["type"], "anytls")
        XCTAssertEqual(node.outbound["tls"]?["server_name"], "a.example.com")
    }

    func testBase64Variants() {
        XCTAssertEqual(Base64.decodeString("aGVsbG8"), "hello")
        XCTAssertEqual(Base64.decodeString("aGVs\nbG8="), "hello")
        XCTAssertEqual(Base64.decode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertNil(Base64.decodeString("not base64!"))
    }
}
