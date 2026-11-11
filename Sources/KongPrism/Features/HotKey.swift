import AppKit
import Carbon
import KongPrismCore

// MARK: - 全局快捷键

/// ⌃⌥P toggles the proxy from any app (Carbon hot keys need no Accessibility permission).
@MainActor
final class HotKey {
    static let shared = HotKey()
    static let display = "⌃⌥P"

    private var reference: EventHotKeyRef?
    private var handlerInstalled = false
    private var action: (() -> Void)?

    /// Returns false when another app already uses the combination.
    @discardableResult
    func register(_ action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4B505253), id: 1) // 'KPRS'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        reference = ref
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    fileprivate func fire() { action?() }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in HotKey.shared.fire() }
            return noErr
        }, 1, &type, nil, nil)
    }
}
