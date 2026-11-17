import XCTest
@testable import IWord

final class AICoachScheduleTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testShanghaiNightCutoffBeforeAndAfter1130() {
        let before = date("2026-11-17T15:29:00Z")
        let after = date("2026-11-17T15:31:00Z")
        XCTAssertEqual(AICoachBackground.cutoff(now: before), date("2026-11-16T15:30:00Z"))
        XCTAssertEqual(AICoachBackground.cutoff(now: after), date("2026-11-17T15:30:00Z"))
        XCTAssertEqual(AICoachBackground.nextDate(now: after), date("2026-11-18T15:30:00Z"))
        XCTAssertEqual(AICoachBackground.cutoff(now: date("2026-11-17T16:05:00Z")), date("2026-11-17T15:30:00Z"))
    }
    func testAdoptedPlanIsDatedAndCannotRaiseManualLimit() {
        var state = LocalState()
        state.profile.learningPreferences = LearningPreferences(dailyNewWords: 12)
        state.profile.aiCoach = AICoachArchive(adoptedPlan: AdoptedCoachPlan(reportID: "r", day: "2026-11-17", dailyNewWords: 20, reviewWordIDs: []))
        XCTAssertEqual(AICoachArchive.effectiveDailyLimit(state: state, now: date("2026-11-17T03:00:00Z")), 12)
        state.profile.aiCoach?.adoptedPlan?.dailyNewWords = 4
        XCTAssertEqual(AICoachArchive.effectiveDailyLimit(state: state, now: date("2026-11-17T03:00:00Z")), 4)
        XCTAssertEqual(AICoachArchive.effectiveDailyLimit(state: state, now: date("2026-11-18T03:00:00Z")), 12)
    }
    func testPriorityReviewHonorsSlotSpacingAndCompletedWords() {
        let now = date("2026-11-17T03:00:00Z")
        func word(_ id: String) -> MobileWord {
            MobileWord(id: id, revision: "r", catalogID: "c", word: id, meaning: id, pos: "n.", phonetic: "", category: "required", unit: "Unit 1", printedPage: 1, order: 0, usages: [], parts: [])
        }
        var state = LocalState(); let a = word("a"), b = word("b"), c = word("c")
        state.words = [a, b, c]; state.profile.associationPlanStartedAt = now.addingTimeInterval(-86400)
        state.progress[a.id] = WordProgress(id: a.id, learned: true, lastStudiedAt: now.addingTimeInterval(-86400))
        state.progress[b.id] = WordProgress(id: b.id, learned: true, lastStudiedAt: now)
        state.progress[c.id] = WordProgress(id: c.id, learned: true, lastStudiedAt: now.addingTimeInterval(-86400))
        state.profile.aiCoach = AICoachArchive(adoptedPlan: AdoptedCoachPlan(reportID: "r", day: "2026-11-17", dailyNewWords: 4, reviewWordIDs: [a.id,b.id,c.id], morningReviewIDs: [a.id,b.id], afternoonReviewIDs: [c.id]))
        XCTAssertEqual(AICoachArchive.prioritizedReviews([], state: state, now: now).map(\.id), [a.id])
        state.sessions["done"] = StudySession(mode: "review", studyDay: "2026-11-17", slot: "morning", steps: [StudyStep(word: a, kind: "recall")], position: 1)
        XCTAssertTrue(AICoachArchive.prioritizedReviews([], state: state, now: now).isEmpty)
        state.profile.slot = "afternoon"
        XCTAssertEqual(AICoachArchive.prioritizedReviews([], state: state, now: now).map(\.id), [c.id])
    }
    func testArchiveRejectsOutOfRangePlan() {
        let archive = AICoachArchive(adoptedPlan: AdoptedCoachPlan(reportID: "r", day: "2026-11-17", dailyNewWords: 51, reviewWordIDs: []))
        XCTAssertThrowsError(try archive.validate())
    }
}
