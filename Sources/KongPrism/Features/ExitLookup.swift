import AppKit
import Carbon
import KongPrismCore

// MARK: - 出口信息

/// Looks up where traffic leaves the proxy. Asked only when the menu opens, at most every
/// five minutes or after a node / mode change, so it costs nothing in the background.
enum ExitLookup {
    /// ipinfo.io first: api.ip.sb sits behind Cloudflare and often answers proxy IPs with 403.
    static let services = ["https://ipinfo.io/json", "https://ipapi.co/json/", "https://api.ip.sb/geoip"]
    private static let preferredKey = "exitLookupService"

    /// Tries the service that worked last time first, and remembers which one answered.
    static func fetch(port: Int) async -> ExitInfo? {
        let preferred = UserDefaults.standard.string(forKey: preferredKey)
        let ordered = (preferred.map { [$0] } ?? []) + services.filter { $0 != preferred }
        for service in ordered {
            guard let url = URL(string: service),
                  let (data, _) = try? await Net.get(url, headers: ["User-Agent": "curl/8.7.1", "Accept": "application/json"],
                                                     routes: [.viaProxy(port: port)], timeout: 6),
                  let json = JSONValue.parse(data), let info = ExitInfo(json: json) else { continue }
            if service != preferred { UserDefaults.standard.set(service, forKey: preferredKey) }
            return info
        }
        return nil
    }
}
