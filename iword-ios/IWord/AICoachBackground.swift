import BackgroundTasks
import Foundation

/// iOS decides when (or whether) to grant time. Foreground/manual execution remains available.
@MainActor enum AICoachBackground {
    static let identifier = "biz.powerunion.iword.ai-coach"
    private static var registered = false
    private static var execute: (() async -> Bool)?
    static func register(execute: @escaping () async -> Bool, cancel: @escaping () -> Void) {
        self.execute = execute
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let operation = Task { @MainActor in
                let success = await Self.execute?() ?? false
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = {
                operation.cancel()
                Task { @MainActor in cancel() }
            }
        }
    }
    nonisolated static func cutoff(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: now)!
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    }
    nonisolated static func nextDate(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(byAdding: .day, value: 1, to: cutoff(now: now))!
    }
    /// Replace only our pending request; never cancel listening or study reminders.
    static func schedule(enabled: Bool, now: Date = Date()) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard enabled else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextDate(now: now)
        try? BGTaskScheduler.shared.submit(request)
    }
}
