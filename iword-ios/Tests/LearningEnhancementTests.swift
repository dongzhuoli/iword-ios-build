import XCTest
import IWordDomain
import IWordStorage
@testable import IWord

final class LearningEnhancementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPreferencesValidateCadenceRange() {
        XCTAssertTrue(LearningPreferences.validate(.init()))
        XCTAssertFalse(LearningPreferences.validate(.init(order: "random")))
        XCTAssertFalse(LearningPreferences.validate(.init(dailyNewWords: 51)))
    }

    func testNewWordsSequentialAndRecommendedOrdering() {
        var state = LocalState()
        let unknown = word("unknown", category: "required", unit: "Unit 2", order: 2)
        let familiar = word("familiar", category: "required", unit: "Unit 1", order: 1)
        let known = word("known", category: "basic", unit: "Unit 1", order: 0)
        state.words = [familiar, unknown, known]
        state.progress[unknown.id] = WordProgress(id: unknown.id, familiarity: "unknown")
        state.progress[familiar.id] = WordProgress(id: familiar.id, familiarity: "familiar")
        state.progress[known.id] = WordProgress(id: known.id, familiarity: "known")
        XCTAssertEqual(LearningSelection.newWords(state: state).map(\.id), [unknown.id, familiar.id])
        state.profile.learningPreferences = LearningPreferences(order: "sequential")
        XCTAssertEqual(LearningSelection.newWords(state: state).map(\.id), [familiar.id, unknown.id])
    }

    func testConsolidationKeepsWeakWordsWhenPreviousGroupHasAlternatives() {
        var state = LocalState()
        let weak = word("weak", order: 0), stable = word("stable", order: 1), other = word("other", order: 2)
        state.words = [weak, stable, other]
        state.progress[weak.id] = WordProgress(id: weak.id, learned: true, latestRating: .forgot, lastStudiedAt: now.addingTimeInterval(-300))
        state.progress[stable.id] = WordProgress(id: stable.id, learned: true, latestRating: .easy, lastStudiedAt: now)
        state.progress[other.id] = WordProgress(id: other.id, learned: true, latestRating: .easy, lastStudiedAt: now.addingTimeInterval(-100))
        state.sessions["previous"] = StudySession(id: "previous", mode: "review", studyDay: LocalState.studyDay(now), slot: "evening", createdAt: now.addingTimeInterval(-60), steps: [StudyStep(word: stable, kind: "recall")], position: 1)
        XCTAssertEqual(LearningSelection.consolidation(state: state, now: now, limit: 2).map(\.id), [weak.id, other.id])
    }

    func testEveningReviewsCoverAllNewWordsAndSkipCompletedNonDueRecall() {
        var state = LocalState()
        let newWord = word("new"), completed = word("completed", order: 1), due = word("due", order: 2)
        state.words = [newWord, completed, due]
        state.progress[newWord.id] = WordProgress(id: newWord.id, learned: true, firstLearnedAt: now)
        state.progress[completed.id] = WordProgress(id: completed.id, learned: true, firstLearnedAt: now.addingTimeInterval(-86_400), schedule: ScheduleState(dueAt: now.addingTimeInterval(86_400)))
        state.progress[due.id] = WordProgress(id: due.id, learned: true, firstLearnedAt: now.addingTimeInterval(-86_400), schedule: ScheduleState(dueAt: now.addingTimeInterval(-1)))
        state.sessions["evening"] = StudySession(id: "evening", mode: "standard", studyDay: LocalState.studyDay(now), slot: "evening", steps: [StudyStep(word: completed, kind: "recall")], position: 1)
        XCTAssertEqual(LearningSelection.standardReviews(state: state, now: now, slot: "evening").map(\.id), [newWord.id, due.id])
    }

    func testCreditDeduplicatesRoundAndBackfillDeduplicatesHistory() {
        var state = LocalState()
        let due = now.addingTimeInterval(86_400)
        state.progress["practice"] = WordProgress(id: "practice", learned: true, schedule: ScheduleState(stability: 3, dueAt: due, lastContactAt: now.addingTimeInterval(-100)))
        LearningHistory.credit(state: &state, wordID: "practice", source: "practice", roundID: "practice-round", now: now)
        XCTAssertEqual(state.progress["practice"]?.schedule.stability, 3)
        XCTAssertEqual(state.progress["practice"]?.schedule.dueAt, due)
        XCTAssertEqual(state.progress["practice"]?.schedule.lastContactAt, now)

        LearningHistory.credit(state: &state, wordID: "word", source: "learn", roundID: "round", now: now)
        LearningHistory.credit(state: &state, wordID: "word", source: "standard", roundID: "round", now: now.addingTimeInterval(5))
        XCTAssertEqual(state.progress["word"]?.studyCount, 1)
        XCTAssertEqual(state.progress["word"]?.learningCount, 1)
        XCTAssertEqual(state.progress["word"]?.lastStudiedAt, now.addingTimeInterval(5))

        LearningHistory.credit(state: &state, wordID: "interleaved", source: "learn", roundID: "A", now: now)
        LearningHistory.credit(state: &state, wordID: "interleaved", source: "practice", roundID: "B", now: now.addingTimeInterval(10))
        LearningHistory.credit(state: &state, wordID: "interleaved", source: "standard", roundID: "A", now: now.addingTimeInterval(20))
        XCTAssertEqual(state.progress["interleaved"]?.studyCount, 2)
        XCTAssertEqual(state.progress["interleaved"]?.learningCount, 1)
        XCTAssertEqual(state.progress["interleaved"]?.practiceCount, 1)
        XCTAssertEqual(state.progress["interleaved"]?.lastStudiedAt, now.addingTimeInterval(20))
        XCTAssertEqual(state.progress["interleaved"]?.previousStudiedAt, now)
        XCTAssertEqual(state.progress["interleaved"]?.creditedRoundIDs, Set(["A", "B"]))

        let events = [
            JournalEvent(kind: "LEARN", fields: ["sessionID": "s1", "wordID": "history"], occurredAt: now.addingTimeInterval(-20)),
            JournalEvent(kind: "RATE", fields: ["sessionID": "s1", "wordID": "history", "source": "standard"], occurredAt: now.addingTimeInterval(-10)),
            JournalEvent(kind: "ASSESS", fields: ["sessionID": "s2", "wordID": "history"], occurredAt: now)
        ]
        LearningHistory.backfill(state: &state, events: events)
        LearningHistory.backfill(state: &state, events: events)
        XCTAssertEqual(state.progress["history"]?.studyCount, 1)
        XCTAssertEqual(state.progress["history"]?.learningCount, 1)
        XCTAssertNil(state.progress["history"]?.previousStudiedAt)

        state.progress["history"]?.lastStudiedAt = now.addingTimeInterval(100)
        LearningHistory.backfill(state: &state, events: events)
        XCTAssertEqual(state.progress["history"]?.lastStudiedAt, now.addingTimeInterval(100))
    }

    func testDistantMemoriesTakeTenOldestRegardlessOfWeakness() {
        var state = LocalState()
        for index in 0..<14 {
            let value = word("word-\(index)", order: index)
            state.words.append(value)
            state.progress[value.id] = WordProgress(id: value.id, learned: true,
                latestRating: index == 0 ? .forgot : .easy,
                lastStudiedAt: now.addingTimeInterval(-Double(index) * 3600))
        }
        state.progress["word-13"]?.learned = false
        state.words[12].inactive = true
        XCTAssertEqual(LearningSelection.distantMemories(state: state).map(\.id),
                       (2...11).reversed().map { "word-\($0)" })
        XCTAssertTrue(LearningSelection.distantMemories(state: state, limit: 0).isEmpty)
        let first = LearningSelection.distantMemories(state: state, limit: 1)[0]
        LearningHistory.credit(state: &state, wordID: first.id, source: "review", roundID: "distant-round", now: now)
        XCTAssertEqual(LearningSelection.distantMemories(state: state, limit: 1).first?.id, "word-10")
    }

    func testDistantMemoriesFallbackDatesSmallPoolAndTaskSnapshot() throws {
        var state = LocalState()
        let first = word("first"), second = word("second", order: 1)
        state.words = [second, first]
        state.progress[first.id] = WordProgress(id: first.id, learned: true, firstLearnedAt: now.addingTimeInterval(-200))
        state.progress[second.id] = WordProgress(id: second.id, learned: true, firstLearnedAt: now.addingTimeInterval(-400),
            schedule: ScheduleState(lastContactAt: now.addingTimeInterval(-100)))
        let selected = LearningSelection.distantMemories(state: state)
        XCTAssertEqual(selected.map(\.id), [first.id, second.id])
        var task = StudySession(mode: "review", studyDay: LocalState.studyDay(now), slot: "morning",
            steps: selected.map { StudyStep(word: $0, kind: "recall") })
        task.reviewKind = "distant"; task.position = 1; task.paused = true
        let restored = try JSONDecoder().decode(StudySession.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(restored, task)
        XCTAssertEqual(restored.current?.word.id, second.id)
        XCTAssertEqual(restored.reviewKind, "distant")
    }

    func testMeaningCoreAndContextPreferPrimarySenseAndTrimGloss() {
        var value = word("radiate")
        value.meaning = "备用释义"
        value.usages = [
            WordUsage(key: "v", pos: "v.", phonetic: nil, senses: [
                WordSense(key: "primary", meaning: " 放射；发出\n延伸", primary: true,
                          examples: [WordExample(text: "The sun radiates heat.", translation: "太阳散发热量。")]),
                WordSense(key: "secondary", meaning: "扩散", primary: nil, examples: nil)
            ])
        ]

        XCTAssertEqual(MeaningLearning.coreMeaning(value), "放射")
        XCTAssertEqual(MeaningLearning.context(value)?.text, "The sun radiates heat.")
    }

    func testMeaningCueEscalatesFromTranslationToExampleToPosition() {
        var value = word("radiate")
        value.usages = [WordUsage(key: "v", pos: "v.", phonetic: nil, senses: [
            WordSense(key: "s", meaning: "放射", primary: true,
                      examples: [WordExample(text: "The sun radiates heat.", translation: "太阳散发热量。")])
        ])]
        XCTAssertEqual(MeaningLearning.cue(value, level: 1), "想想这个场景：太阳散发热量。")

        value.usages[0].senses[0].examples = [WordExample(text: "The sun radiates heat.", translation: nil)]
        XCTAssertEqual(MeaningLearning.cue(value, level: 1), "想想这个搭配：The sun radiates heat.")

        value.usages = []
        XCTAssertEqual(MeaningLearning.cue(value, level: 1), "词性：n。想不起就看看答案。")
        XCTAssertEqual(MeaningLearning.cue(value, level: 2), "radiate")
    }

    func testMeaningChoicesExcludeOverlappingGlossesAndRequireDistractors() {
        var answer = word("radiate")
        answer.meaning = "放射；散发"
        let overlap = word("radiation", order: 1)
        var overlapMeaning = overlap
        overlapMeaning.meaning = "放射"
        let distinct = word("objective", order: 2)
        var distinctMeaning = distinct
        distinctMeaning.meaning = "目标"
        let sameSpelling = word("radiate", order: 3)
        let choices = MeaningLearning.choices(for: answer, candidates: [sameSpelling, distinctMeaning, overlapMeaning])

        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices.contains { $0.id == answer.id && $0.meaning == "放射" })
        XCTAssertTrue(choices.contains { $0.id == distinctMeaning.id && $0.meaning == distinctMeaning.meaning })
        XCTAssertFalse(choices.contains { $0.id == overlapMeaning.id })
        XCTAssertEqual(Set(choices.map(\.meaning)).count, choices.count)
        XCTAssertTrue(MeaningLearning.choices(for: answer, candidates: [answer]).isEmpty)
    }

    func testMeaningStepsAddRecognitionBeforeUnaidedRecallAndRetrySupport() {
        var state = LocalState()
        let target = word("target")
        var distractor = word("distractor", order: 1)
        distractor.meaning = "另一个意思"
        state.words = [target, distractor]

        let steps = MeaningLearning.steps(words: [target], state: state)
        XCTAssertEqual(steps.map(\.kind), ["learn", "recognition", "recall"])
        XCTAssertEqual(steps[0].meaningEvidenceVersion, 3)
        XCTAssertEqual(steps[1].meaningChoices?.count, 2)

        var learnedState = state
        learnedState.progress[target.id] = WordProgress(id: target.id, learned: true)
        let retry = MeaningLearning.steps(words: [target], state: learnedState, retry: 1)
        XCTAssertEqual(retry.map(\.kind), ["learn", "recognition", "recall"])
        XCTAssertTrue(retry[0].relearning == true)
    }

    func testMeaningFollowUpLimitsRepeatedFailureToOneRelearningStep() {
        var state = LocalState()
        let target = word("target")
        var failed = MeaningLearning.step(target, kind: "recall")
        failed.meaningFailure = true
        let first = StudySession(mode: "standard", studyDay: "2026-11-13", slot: "morning", steps: [], position: 0)
        XCTAssertEqual(MeaningLearning.followUp(after: failed, session: first, state: state).map(\.kind),
                       ["learn", "recall"])

        var second = first
        var previous = MeaningLearning.step(target, kind: "recall")
        previous.meaningFailure = true
        second.steps = [previous]
        second.position = 1
        XCTAssertEqual(MeaningLearning.followUp(after: failed, session: second, state: state).map(\.kind), ["learn"])
        XCTAssertTrue(MeaningLearning.followUp(after: failed, session: second, state: state).first?.relearning == true)
    }

    func testMeaningIndependentCreditRequiresUnaidedRecall() {
        let target = word("target")
        var step = MeaningLearning.step(target, kind: "recall")
        XCTAssertTrue(MeaningLearning.independent(step, rating: .easy))
        XCTAssertFalse(MeaningLearning.independent(step, rating: .forgot))

        step.hinted = true
        XCTAssertFalse(MeaningLearning.independent(step, rating: .easy))
        step.hinted = false
        step.spellingBeforeRecall = true
        XCTAssertFalse(MeaningLearning.independent(step, rating: .slow))
        step.spellingBeforeRecall = false
        step.spelling = SpellingRound(word: target.word)
        XCTAssertTrue(MeaningLearning.independent(step, rating: .easy))
        step.meaningEvidenceVersion = nil
        XCTAssertFalse(MeaningLearning.independent(step, rating: .easy))
    }

    func testPauseNewWordsHonorsGentlePeriodAndWeakWordThreshold() {
        var state = LocalState()
        state.words = (0..<5).map { word("word-\($0)", order: $0) }
        for value in state.words {
            state.progress[value.id] = WordProgress(id: value.id, learned: true, latestHinted: true)
        }
        XCTAssertTrue(MeaningLearning.pauseNewWords(state: state, now: now))

        state.progress.removeAll()
        state.profile.gentleStartedAt = now.addingTimeInterval(-4 * 86_400)
        XCTAssertFalse(MeaningLearning.pauseNewWords(state: state, now: now))
        state.profile.gentleStartedAt = now
        XCTAssertTrue(MeaningLearning.pauseNewWords(state: state, now: now.addingTimeInterval(86_400)))
    }

    private func word(_ id: String, category: String = "required", unit: String = "Unit 1", order: Int = 0) -> MobileWord {
        MobileWord(
            id: id, revision: "r1", catalogID: "c1", word: id, meaning: id, pos: "n", phonetic: "",
            category: category, unit: unit, printedPage: 1, order: order, usages: [], parts: [],
            audioHash: nil, audioUsageKey: nil, audioNote: nil, packageID: nil, inactive: false)
    }
}
