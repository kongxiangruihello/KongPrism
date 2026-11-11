import AppKit
import CoreWLAN
import Network
import UserNotifications
import KongPrismCore

// MARK: - 系统通知

enum Notifier {
    /// Sends a notification once per `key` per day (asks for permission the first time).
    static func notifyOnce(key: String, title: String, body: String, settings: inout AppSettings) {
        if let last = settings.notifiedWarnings[key], Date().timeIntervalSince(last) < 24 * 3600 { return }
        settings.notifiedWarnings[key] = Date()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }
}
