import XCTest
@testable import IWord

final class AICoachPracticeTests: XCTestCase {
    func testThirdWrongSpellingRevealsAndCompletedQuestionCannotBeCreditedAgain() {
        let question = AICoachExercise(kind: .spelling, wordID: "radiate", answer: "radiate")
        var result = CoachExerciseProgress()
        result.answer(question, spelling: "radiant")
        XCTAssertEqual(result.firstCorrect, false); XCTAssertFalse(result.complete)
        result.answer(question, spelling: "radiates")
        XCTAssertFalse(result.complete)
        result.answer(question, spelling: "radiation")
        XCTAssertTrue(result.complete); XCTAssertTrue(result.revealed)
        let completed = result
        result.answer(question, spelling: "radiate")
        XCTAssertEqual(result, completed)
    }
    func testRetrySuccessPreservesFirstFailureAndTracksLatestSuccess() {
        let question = AICoachExercise(kind: .meaningChoice, wordID: "a", choiceWordIDs: ["a", "b", "c", "d"])
        var result = CoachExerciseProgress()
        result.answer(question, choiceIndex: 1)
        result.answer(question, choiceIndex: 0)
        XCTAssertEqual(result.firstCorrect, false); XCTAssertEqual(result.lastCorrect, true)
        XCTAssertTrue(result.complete); XCTAssertEqual(result.attempts, 2)
    }
    func testRecallSelfAssessmentRequiresRevealButCanRecordIndependentRecall() {
        let question = AICoachExercise(kind: .meaningRecall, wordID: "a")
        var result = CoachExerciseProgress()
        result.answer(question, recalled: true)
        XCTAssertEqual(result.attempts, 0)
        result.revealed = true
        result.answer(question, recalled: true)
        XCTAssertEqual(result.firstCorrect, true); XCTAssertTrue(result.complete)
    }
    func testHintedRecallIsNotRecordedAsIndependentFirstSuccess() {
        let question = AICoachExercise(kind: .meaningRecall, wordID: "a", hint: "想想你的个人联想")
        var result = CoachExerciseProgress(revealed: true, hintUsed: true)
        result.answer(question, recalled: true)
        XCTAssertEqual(result.firstCorrect, false); XCTAssertEqual(result.lastCorrect, true)
    }
    func testInvalidChoiceAndEmptySpellingAnswerDoNotAdvance() {
        var result = CoachExerciseProgress()
        result.answer(AICoachExercise(kind: .meaningChoice, wordID: "a", choiceWordIDs: ["a", "b", "c", "d"]), choiceIndex: 5)
        result.answer(AICoachExercise(kind: .spelling, wordID: "a"), spelling: "")
        XCTAssertEqual(result.attempts, 0); XCTAssertNil(result.firstCorrect)
    }
}
