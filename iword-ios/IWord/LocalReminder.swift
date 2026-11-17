import Foundation
import UserNotifications

/// One-off reminders let today's completed study cancel only today's alert, without background execution.
enum ReminderPlan {
    static func dayID(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func completedDays(state: LocalState, calendar: Calendar = .current) -> Set<String> {
        Set(state.sessions.values.compactMap { session in
            guard session.slot == "evening", session.mode == "standard", let finished = session.completedAt,
                  session.steps.contains(where: { $0.kind == "recall" }) else { return nil }
            return dayID(finished, calendar: calendar)
        })
    }
    static func dates(preferences: LearningPreferences, completed: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        guard preferences.reminderEnabled, (0...23).contains(preferences.reminderHour), (0...59).contains(preferences.reminderMinute) else { return [] }
        return (0..<28).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let date = calendar.date(bySettingHour: preferences.reminderHour, minute: preferences.reminderMinute, second: 0, of: day),
                  date > now, !completed.contains(dayID(date, calendar: calendar)) else { return nil }
            return date
        }
    }
}

@MainActor final class LocalReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalReminder()
    var onOpen: (() -> Void)?
    var openRequested = false
    private let center = UNUserNotificationCenter.current()
    private var schedulingTask: Task<Void, Never>?
    private override init() { super.init(); center.delegate = self }

    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default: return false
        }
    }
    func refresh(state: LocalState) async {
        let previous = schedulingTask
        let next = Task { @MainActor in
            // Serialize pending-request replacement; an older async add must never override newer preferences.
            await previous?.value
            let pending = await self.center.pendingNotificationRequests()
            self.center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("iword-evening-") }.map(\.identifier))
            guard state.profile.preferences.reminderEnabled else { return }
            let settings = await self.center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            let calendar = Calendar.current
            let dates = ReminderPlan.dates(preferences: state.profile.preferences, completed: ReminderPlan.completedDays(state: state, calendar: calendar), calendar: calendar)
            for date in dates {
                let content = UNMutableNotificationContent(); content.title = "今晚，再遇见学过的词"
                content.body = "给记忆一点时间，完成今天的晚间复习。"; content.sound = .default
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                let request = UNNotificationRequest(identifier: "iword-evening-" + ReminderPlan.dayID(date, calendar: calendar), content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                try? await self.center.add(request)
            }
        }
        schedulingTask = next; await next.value
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        Task { @MainActor in
            if let open = self.onOpen { open() } else { self.openRequested = true }
        }
    }
}
