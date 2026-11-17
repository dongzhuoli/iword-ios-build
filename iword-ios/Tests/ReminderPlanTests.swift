import XCTest
@testable import IWord

final class ReminderPlanTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    func testRemindersAreOptInAndSkipCompletedOrPastDays() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T10:00:00Z"))
        var preferences = LearningPreferences()
        XCTAssertTrue(ReminderPlan.dates(preferences: preferences, completed: [], now: now, calendar: calendar).isEmpty)
        preferences.reminderEnabled = true
        let dates = ReminderPlan.dates(preferences: preferences, completed: [], now: now, calendar: calendar)
        XCTAssertEqual(dates.count, 28)
        XCTAssertEqual(calendar.component(.hour, from: dates[0]), 20)
        XCTAssertEqual(calendar.component(.minute, from: dates[0]), 30)
        let completed = ReminderPlan.dates(preferences: preferences, completed: ["2026-11-11"], now: now, calendar: calendar)
        XCTAssertEqual(completed.count, 27); XCTAssertEqual(ReminderPlan.dayID(completed[0], calendar: calendar), "2026-11-12")
        preferences.reminderHour = 9
        let past = ReminderPlan.dates(preferences: preferences, completed: [], now: now, calendar: calendar)
        XCTAssertEqual(past.count, 27); XCTAssertEqual(ReminderPlan.dayID(past[0], calendar: calendar), "2026-11-12")
    }
    func testOnlyCompletedEveningRecallCancelsTodaysReminder() throws {
        let fixture = Bundle(for: Self.self).url(forResource: "valid", withExtension: "zip", subdirectory: "Fixtures")!
        let (_, words) = try ContentInstaller.install(fixture)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T20:00:00Z"))
        var state = LocalState()
        var task = StudySession(mode: "standard", studyDay: "2026-11-11", slot: "morning", steps: [StudyStep(word: words[0], kind: "recall")])
        task.completedAt = date; task.position = 1; state.sessions[task.id] = task
        XCTAssertTrue(ReminderPlan.completedDays(state: state, calendar: calendar).isEmpty)
        task.slot = "evening"; task.completedAt = nil; state.sessions[task.id] = task
        XCTAssertTrue(ReminderPlan.completedDays(state: state, calendar: calendar).isEmpty)
        task.completedAt = date; state.sessions[task.id] = task
        XCTAssertEqual(ReminderPlan.completedDays(state: state, calendar: calendar), ["2026-11-11"])
    }
}
