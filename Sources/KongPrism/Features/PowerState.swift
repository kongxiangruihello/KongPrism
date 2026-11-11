import AppKit
import CoreImage
import IOKit.ps
import KongPrismCore

// MARK: - 电源

/// Battery and Low Power Mode, followed through notifications (no polling).
@MainActor
final class PowerState {
    static let shared = PowerState()
    private(set) var onBattery = false
    private(set) var lowPower = false
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in PowerState.shared.refresh() }
        }
        if let loop = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerState.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            source = loop
        }
    }

    /// True when the Mac should not spend energy on extras (battery or Low Power Mode).
    var shouldSave: Bool { onBattery || lowPower }

    private func refresh() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type: String? = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        let battery = type == kIOPSBatteryPowerValue
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard battery != onBattery || low != lowPower else { return }
        onBattery = battery
        lowPower = low
        onChange?()
    }

    /// Seconds since the last keyboard or mouse event.
    static var idleSeconds: TimeInterval {
        [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
