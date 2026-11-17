import XCTest
@testable import IWord

final class SpokenMeaningTests: XCTestCase {
    func testAcceptsAnySenseCommonWordingAndRejectsVagueOrNegativeAnswers() {
        var target = word("radiant", meaning: "发光的，容光焕发的；光芒四射的")
        XCTAssertTrue(SpokenMeaning.matches("发光的", word: target))
        XCTAssertTrue(SpokenMeaning.matches("这个词的意思是发出光", word: target))
        XCTAssertTrue(SpokenMeaning.matches("容光焕发", word: target))
        XCTAssertTrue(SpokenMeaning.matches("发光，容光焕发", word: target))
        XCTAssertFalse(SpokenMeaning.matches("发光，反对", word: target))
        XCTAssertFalse(SpokenMeaning.matches("光", word: target))
        XCTAssertFalse(SpokenMeaning.matches("不发光", word: target))
        target.meaning = "物体；对象"
        target.usages = [WordUsage(key: "verb", pos: "v.", senses: [WordSense(key: "oppose", meaning: "反对，不赞成")])]
        XCTAssertTrue(SpokenMeaning.matches("不赞成", word: target))
        XCTAssertFalse(SpokenMeaning.matches("不反对", word: target))
        XCTAssertFalse(SpokenMeaning.matches("赞成", word: target))
        XCTAssertFalse(SpokenMeaning.matches("我不反对但也不是很赞成", word: target))
        XCTAssertTrue(SpokenMeaning.matches("书", word: word("book", meaning: "书")))
    }

    func testFirstCorrectRevealsWithoutRatingOrAdvancing() {
        var step = StudyStep(word: word("radiant", meaning: "发光的"), kind: "recall")
        XCTAssertEqual(SpokenMeaning.submit("发光", to: &step), true)
        XCTAssertEqual(step.spokenAttempts, 1)
        XCTAssertTrue(step.revealed)
        XCTAssertEqual(step.spokenTranscript, "发光")
        XCTAssertNil(step.meaningFailure)
        XCTAssertTrue(SpokenMeaning.valid(step))
        XCTAssertNil(SpokenMeaning.submit("发光", to: &step))
        XCTAssertEqual(step.spokenAttempts, 1)
    }

    func testSecondMismatchRevealsAndStopsFurtherAttempts() {
        var step = StudyStep(word: word("radiant", meaning: "发光的"), kind: "recall")
        XCTAssertEqual(SpokenMeaning.submit("激进的", to: &step), false)
        XCTAssertFalse(step.revealed)
        XCTAssertEqual(step.spokenAttempts, 1)
        XCTAssertEqual(SpokenMeaning.submit("目标", to: &step), false)
        XCTAssertTrue(step.revealed)
        XCTAssertEqual(step.spokenAttempts, 2)
        XCTAssertTrue(SpokenMeaning.valid(step))
        XCTAssertNil(SpokenMeaning.submit("发光", to: &step))
        XCTAssertEqual(step.spokenAttempts, 2)
    }

    func testEmptyRecognitionDoesNotCountAndRetryCanSucceed() {
        var step = StudyStep(word: word("object", meaning: "反对"), kind: "recall")
        XCTAssertNil(SpokenMeaning.submit("  ", to: &step))
        XCTAssertNil(step.spokenAttempts)
        XCTAssertNil(SpokenMeaning.submit("。", to: &step))
        XCTAssertNil(step.spokenAttempts)
        XCTAssertEqual(SpokenMeaning.submit("物理", to: &step), false)
        XCTAssertEqual(SpokenMeaning.submit("不赞成", to: &step), true)
        XCTAssertTrue(step.revealed)
        XCTAssertEqual(step.spokenAttempts, 2)
        XCTAssertTrue(SpokenMeaning.valid(step))
    }

    func testLegacySpeechFieldsDecodeAndNewFieldsRoundTrip() throws {
        let original = StudyStep(word: word("radiant", meaning: "发光的"), kind: "recall")
        let raw = try JSONEncoder().encode(original)
        let old = try JSONDecoder().decode(StudyStep.self, from: raw)
        XCTAssertNil(old.spokenAttempts)
        XCTAssertTrue(SpokenMeaning.valid(old))
        var answered = old
        _ = SpokenMeaning.submit("发光", to: &answered)
        let restored = try JSONDecoder().decode(StudyStep.self, from: JSONEncoder().encode(answered))
        XCTAssertEqual(answered, restored)
        answered.spokenAttempts = 3
        XCTAssertFalse(SpokenMeaning.valid(answered))
    }

    func testWordProgressIgnoresSubstepsRevealAndFailureRetries() throws {
        let first = word("first", meaning: "第一"), second = word("second", meaning: "第二")
        var session = StudySession(mode: "standard", studyDay: "2026-11-15", slot: "morning", steps: [
            StudyStep(word: first, kind: "learn"), StudyStep(word: first, kind: "recognition"),
            StudyStep(word: second, kind: "learn"), StudyStep(word: first, kind: "recall"),
            StudyStep(word: second, kind: "recall"), StudyStep(word: first, kind: "learn", retry: 1)
        ])
        XCTAssertEqual(session.totalWordCount, 2)
        for position in 0...4 {
            session.position = position
            XCTAssertEqual(session.completedWordCount, 0)
        }
        session.steps[4].revealed = true
        XCTAssertEqual(session.completedWordCount, 0)
        session.position = 5
        XCTAssertEqual(session.completedWordCount, 1)
        let resumed = try JSONDecoder().decode(StudySession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(resumed.completedWordCount, 1)
        session.position = 6
        XCTAssertEqual(session.completedWordCount, 2)
        XCTAssertEqual(session.totalWordCount, 2)
    }

    func testFailureRevisitStaysWithWordUntilCompletionAndDeduplicatesContentIDs() {
        let first = word("first", meaning: "第一"), second = word("second", meaning: "第二")
        var alternate = first
        alternate.id = "first-reimported"
        var session = StudySession(mode: "review", studyDay: "2026-11-17", slot: "morning", steps: [
            StudyStep(word: first, kind: "recall"), StudyStep(word: second, kind: "recall")
        ])
        session.insertFollowUp([StudyStep(word: alternate, kind: "learn", retry: 1)])
        session.position = 1
        XCTAssertEqual(session.current?.word.word, first.word)
        XCTAssertEqual(session.completedWordCount, 0)
        XCTAssertEqual(session.totalWordCount, 2)
        session.position = 2
        XCTAssertEqual(session.current?.word.word, second.word)
        XCTAssertEqual(session.completedWordCount, 1)
        session.position = 3
        XCTAssertEqual(session.completedWordCount, 2)
    }

    private func word(_ id: String, meaning: String) -> MobileWord {
        MobileWord(id: id, revision: "r1", catalogID: "c1", word: id, meaning: meaning, pos: "adj.", phonetic: "", category: "required", unit: "Unit 1", printedPage: 1, order: 0, usages: [], parts: [])
    }
}
