import AppKit
import Carbon
import KongPrismCore

// MARK: - 菜单栏网速

/// Reads sing-box's /traffic stream (one line per second) while the speed display is on.
@MainActor
final class TrafficMonitor {
    private var task: Task<Void, Never>?
    var onUpdate: ((Int64, Int64) -> Void)?

    var isRunning: Bool { task != nil }

    func start(api: ClashAPI) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.stream(api)
                // The stream ends when the core restarts; try again shortly.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func stream(_ api: ClashAPI) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(api.port)/traffic")!)
        request.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3600
        let session = Net.session(.direct, timeout: 3600)
        defer { session.invalidateAndCancel() }
        guard let (bytes, _) = try? await session.bytes(for: request) else { return }
        do {
            for try await line in bytes.lines {
                guard let json = JSONValue.parse(Data(line.utf8)) else { continue }
                let up = Int64(json["up"]?.intValue ?? 0)
                let down = Int64(json["down"]?.intValue ?? 0)
                onUpdate?(up, down)
            }
        } catch {}
    }
}
