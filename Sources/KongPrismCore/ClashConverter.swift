import Foundation

/// Converts Clash / Mihomo `proxies:` entries into sing-box outbounds.
public enum ClashConverter {
    public enum Failure: Error, Equatable {
        case unsupported(String)
        case missing(String)
    }

    public static func convert(_ proxy: [String: JSONValue]) throws -> ProxyNode {
        let proxy = Fields(proxy)
        guard let type = proxy.string("type")?.lowercased() else { throw Failure.missing("type") }
        guard let server = proxy.string("server") else { throw Failure.missing("server") }
        let port = proxy.int("port") ?? Int(proxy.string("ports")?.split(separator: ",").first?.split(separator: "-").first ?? "") ?? 443
        let name = proxy.string("name") ?? "\(server):\(port)"
        var outbound: [String: JSONValue] = ["server": .string(server), "server_port": .int(port)]

        switch type {
        case "ss", "shadowsocks":
            outbound["type"] = "shadowsocks"
            outbound["method"] = .string(try proxy.require("cipher"))
            outbound["password"] = .string(try proxy.require("password"))
            if let plugin = proxy.string("plugin") {
                let options = proxy.object("plugin-opts")
                switch plugin {
                case "obfs", "simple-obfs", "obfs-local":
                    var parts = ["obfs=\(options.string("mode") ?? "http")"]
                    if let host = options.string("host") { parts.append("obfs-host=\(host)") }
                    outbound["plugin"] = "obfs-local"
                    outbound["plugin_opts"] = .string(parts.joined(separator: ";"))
                case "v2ray-plugin":
                    var parts: [String] = []
                    if options.bool("tls") == true { parts.append("tls") }
                    if let host = options.string("host") { parts.append("host=\(host)") }
                    if let path = options.string("path") { parts.append("path=\(path)") }
                    if options.bool("mux") == true { parts.append("mux=1") }
                    outbound["plugin"] = "v2ray-plugin"
                    outbound["plugin_opts"] = .string(parts.joined(separator: ";"))
                default:
                    throw Failure.unsupported("ss plugin \(plugin)")
                }
            }
            if proxy.bool("udp-over-tcp") == true { outbound["udp_over_tcp"] = true }

        case "vmess":
            outbound["type"] = "vmess"
            outbound["uuid"] = .string(try proxy.require("uuid"))
            outbound["alter_id"] = .int(proxy.int("alterId") ?? 0)
            outbound["security"] = .string(proxy.string("cipher") ?? "auto")
            if proxy.bool("global-padding") == true { outbound["global_padding"] = true }
            if proxy.bool("authenticated-length") == true { outbound["authenticated_length"] = true }
            if let transport = try transport(proxy) { outbound["transport"] = .object(transport) }
            if proxy.bool("tls") == true { outbound["tls"] = .object(tls(proxy, sniKey: "servername")) }
            if let encoding = proxy.string("packet-encoding") { outbound["packet_encoding"] = .string(encoding) }

        case "vless":
            outbound["type"] = "vless"
            outbound["uuid"] = .string(try proxy.require("uuid"))
            if let flow = proxy.string("flow") { outbound["flow"] = .string(flow) }
            outbound["packet_encoding"] = .string(proxy.string("packet-encoding") ?? "xudp")
            if let transport = try transport(proxy) { outbound["transport"] = .object(transport) }
            if proxy.bool("tls") == true || !proxy.object("reality-opts").isEmpty {
                outbound["tls"] = .object(tls(proxy, sniKey: "servername"))
            }

        case "trojan":
            outbound["type"] = "trojan"
            outbound["password"] = .string(try proxy.require("password"))
            if let transport = try transport(proxy) { outbound["transport"] = .object(transport) }
            outbound["tls"] = .object(tls(proxy, sniKey: "sni"))

        case "hysteria2", "hy2":
            outbound["type"] = "hysteria2"
            outbound["password"] = .string(proxy.string("password") ?? proxy.string("auth") ?? "")
            if let ports = proxy.string("ports") {
                let ranges = ports.split(separator: ",").map { part -> String in
                    part.contains("-") ? part.replacingOccurrences(of: "-", with: ":") : "\(part):\(part)"
                }
                outbound["server_ports"] = .array(ranges.map(JSONValue.string))
            }
            if let up = mbps(proxy.string("up")) { outbound["up_mbps"] = .int(up) }
            if let down = mbps(proxy.string("down")) { outbound["down_mbps"] = .int(down) }
            if let obfs = proxy.string("obfs"), obfs != "none" {
                outbound["obfs"] = ["type": .string(obfs), "password": .string(proxy.string("obfs-password") ?? "")]
            }
            outbound["tls"] = .object(tls(proxy, sniKey: "sni", defaultALPN: ["h3"]))

        case "hysteria":
            outbound["type"] = "hysteria"
            if let auth = proxy.string("auth-str") ?? proxy.string("auth_str") { outbound["auth_str"] = .string(auth) }
            outbound["up_mbps"] = .int(mbps(proxy.string("up")) ?? 50)
            outbound["down_mbps"] = .int(mbps(proxy.string("down")) ?? 100)
            if let obfs = proxy.string("obfs") { outbound["obfs"] = .string(obfs) }
            outbound["tls"] = .object(tls(proxy, sniKey: "sni", defaultALPN: ["hysteria"]))

        case "tuic":
            outbound["type"] = "tuic"
            outbound["uuid"] = .string(try proxy.require("uuid"))
            outbound["password"] = .string(proxy.string("password") ?? "")
            outbound["congestion_control"] = .string(proxy.string("congestion-controller") ?? "bbr")
            if let mode = proxy.string("udp-relay-mode") { outbound["udp_relay_mode"] = .string(mode) }
            if proxy.bool("reduce-rtt") == true { outbound["zero_rtt_handshake"] = true }
            var tlsObject = tls(proxy, sniKey: "sni", defaultALPN: ["h3"])
            if proxy.bool("disable-sni") == true { tlsObject["disable_sni"] = true }
            outbound["tls"] = .object(tlsObject)

        case "anytls":
            outbound["type"] = "anytls"
            outbound["password"] = .string(try proxy.require("password"))
            outbound["tls"] = .object(tls(proxy, sniKey: "sni"))

        case "socks5", "socks":
            outbound["type"] = "socks"
            if let user = proxy.string("username") { outbound["username"] = .string(user) }
            if let password = proxy.string("password") { outbound["password"] = .string(password) }
            if proxy.bool("tls") == true { throw Failure.unsupported("socks5 over tls") }

        case "http":
            outbound["type"] = "http"
            if let user = proxy.string("username") { outbound["username"] = .string(user) }
            if let password = proxy.string("password") { outbound["password"] = .string(password) }
            if proxy.bool("tls") == true { outbound["tls"] = .object(tls(proxy, sniKey: "sni")) }

        default:
            throw Failure.unsupported(type)
        }
        return ProxyNode(name: name, outbound: outbound)
    }

    // MARK: Pieces

    static func tls(_ proxy: Fields, sniKey: String, defaultALPN: [String] = []) -> [String: JSONValue] {
        var tls: [String: JSONValue] = ["enabled": true]
        if let name = proxy.string(sniKey) ?? proxy.string("servername") ?? proxy.string("sni") { tls["server_name"] = .string(name) }
        if proxy.bool("skip-cert-verify") == true { tls["insecure"] = true }
        let alpn = proxy.strings("alpn")
        if !alpn.isEmpty {
            tls["alpn"] = .array(alpn.map(JSONValue.string))
        } else if !defaultALPN.isEmpty {
            tls["alpn"] = .array(defaultALPN.map(JSONValue.string))
        }
        if let fingerprint = proxy.string("client-fingerprint"), fingerprint != "none" {
            tls["utls"] = ["enabled": true, "fingerprint": .string(fingerprint == "random" ? "randomized" : fingerprint)]
        }
        let reality = proxy.object("reality-opts")
        if let key = reality.string("public-key") {
            tls["reality"] = ["enabled": true, "public_key": .string(key), "short_id": .string(reality.string("short-id") ?? "")]
            if tls["utls"] == nil { tls["utls"] = ["enabled": true, "fingerprint": "chrome"] }
        }
        return tls
    }

    static func transport(_ proxy: Fields) throws -> [String: JSONValue]? {
        let network = proxy.string("network") ?? "tcp"
        switch network {
        case "ws":
            let options = proxy.object("ws-opts")
            let headers = options.object("headers")
            var path = options.string("path") ?? proxy.string("ws-path") ?? "/"
            var transport: [String: JSONValue] = ["type": "ws"]
            if let range = path.range(of: "?ed=") {
                if let early = Int(path[range.upperBound...].prefix { $0.isNumber }) {
                    transport["max_early_data"] = .int(early)
                    transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
                }
                path = String(path[..<range.lowerBound])
            }
            if let early = options.int("max-early-data") {
                transport["max_early_data"] = .int(early)
                transport["early_data_header_name"] = .string(options.string("early-data-header-name") ?? "Sec-WebSocket-Protocol")
            }
            transport["path"] = .string(path)
            if let host = headers.string("Host") ?? headers.string("host") { transport["headers"] = ["Host": .string(host)] }
            if options.bool("v2ray-http-upgrade") == true {
                var upgrade: [String: JSONValue] = ["type": "httpupgrade", "path": .string(path)]
                if let host = headers.string("Host") ?? headers.string("host") { upgrade["host"] = .string(host) }
                return upgrade
            }
            return transport
        case "grpc":
            var transport: [String: JSONValue] = ["type": "grpc"]
            if let name = proxy.object("grpc-opts").string("grpc-service-name") { transport["service_name"] = .string(name) }
            return transport
        case "h2":
            let options = proxy.object("h2-opts")
            var transport: [String: JSONValue] = ["type": "http"]
            let hosts = options.strings("host")
            if !hosts.isEmpty { transport["host"] = .array(hosts.map(JSONValue.string)) }
            if let path = options.string("path") { transport["path"] = .string(path) }
            return transport
        case "http":
            let options = proxy.object("http-opts")
            var transport: [String: JSONValue] = ["type": "http", "method": .string(options.string("method") ?? "GET")]
            if let path = options.strings("path").first { transport["path"] = .string(path) }
            let hosts = options.object("headers").strings("Host")
            if !hosts.isEmpty { transport["host"] = .array(hosts.map(JSONValue.string)) }
            return transport
        case "httpupgrade":
            let options = proxy.object("http-upgrade-opts").isEmpty ? proxy.object("ws-opts") : proxy.object("http-upgrade-opts")
            var transport: [String: JSONValue] = ["type": "httpupgrade", "path": .string(options.string("path") ?? "/")]
            if let host = options.object("headers").string("Host") ?? options.string("host") { transport["host"] = .string(host) }
            return transport
        case "tcp", "":
            return nil
        default:
            throw Failure.unsupported("network \(network)")
        }
    }

    /// "100", "100 Mbps", "20 MB/s"-ish values → Mbps.
    static func mbps(_ text: String?) -> Int? {
        guard let text = text?.lowercased() else { return nil }
        let digits = text.prefix { $0.isNumber }
        guard let value = Int(digits) else { return nil }
        if text.contains("gbps") || text.contains("gb") && !text.contains("mb") { return value * 1000 }
        if text.contains("kbps") { return max(1, value / 1000) }
        return value
    }

    /// Typed access to a Clash proxy mapping.
    struct Fields {
        let values: [String: JSONValue]
        init(_ values: [String: JSONValue]) { self.values = values }

        var isEmpty: Bool { values.isEmpty }

        func string(_ key: String) -> String? {
            guard let value = values[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        func int(_ key: String) -> Int? { values[key]?.intValue }
        func bool(_ key: String) -> Bool? { values[key]?.boolValue }
        func object(_ key: String) -> Fields { Fields(values[key]?.objectValue ?? [:]) }
        func strings(_ key: String) -> [String] {
            if let array = values[key]?.arrayValue { return array.compactMap(\.stringValue) }
            if let single = string(key) { return single.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            return []
        }
        func require(_ key: String) throws -> String {
            guard let value = string(key) else { throw Failure.missing(key) }
            return value
        }
    }
}
