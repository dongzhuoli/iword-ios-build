import XCTest
@testable import IWordDomain

final class LearningRulesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private struct RuleFixture: Decodable {
        let stability: Int
        let rating: RecallRating
        let hinted: Bool
        let intervalHours: Double?
        let expectedStability: Int
        let expectedDelayMinutes: Int?
    }

    func testLearningSchedulesFourHoursAndRecordsContact() {
        let state = LearningRules.afterLearning(now: base)
        XCTAssertEqual(state.stability, 0)
        XCTAssertEqual(state.lastContactAt, base)
        XCTAssertEqual(state.dueAt, base.addingTimeInterval(4 * 60 * 60))
    }

    func testDelayedEasyIncrementsBeforeIntervalLookup() {
        let old = base.addingTimeInterval(-13 * 60 * 60)
        let state = ScheduleState(stability: 0, dueAt: base, lastContactAt: old)
        let result = LearningRules.afterRecall(
            state: state,
            rating: .easy,
            hinted: false,
            observedAt: base,
            now: base.addingTimeInterval(60),
            voluntary: false)

        XCTAssertEqual(result.state.stability, 1)
        XCTAssertEqual(result.state.dueAt, base.addingTimeInterval(60 + 3 * 24 * 60 * 60))
        XCTAssertTrue(result.delayedSuccess)
        XCTAssertFalse(result.clockAnomaly)
    }

    func testHintNormalizesIndependentRatingsToHintDelay() {
        let state = ScheduleState(stability: 3, dueAt: base, lastContactAt: base)
        let result = LearningRules.afterRecall(
            state: state,
            rating: .easy,
            hinted: true,
            observedAt: base.addingTimeInterval(60),
            now: base.addingTimeInterval(120),
            voluntary: false)

        XCTAssertEqual(result.state.stability, 0)
        XCTAssertEqual(result.state.dueAt, base.addingTimeInterval(120 + 4 * 60 * 60))
        XCTAssertFalse(result.delayedSuccess)
    }

    func testVoluntaryReviewPreservesScheduleButMovesContactBaseline() {
        let due = base.addingTimeInterval(86_400)
        let state = ScheduleState(stability: 2, dueAt: due, lastContactAt: base)
        let now = base.addingTimeInterval(90)
        let result = LearningRules.afterRecall(
            state: state,
            rating: .easy,
            hinted: false,
            observedAt: base.addingTimeInterval(60),
            now: now,
            voluntary: true)

        XCTAssertEqual(result.state.stability, 2)
        XCTAssertEqual(result.state.dueAt, due)
        XCTAssertEqual(result.state.lastContactAt, now)
        XCTAssertFalse(result.delayedSuccess)
    }

    func testClockAnomalyDoesNotAdvanceMasteryOrDueDate() {
        let due = base.addingTimeInterval(86_400)
        let state = ScheduleState(stability: 2, dueAt: due, lastContactAt: base)
        let now = base.addingTimeInterval(60)
        let result = LearningRules.afterRecall(
            state: state,
            rating: .easy,
            hinted: false,
            observedAt: base.addingTimeInterval(-1),
            now: now,
            voluntary: false)

        XCTAssertEqual(result.state.stability, 2)
        XCTAssertEqual(result.state.dueAt, due)
        XCTAssertEqual(result.state.lastContactAt, now)
        XCTAssertTrue(result.clockAnomaly)
        XCTAssertFalse(result.delayedSuccess)
    }

    func testNewWordLimitMatchesMorningAfternoonAndEveningCaps() {
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 2, afternoonUsed: 0, dailyUsed: 2), 3)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "afternoon", morningUsed: 5, afternoonUsed: 4, dailyUsed: 7), 1)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "evening", morningUsed: 0, afternoonUsed: 0, dailyUsed: 0), 0)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 0, afternoonUsed: 0, dailyUsed: 10), 0)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 6, afternoonUsed: 0, dailyUsed: 6), 0)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 0, afternoonUsed: 0, dailyUsed: 0, dailyLimit: 20), 10)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "afternoon", morningUsed: 10, afternoonUsed: 0, dailyUsed: 10, dailyLimit: 20), 10)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 0, afternoonUsed: 0, dailyUsed: 0, dailyLimit: 11), 6)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "afternoon", morningUsed: 6, afternoonUsed: 0, dailyUsed: 6, dailyLimit: 11), 5)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 0, afternoonUsed: 0, dailyUsed: 0, dailyLimit: 0), 0)
        XCTAssertEqual(LearningRules.newWordLimit(slot: "morning", morningUsed: 0, afternoonUsed: 0, dailyUsed: 0, dailyLimit: 51), 0)
    }

    func testAudioAssistedEasyDoesNotGrantMasteryAndIsDueNextDay() {
        let old = base.addingTimeInterval(-13 * 60 * 60)
        let result = LearningRules.afterRecall(
            state: ScheduleState(stability: 2, dueAt: old, lastContactAt: old),
            rating: .easy,
            hinted: false,
            observedAt: base,
            now: base.addingTimeInterval(60),
            voluntary: false,
            audioAssisted: true)

        XCTAssertEqual(result.state.stability, 2)
        XCTAssertEqual(result.state.dueAt, base.addingTimeInterval(60 + 24 * 60 * 60))
        XCTAssertFalse(result.delayedSuccess)
    }

    func testSharedRuleFixturesUseOneHourDefaultInterval() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "rule-fixtures",
            withExtension: "json",
            subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([RuleFixture].self, from: Data(contentsOf: url))

        for fixture in fixtures {
            let observedAt = base.addingTimeInterval((fixture.intervalHours ?? 1) * 60 * 60)
            let result = LearningRules.afterRecall(
                state: ScheduleState(stability: fixture.stability, lastContactAt: base),
                rating: fixture.rating,
                hinted: fixture.hinted,
                observedAt: observedAt,
                now: observedAt,
                voluntary: false)
            XCTAssertEqual(result.state.stability, fixture.expectedStability, fixture.rating.rawValue)
            if let minutes = fixture.expectedDelayMinutes {
                XCTAssertEqual(result.state.dueAt, observedAt.addingTimeInterval(TimeInterval(minutes * 60)))
            }
        }
    }
}
