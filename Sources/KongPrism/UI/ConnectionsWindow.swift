import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 连接

@MainActor
final class ConnectionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = ConnectionsModel()

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ConnectionsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "KongPrism · 连接"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 480))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Polling stops as soon as the window closes or is minimised.
    func windowWillClose(_ notification: Notification) { model.stop() }
    func windowDidMiniaturize(_ notification: Notification) { model.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { model.start() }
}

@MainActor
final class ConnectionsModel: ObservableObject {
    @Published var connections: [ClashAPI.Connection] = []
    @Published var totals: (up: Int64, down: Int64) = (0, 0)
    @Published var filter = ""
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let controller = AppController.shared
        guard controller.status.isRunning else { connections = []; return }
        Task {
            guard let result = try? await controller.api.connections() else { return }
            connections = result.connections.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            totals = (result.upload, result.download)
        }
    }

    func close(_ id: String) {
        Task {
            await AppController.shared.api.closeConnection(id)
            refresh()
        }
    }

    func closeAll() {
        Task {
            await AppController.shared.api.closeConnections()
            refresh()
        }
    }
}

struct ConnectionsView: View {
    @ObservedObject var model: ConnectionsModel

    private var shown: [ClashAPI.Connection] {
        let text = model.filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return model.connections }
        return model.connections.filter { "\($0.host) \($0.rule) \($0.chain) \($0.process)".lowercased().contains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("筛选：域名、规则、节点、程序", text: $model.filter).frame(maxWidth: 280)
                Spacer()
                Text("\(shown.count) 条 · 累计 ↑\(SubscriptionUsage.bytes(model.totals.up)) ↓\(SubscriptionUsage.bytes(model.totals.down))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("全部断开") { model.closeAll() }
            }
            Table(shown) {
                TableColumn("域名 / 地址") { Text($0.host).lineLimit(1).help($0.host) }.width(min: 180, ideal: 240)
                TableColumn("规则") { Text($0.rule).lineLimit(1).foregroundStyle(.secondary) }.width(min: 100, ideal: 150)
                TableColumn("线路") { Text($0.chain).lineLimit(1) }.width(min: 120, ideal: 180)
                TableColumn("程序") { Text($0.process).lineLimit(1).foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                TableColumn("↓ / ↑") { item in
                    Text("\(SubscriptionUsage.bytes(item.download)) / \(SubscriptionUsage.bytes(item.upload))")
                        .font(.system(.caption, design: .monospaced))
                }.width(min: 90, ideal: 120)
                TableColumn("") { item in
                    Button { model.close(item.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("断开")
                        .accessibilityLabel("断开这条连接")
                }.width(28)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 360)
    }
}
