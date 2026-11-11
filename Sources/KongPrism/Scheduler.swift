import Foundation

/// Periodic work through NSBackgroundActivityScheduler: macOS picks the moment
/// (batched with other wake-ups, postponed on battery saver or heavy load), so
/// KongPrism keeps no timers of its own.
@MainActor
final class Scheduler {
    private weak var controller: AppController?
    private var activities: [NSBackgroundActivityScheduler] = []

    init(controller: AppController) { self.controller = controller }

    func start() {
        guard let controller else { return }
        let hours = max(1, controller.settings.subscriptionIntervalHours)
        schedule("subscriptions", every: TimeInterval(hours) * 3600) { controller in
            await controller.updateAllProfiles()
        }
        schedule("rules", every: 7 * 24 * 3600) { controller in
            guard controller.settings.autoUpdateRules else { return }
            await controller.updateRules(userInitiated: false)
        }
        // Only does anything while a hand-picked node is selected (groups test themselves).
        schedule("node-health", every: 15 * 60) { controller in
            await controller.checkSelectedNode()
            await controller.checkFailover()
        }
        schedule("updates", every: 24 * 3600) { controller in
            if controller.settings.autoCheckAppUpdates { await controller.checkAppUpdate(userInitiated: false) }
            if controller.settings.autoCheckCoreUpdates { await controller.checkCoreUpdate(userInitiated: false) }
        }
    }

    /// Re-creates the schedules (after the subscription interval changes).
    func restart() {
        activities.forEach { $0.invalidate() }
        activities.removeAll()
        start()
    }

    private func schedule(_ name: String, every interval: TimeInterval, _ work: @escaping @MainActor (AppController) async -> Void) {
        let activity = NSBackgroundActivityScheduler(identifier: "com.kongxiangrui.KongPrism.\(name)")
        activity.repeats = true
        activity.interval = interval
        activity.tolerance = interval / 4
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let controller = self?.controller else { completion(.finished); return }
                if activity.shouldDefer { completion(.deferred); return }
                await work(controller)
                completion(.finished)
            }
        }
        activities.append(activity)
    }
}
