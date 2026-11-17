import XCTest
import IWordDomain
@testable import IWord

final class AssociationLearningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPhaseLowersLimitOnlyOnceAndPreservesZeroOrLowerChoices() {
        var state = personalState()
        state.profile.learningPreferences = LearningPreferences(dailyNewWords: 12)
        XCTAssertTrue(AssociationLearning.beginIfNeeded(state: &state, now: now))
        XCTAssertEqual(state.profile.preferences.dailyNewWords, 6)
        state.profile.learningPreferences?.dailyNewWords = 20
        XCTAssertFalse(AssociationLearning.beginIfNeeded(state: &state, now: now.addingTimeInterval(100)))
        XCTAssertEqual(state.profile.preferences.dailyNewWords, 20)
        XCTAssertEqual(state.profile.associationPlanStartedAt, now)
        var zero = LocalState()
        zero.profile.learningPreferences = LearningPreferences(dailyNewWords: 0)
        AssociationLearning.beginIfNeeded(state: &zero, now: now)
        XCTAssertEqual(zero.profile.preferences.dailyNewWords, 0)
        var lower = LocalState()
        lower.profile.learningPreferences = LearningPreferences(dailyNewWords: 3)
        AssociationLearning.beginIfNeeded(state: &lower, now: now)
        XCTAssertEqual(lower.profile.preferences.dailyNewWords, 3)
    }

    func testOnlyUserWrittenHintsAreUsedAndImportedSuggestionsStayHidden() {
        var state = LocalState()
        let target = word("absorb")
        XCTAssertNil(AssociationLearning.note(for: target, state: state))
        state.profile.associationNotes = ["absorb": PersonalAssociation(cue: "自动生成", source: "suggestion")]
        XCTAssertNil(AssociationLearning.note(for: target, state: state))
        state.profile.associationNotes = ["absorb": PersonalAssociation(cue: "我写的海绵", source: "personal")]
        XCTAssertEqual(AssociationLearning.note(for: target, state: state)?.cue, "我写的海绵")
    }

    func testPersonalNoteSurvivesChangedContentIDAndFreezesInTask() throws {
        var state = personalState()
        let target = word("absorb")
        let original = try XCTUnwrap(AssociationLearning.note(for: target, state: state))
        let snapshot = AssociationLearning.decorate(StudyStep(word: target, kind: "recall"), state: state)
        let changed = PersonalAssociation(cue: "我的海绵", story: "我自己的画面", version: "personal-v2")
        state.profile.associationNotes = ["absorb": changed]
        var replacement = target
        replacement.id = "updated-content-id"
        XCTAssertEqual(AssociationLearning.note(for: replacement, state: state), changed)
        XCTAssertEqual(snapshot.association, original)
        let restored = try JSONDecoder().decode(StudyStep.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.association, original)
        // Saving an empty override suppresses a suggested card instead of restoring it.
        state.profile.associationNotes?["absorb"] = PersonalAssociation()
        XCTAssertNil(AssociationLearning.note(for: replacement, state: state))
    }

    func testSpacingSeparatesStrugglingAndSuccessfulWordsAndClockFuture() {
        var state = personalState()
        state.profile.associationPlanStartedAt = now
        var progress = WordProgress(id: "word", learned: true, latestRating: .forgot, lastStudiedAt: now.addingTimeInterval(-29 * 60))
        XCTAssertFalse(AssociationLearning.ready(progress, state: state, now: now))
        progress.lastStudiedAt = now.addingTimeInterval(-30 * 60)
        XCTAssertTrue(AssociationLearning.ready(progress, state: state, now: now))
        progress.latestRating = .easy
        XCTAssertFalse(AssociationLearning.ready(progress, state: state, now: now))
        progress.lastStudiedAt = now.addingTimeInterval(-4 * 3600)
        XCTAssertTrue(AssociationLearning.ready(progress, state: state, now: now))
        progress.lastStudiedAt = now.addingTimeInterval(1)
        XCTAssertFalse(AssociationLearning.ready(progress, state: state, now: now))
        state.profile.associationPlanStartedAt = nil
        XCTAssertTrue(AssociationLearning.ready(progress, state: state, now: now))
    }

    func testAutomaticAndConsolidationSkipRecentWordsButDistantRemainsExplicit() {
        var state = personalState()
        state.profile.associationPlanStartedAt = now
        let target = word("absorb")
        state.words = [target]
        state.progress[target.id] = WordProgress(id: target.id, learned: true, schedule: ScheduleState(dueAt: now.addingTimeInterval(-1)), latestRating: .forgot, lastStudiedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(LearningSelection.standardReviews(state: state, now: now, slot: "morning").isEmpty)
        XCTAssertTrue(LearningSelection.consolidation(state: state, now: now).isEmpty)
        XCTAssertEqual(LearningSelection.distantMemories(state: state).map(\.id), [target.id])
        state.progress[target.id]?.lastStudiedAt = now.addingTimeInterval(-1800)
        XCTAssertEqual(LearningSelection.standardReviews(state: state, now: now, slot: "morning").map(\.id), [target.id])
    }

    func testFailureRevisitsAssociationOnceWithoutAnotherImmediateQuiz() {
        var state = personalState()
        state.profile.associationPlanStartedAt = now
        let target = word("absorb")
        state.progress[target.id] = WordProgress(id: target.id, learned: true)
        var failed = MeaningLearning.step(target, kind: "recall")
        failed.meaningFailure = true
        let session = StudySession(mode: "standard", studyDay: "2026-11-16", slot: "morning", steps: [failed])
        let followUp = MeaningLearning.followUp(after: failed, session: session, state: state)
        XCTAssertEqual(followUp.map(\.kind), ["learn"])
        XCTAssertTrue(followUp.first?.relearning == true)
        XCTAssertEqual(followUp.first?.association, state.profile.associationNotes?["absorb"])
        XCTAssertEqual(state.progress[target.id]?.latestRating, nil)
    }

    func testFirstExposureFollowsWordAndVersionAcrossRounds() throws {
        var state = personalState()
        let target = word("absorb")
        var learning = AssociationLearning.decorate(StudyStep(word: target, kind: "learn"), state: state)
        XCTAssertNil(learning.associationExposedAt)
        AssociationLearning.expose(&learning, state: &state, now: now)
        let recall = AssociationLearning.decorate(StudyStep(word: target, kind: "recall"), state: state)
        XCTAssertEqual(recall.associationExposedAt, now)
        var another = recall
        AssociationLearning.expose(&another, state: &state, now: now.addingTimeInterval(100))
        XCTAssertEqual(another.associationExposedAt, now)
        state.profile.associationNotes = ["absorb": PersonalAssociation(cue: "新线索", story: "新画面", version: "new")]
        let changed = AssociationLearning.decorate(StudyStep(word: target, kind: "learn"), state: state)
        XCTAssertNil(changed.associationExposedAt)
        let restored = try JSONDecoder().decode(LocalProfile.self, from: JSONEncoder().encode(state.profile))
        XCTAssertEqual(restored.associationExposureDates, state.profile.associationExposureDates)
    }

    func testOldProfilesDecodeWithoutNewFieldsAndInvalidNotesAreRejected() throws {
        let original = LocalProfile()
        let restored = try JSONDecoder().decode(LocalProfile.self, from: JSONEncoder().encode(original))
        XCTAssertNil(restored.associationNotes)
        XCTAssertNil(restored.associationPlanStartedAt)
        XCTAssertFalse(PersonalAssociation(cue: String(repeating: "a", count: 201)).valid)
        XCTAssertFalse(PersonalAssociation(source: "verified-etymology").valid)
        var state = personalState()
        state.profile.associationNotes = ["absorb": PersonalAssociation(cue: "海绵", story: "吸水", version: "v1")]
        let notes = try JSONDecoder().decode(LocalProfile.self, from: JSONEncoder().encode(state.profile))
        XCTAssertEqual(notes.associationNotes, state.profile.associationNotes)
    }

    func testSameSpellingFromRepeatedImportsOnlyGetsOneLearningSequence() {
        let state = personalState()
        let original = word("absorb")
        var duplicate = original
        duplicate.id = "other-import-id"
        let steps = MeaningLearning.steps(words: [original, duplicate], state: state)
        XCTAssertEqual(steps.filter { $0.kind == "learn" }.count, 1)
        XCTAssertEqual(steps.filter { $0.kind == "recall" }.count, 1)
    }

    func testFormationUsesImportedPartsWithoutGuessingFromSpelling() {
        var target = word("absorb")
        XCTAssertTrue(WordFormation.parts(target).isEmpty)
        target.parts = [WordPart(type: "root", text: "导入的词根"),
                        WordPart(type: "etymology", text: "导入的词源及来源"),
                        WordPart(type: "structure", text: "导入的组成"),
                        WordPart(type: "mnemonic", text: "书中助记"),
                        WordPart(type: "derived", text: "派生词另列")]
        XCTAssertEqual(WordFormation.parts(target).map(\.type), ["structure", "etymology"])
        XCTAssertTrue(WordFormation.parts(target)[0].text.contains("导入的词根"))
        XCTAssertTrue(WordFormation.parts(target)[0].text.contains("导入的组成"))
    }

    private func personalState() -> LocalState {
        var state = LocalState()
        state.profile.associationNotes = ["absorb": PersonalAssociation(cue: "我的海绵", story: "吸水", version: "personal-v1")]
        return state
    }

    private func word(_ spelling: String) -> MobileWord {
        MobileWord(id: spelling, revision: "r1", catalogID: "c1", word: spelling, meaning: "吸收", pos: "v.", phonetic: "", category: "required", unit: "Unit 1", printedPage: 1, order: 0, usages: [], parts: [])
    }
}
