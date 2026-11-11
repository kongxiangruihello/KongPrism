import AppKit
import CoreImage
import IOKit.ps
import KongPrismCore

// MARK: - 流量统计

/// Daily and per-subscription traffic. sing-box reports totals since it started; KongPrism samples
/// them only when the menu opens, once an hour (system-scheduled), and before the core stops.
struct TrafficStats: Codable, Equatable {
    struct Usage: Codable, Equatable {
        var up: Int64 = 0
        var down: Int64 = 0
        var total: Int64 { up + down }
    }

    var days: [String: Usage] = [:]
    var profiles: [String: Usage] = [:]
    var lastUp: Int64 = 0
    var lastDown: Int64 = 0

    static var url: URL { Paths.support.appendingPathComponent("traffic.json") }
    static func load() -> TrafficStats { Store.load(TrafficStats.self, from: url) ?? TrafficStats() }
    func save() { Store.save(self, to: Self.url) }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Adds what the core counted since the last sample. A smaller total means the core restarted.
    mutating func record(totalUp: Int64, totalDown: Int64, profile: String, on date: Date = Date()) {
        let up = totalUp >= lastUp ? totalUp - lastUp : totalUp
        let down = totalDown >= lastDown ? totalDown - lastDown : totalDown
        lastUp = totalUp
        lastDown = totalDown
        guard up > 0 || down > 0 else { return }
        let day = Self.dayFormatter.string(from: date)
        days[day, default: Usage()].up += up
        days[day, default: Usage()].down += down
        profiles[profile, default: Usage()].up += up
        profiles[profile, default: Usage()].down += down
        // Keep 120 days.
        let cutoff = Self.dayFormatter.string(from: date.addingTimeInterval(-120 * 86_400))
        days = days.filter { $0.key >= cutoff }
    }

    /// The core restarted: its counters start from zero again.
    mutating func coreRestarted() {
        lastUp = 0
        lastDown = 0
    }

    func usage(lastDays count: Int, until date: Date = Date()) -> [(day: Date, usage: Usage)] {
        (0..<count).reversed().map { offset in
            let day = Calendar.current.startOfDay(for: date.addingTimeInterval(-Double(offset) * 86_400))
            return (day, days[Self.dayFormatter.string(from: day)] ?? Usage())
        }
    }

    func total(since start: Date) -> Usage {
        let from = Self.dayFormatter.string(from: start)
        return days.filter { $0.key >= from }.values.reduce(Usage()) { Usage(up: $0.up + $1.up, down: $0.down + $1.down) }
    }
}
