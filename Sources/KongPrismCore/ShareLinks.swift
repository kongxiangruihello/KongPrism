import Foundation

/// Parses node share links (ss, vmess, vless, trojan, hysteria2/hy2, tuic, anytls, socks)
/// into sing-box outbounds.
public enum ShareLinks {
    public enum Failure: Error, Equatable {
        case unsupportedScheme(String)
        case unsupportedTransport(String)
        case malformed(String)
    }

    /// Parses every line that looks like a link; returns the nodes and how many lines were skipped.
    public static func parseList(_ text: String) -> (nodes: [ProxyNode], skipped: Int) {
        var nodes: [ProxyNode] = []
        var skipped = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("://") else { continue }
            if let node = try? parse(line) { nodes.append(node) } else { skipped += 1 }
        }
        return (nodes, skipped)
    }

    public static func parse(_ link: String) throws -> ProxyNode {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = link.range(of: "://") else { throw Failure.malformed(link) }
        let scheme = link[..<separator.lowerBound].lowercased()
        switch scheme {
        case "ss": return try shadowsocks(link)
        case "vmess": return try vmess(link)
        case "vless": return try vless(link)
        case "trojan": return try trojan(link)
        case "hysteria2", "hy2": return try hysteria2(link)
        case "tuic": return try tuic(link)
        case "anytls": return try anytls(link)
        case "socks", "socks5": return try socks(link)
        default: throw Failure.unsupportedScheme(scheme)
        }
    }

    // MARK: Protocols

    static func shadowsocks(_ link: String) throws -> ProxyNode {
        let body = String(link.dropFirst("ss://".count))
        let beforeFragment = body.components(separatedBy: "#")[0]
        let fragment = body.contains("#") ? String(body[body.index(after: body.firstIndex(of: "#")!)...]) : nil
        var url: LinkURL
        if !beforeFragment.contains("@") {
            // Legacy form: ss://BASE64(method:password@host:port)#name
            let encoded = beforeFragment.components(separatedBy: "?")[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let decoded = Base64.decodeString(encoded), decoded.contains("@") else { throw Failure.malformed(link) }
            url = try LinkURL("ss://" + decoded + (fragment.map { "#" + $0 } ?? ""))
        } else {
            url = try LinkURL(link)
        }
        guard let userinfo = url.userinfo else { throw Failure.malformed(link) }
        // SIP002: userinfo is BASE64URL(method:password), or percent-encoded for 2022 ciphers.
        // Base64 never contains ":", so a colon means the plain form.
        var credentials = userinfo.removingPercentEncoding ?? userinfo
        if !credentials.contains(":") {
            guard let decoded = Base64.decodeString(userinfo), decoded.contains(":") else { throw Failure.malformed(link) }
            credentials = decoded
        }
        guard let colon = credentials.firstIndex(of: ":") else { throw Failure.malformed(link) }
        let method = String(credentials[..<colon])
        let password = String(credentials[credentials.index(after: colon)...])
        var outbound = base("shadowsocks", url)
        outbound["method"] = .string(method)
        outbound["password"] = .string(password)
        if let plugin = url.query["plugin"], !plugin.isEmpty {
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            var name = parts[0]
            if name == "simple-obfs" || name == "obfs" { name = "obfs-local" }
            guard name == "obfs-local" || name == "v2ray-plugin" else { throw Failure.unsupportedTransport(name) }
            outbound["plugin"] = .string(name)
            if parts.count > 1 { outbound["plugin_opts"] = .string(parts[1]) }
        }
        if url.query["uot"].flatMap(Self.flag) == true { outbound["udp_over_tcp"] = true }
        return ProxyNode(name: url.name, outbound: outbound)
    }

    static func vmess(_ link: String) throws -> ProxyNode {
        let body = String(link.dropFirst("vmess://".count)).components(separatedBy: "#")[0]
        guard let decoded = Base64.decode(body), let json = JSONValue.parse(decoded), let object = json.objectValue else {
            // Some providers use the vless-style form for vmess.
            return try vlessStyle(link, type: "vmess")
        }
        func value(_ key: String) -> String? {
            guard let string = object[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
            return string
        }
        guard let server = value("add"), let port = object["port"]?.intValue, let uuid = value("id") else {
            throw Failure.malformed(link)
        }
        var outbound: [String: JSONValue] = ["type": "vmess", "server": .string(server), "server_port": .int(port), "uuid": .string(uuid)]
        outbound["security"] = .string(value("scy") ?? "auto")
        outbound["alter_id"] = .int(object["aid"]?.intValue ?? 0)
        let network = value("net") ?? "tcp"
        if let transport = try Transport.make(network: network, host: value("host"), path: value("path"),
                                              serviceName: value("path"), headerType: value("type")) {
            outbound["transport"] = .object(transport)
        }
        if let security = value("tls"), security == "tls" {
            outbound["tls"] = .object(TLS.make(serverName: value("sni") ?? value("host"),
                                               insecure: object["allowInsecure"]?.boolValue ?? false,
                                               alpn: value("alpn"), fingerprint: value("fp")))
        }
        return ProxyNode(name: value("ps") ?? "\(server):\(port)", outbound: outbound)
    }

    static func vless(_ link: String) throws -> ProxyNode { try vlessStyle(link, type: "vless") }

    /// vless:// (and the URL form of vmess://): uuid@host:port?security=…&type=…#name
    static func vlessStyle(_ link: String, type: String) throws -> ProxyNode {
        let url = try LinkURL(link)
        guard let uuid = url.userinfo?.removingPercentEncoding, !uuid.isEmpty else { throw Failure.malformed(link) }
        if type == "vless", let encryption = url.query["encryption"], !encryption.isEmpty, encryption != "none" {
            throw Failure.unsupportedTransport("VLESS encryption")
        }
        var outbound = base(type, url)
        outbound["uuid"] = .string(uuid)
        if type == "vless", let flow = url.query["flow"], !flow.isEmpty { outbound["flow"] = .string(flow) }
        if type == "vmess" {
            outbound["security"] = .string(url.query["encryption"] ?? "auto")
            outbound["alter_id"] = 0
        }
        if let transport = try Transport.make(network: url.query["type"] ?? "tcp", host: url.query["host"], path: url.query["path"],
                                              serviceName: url.query["serviceName"] ?? url.query["service_name"],
                                              headerType: url.query["headerType"]) {
            outbound["transport"] = .object(transport)
        }
        let security = url.query["security"] ?? "none"
        if security == "tls" || security == "reality" || security == "xtls" {
            var tls = TLS.make(serverName: url.query["sni"] ?? url.query["peer"] ?? url.query["host"],
                               insecure: flag(url.query["allowInsecure"] ?? url.query["insecure"] ?? "0") ?? false,
                               alpn: url.query["alpn"], fingerprint: url.query["fp"])
            if security == "reality" {
                guard let publicKey = url.query["pbk"], !publicKey.isEmpty else { throw Failure.malformed(link) }
                tls["reality"] = ["enabled": true, "public_key": .string(publicKey), "short_id": .string(url.query["sid"] ?? "")]
                if tls["utls"] == nil { tls["utls"] = ["enabled": true, "fingerprint": "chrome"] }
            }
            outbound["tls"] = .object(tls)
        }
        if type == "vless" {
            // Xray servers expect XUDP for UDP over VLESS (also the Clash.Meta default).
            outbound["packet_encoding"] = .string(url.query["packetEncoding"] == "packetaddr" ? "packetaddr" : "xudp")
        }
        return ProxyNode(name: url.name, outbound: outbound)
    }

    static func trojan(_ link: String) throws -> ProxyNode {
        let url = try LinkURL(link)
        guard let password = url.userinfo?.removingPercentEncoding, !password.isEmpty else { throw Failure.malformed(link) }
        var outbound = base("trojan", url)
        outbound["password"] = .string(password)
        if let transport = try Transport.make(network: url.query["type"] ?? "tcp", host: url.query["host"], path: url.query["path"],
                                              serviceName: url.query["serviceName"], headerType: nil) {
            outbound["transport"] = .object(transport)
        }
        if url.query["security"] != "none" {
            var tls = TLS.make(serverName: url.query["sni"] ?? url.query["peer"] ?? url.query["host"],
                               insecure: flag(url.query["allowInsecure"] ?? url.query["insecure"] ?? "0") ?? false,
                               alpn: url.query["alpn"], fingerprint: url.query["fp"])
            if url.query["security"] == "reality", let publicKey = url.query["pbk"] {
                tls["reality"] = ["enabled": true, "public_key": .string(publicKey), "short_id": .string(url.query["sid"] ?? "")]
                if tls["utls"] == nil { tls["utls"] = ["enabled": true, "fingerprint": "chrome"] }
            }
            outbound["tls"] = .object(tls)
        }
        return ProxyNode(name: url.name, outbound: outbound)
    }

    static func hysteria2(_ link: String) throws -> ProxyNode {
        var url = try LinkURL(link)
        // Port hopping: host:443,20000-30000 or ?mport=20000-30000
        var hopping: [String] = []
        if url.portRaw.contains(",") || url.portRaw.contains("-") {
            let parts = url.portRaw.split(separator: ",").map(String.init)
            for part in parts where part.contains("-") { hopping.append(part.replacingOccurrences(of: "-", with: ":")) }
            url.port = parts.compactMap { Int($0) }.first ?? Int(parts.first?.split(separator: "-").first ?? "") ?? 443
        }
        if let mport = url.query["mport"] {
            for part in mport.split(separator: ",") {
                hopping.append(part.contains("-") ? part.replacingOccurrences(of: "-", with: ":") : "\(part):\(part)")
            }
        }
        var outbound = base("hysteria2", url)
        if !hopping.isEmpty { outbound["server_ports"] = .array(hopping.map(JSONValue.string)) }
        if let password = url.userinfo?.removingPercentEncoding, !password.isEmpty {
            outbound["password"] = .string(password)
        } else if let auth = url.query["auth"] {
            outbound["password"] = .string(auth)
        }
        if let obfs = url.query["obfs"], obfs != "none", !obfs.isEmpty {
            outbound["obfs"] = ["type": .string(obfs), "password": .string(url.query["obfs-password"] ?? url.query["obfs_password"] ?? "")]
        }
        if let up = url.query["upmbps"].flatMap(Int.init) { outbound["up_mbps"] = .int(up) }
        if let down = url.query["downmbps"].flatMap(Int.init) { outbound["down_mbps"] = .int(down) }
        outbound["tls"] = .object(TLS.make(serverName: url.query["sni"] ?? url.query["peer"],
                                           insecure: flag(url.query["insecure"] ?? url.query["allowInsecure"] ?? "0") ?? false,
                                           alpn: url.query["alpn"] ?? "h3", fingerprint: nil))
        return ProxyNode(name: url.name, outbound: outbound)
    }

    static func tuic(_ link: String) throws -> ProxyNode {
        let url = try LinkURL(link)
        guard let userinfo = url.userinfo, let colon = userinfo.firstIndex(of: ":") else { throw Failure.malformed(link) }
        var outbound = base("tuic", url)
        outbound["uuid"] = .string(String(userinfo[..<colon]).removingPercentEncoding ?? "")
        outbound["password"] = .string(String(userinfo[userinfo.index(after: colon)...]).removingPercentEncoding ?? "")
        outbound["congestion_control"] = .string(url.query["congestion_control"] ?? url.query["congestion-control"] ?? "bbr")
        if let mode = url.query["udp_relay_mode"] ?? url.query["udp-relay-mode"] { outbound["udp_relay_mode"] = .string(mode) }
        if flag(url.query["reduce_rtt"] ?? url.query["zero_rtt_handshake"] ?? "0") == true { outbound["zero_rtt_handshake"] = true }
        var tls = TLS.make(serverName: url.query["sni"],
                           insecure: flag(url.query["allow_insecure"] ?? url.query["insecure"] ?? url.query["allowInsecure"] ?? "0") ?? false,
                           alpn: url.query["alpn"] ?? "h3", fingerprint: nil)
        if flag(url.query["disable_sni"] ?? "0") == true { tls["disable_sni"] = true }
        outbound["tls"] = .object(tls)
        return ProxyNode(name: url.name, outbound: outbound)
    }

    static func anytls(_ link: String) throws -> ProxyNode {
        let url = try LinkURL(link)
        guard let password = url.userinfo?.removingPercentEncoding, !password.isEmpty else { throw Failure.malformed(link) }
        var outbound = base("anytls", url)
        outbound["password"] = .string(password)
        outbound["tls"] = .object(TLS.make(serverName: url.query["sni"] ?? url.query["peer"],
                                           insecure: flag(url.query["insecure"] ?? url.query["allowInsecure"] ?? "0") ?? false,
                                           alpn: url.query["alpn"], fingerprint: url.query["fp"]))
        return ProxyNode(name: url.name, outbound: outbound)
    }

    static func socks(_ link: String) throws -> ProxyNode {
        let url = try LinkURL(link)
        var outbound = base("socks", url)
        if var userinfo = url.userinfo {
            if !userinfo.contains(":"), let decoded = Base64.decodeString(userinfo) { userinfo = decoded }
            let parts = userinfo.split(separator: ":", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            outbound["username"] = .string(parts[0])
            if parts.count > 1 { outbound["password"] = .string(parts[1]) }
        }
        return ProxyNode(name: url.name, outbound: outbound)
    }

    // MARK: Helpers

    static func base(_ type: String, _ url: LinkURL) -> [String: JSONValue] {
        ["type": .string(type), "server": .string(url.host), "server_port": .int(url.port)]
    }

    static func flag(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no", "": return false
        default: return nil
        }
    }
}

/// sing-box TLS objects.
enum TLS {
    static func make(serverName: String?, insecure: Bool, alpn: String?, fingerprint: String?) -> [String: JSONValue] {
        var tls: [String: JSONValue] = ["enabled": true]
        if let serverName, !serverName.isEmpty { tls["server_name"] = .string(serverName) }
        if insecure { tls["insecure"] = true }
        if let alpn, !alpn.isEmpty {
            tls["alpn"] = .array(alpn.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        }
        if let fingerprint, !fingerprint.isEmpty, fingerprint != "none" {
            tls["utls"] = ["enabled": true, "fingerprint": .string(fingerprint)]
        }
        return tls
    }
}

/// sing-box V2Ray transports.
enum Transport {
    /// nil for plain TCP. Throws for transports sing-box does not have (xhttp, kcp, …).
    static func make(network: String, host: String?, path: String?, serviceName: String?, headerType: String?) throws -> [String: JSONValue]? {
        let host = host?.trimmingCharacters(in: .whitespaces).nonEmpty
        switch network.lowercased() {
        case "", "tcp", "raw", "none":
            if headerType == "http" {
                var transport: [String: JSONValue] = ["type": "http", "method": "GET"]
                if let host { transport["host"] = .array(host.split(separator: ",").map { .string(String($0)) }) }
                if let path = path?.nonEmpty { transport["path"] = .string(path) }
                return transport
            }
            return nil
        case "ws", "websocket":
            var transport: [String: JSONValue] = ["type": "ws"]
            var path = path?.nonEmpty ?? "/"
            // "/path?ed=2048" means early data, which sing-box sets with separate fields.
            if let range = path.range(of: "?ed=") ?? path.range(of: "&ed=") {
                let value = path[range.upperBound...].prefix { $0.isNumber }
                if let early = Int(value) {
                    transport["max_early_data"] = .int(early)
                    transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
                }
                path = String(path[..<range.lowerBound])
            }
            transport["path"] = .string(path)
            if let host { transport["headers"] = ["Host": .string(host)] }
            return transport
        case "grpc":
            var transport: [String: JSONValue] = ["type": "grpc"]
            if let name = serviceName?.nonEmpty { transport["service_name"] = .string(name) }
            return transport
        case "h2", "http":
            var transport: [String: JSONValue] = ["type": "http"]
            if let host { transport["host"] = .array(host.split(separator: ",").map { .string(String($0)) }) }
            if let path = path?.nonEmpty { transport["path"] = .string(path) }
            return transport
        case "httpupgrade":
            var transport: [String: JSONValue] = ["type": "httpupgrade"]
            if let host { transport["host"] = .string(host) }
            transport["path"] = .string(path?.nonEmpty ?? "/")
            return transport
        case "quic":
            return ["type": "quic"]
        default:
            throw ShareLinks.Failure.unsupportedTransport(network)
        }
    }
}

/// A forgiving URL parser for share links, which often are not valid URLs
/// (unescaped names, IPv6 hosts, port lists).
struct LinkURL {
    var scheme: String
    var userinfo: String?
    var host: String
    var port: Int
    var portRaw: String
    var authorityRaw: String
    var query: [String: String]
    var fragment: String?

    var name: String {
        if let fragment, let decoded = fragment.removingPercentEncoding?.trimmingCharacters(in: .whitespaces), !decoded.isEmpty {
            return decoded
        }
        return "\(host):\(port)"
    }

    init(_ link: String) throws {
        guard let separator = link.range(of: "://") else { throw ShareLinks.Failure.malformed(link) }
        scheme = link[..<separator.lowerBound].lowercased()
        var rest = String(link[separator.upperBound...])
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        var queryString = ""
        if let mark = rest.firstIndex(of: "?") {
            queryString = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
        }
        // Drop a path ("host:port/?plugin=…"); userinfo may itself contain "/" (standard base64).
        let hostStart = rest.lastIndex(of: "@").map { rest.index(after: $0) } ?? rest.startIndex
        if let slash = rest[hostStart...].firstIndex(of: "/") { rest = String(rest[..<slash]) }
        authorityRaw = rest
        var hostPort = rest
        if let at = rest.lastIndex(of: "@") {
            userinfo = String(rest[..<at])
            hostPort = String(rest[rest.index(after: at)...])
        }
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            portRaw = after.hasPrefix(":") ? String(after.dropFirst()) : ""
        } else if let colon = hostPort.firstIndex(of: ":") {
            host = String(hostPort[..<colon])
            portRaw = String(hostPort[hostPort.index(after: colon)...])
        } else {
            host = hostPort
            portRaw = ""
        }
        host = host.removingPercentEncoding ?? host
        port = Int(portRaw) ?? 443
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: "%20").removingPercentEncoding ?? parts[1]) : ""
            query[key] = value
        }
        self.query = query
        if userinfo != nil, host.isEmpty { throw ShareLinks.Failure.malformed(link) }
    }
}

public enum Base64 {
    /// Decodes standard or URL-safe base64, with or without padding or line breaks.
    public static func decode(_ text: String) -> Data? {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }) else { return nil }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }

    public static func decodeString(_ text: String) -> String? {
        guard let data = decode(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
