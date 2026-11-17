import XCTest
@testable import IWord

final class PracticeEngineTests: XCTestCase {
    func testMeaningOptionsUseDistinctMeaningsAndIgnoreDuplicateInactiveWords() throws {
        let words = [word("one", "one", "一"), word("duplicate", "duplicate", "一"), word("two", "two", "二"), word("three", "three", "三"), word("four", "four", "四"), word("old", "old", "旧", inactive: true)]
        let round = try PracticeEngine.make(kind: .meaning, words: words)
        XCTAssertEqual(Set(round.questions.map(\.word.id)), Set(["one", "two", "three", "four"]))
        XCTAssertTrue(round.questions.allSatisfy { Set($0.choices.map { $0.word.meaning }).count == 4 })
        XCTAssertNoThrow(try round.validate())
    }

    func testCompletionUsesNineUniqueSameLengthChoices() throws {
        let round = try PracticeEngine.make(kind: .completion, words: [word("a", "alphabetical", "字母")])
        let question = try XCTUnwrap(round.current)
        let answer = try XCTUnwrap(question.answer)
        XCTAssertEqual(question.letterChoices.count, 9)
        XCTAssertEqual(Set(question.letterChoices.map { $0.lowercased() }).count, 9)
        XCTAssertTrue(question.letterChoices.allSatisfy { $0.count == answer.count })
        XCTAssertTrue(question.letterChoices.contains(answer))
    }

    func testMatchingPartialProgressPreservesSnapshotAndMeaningOrder() throws {
        let values = [word("a", "apple", "苹果"), word("b", "book", "书"), word("c", "cat", "猫")]
        var round = try PracticeEngine.make(kind: .matching, words: values)
        let first = try XCTUnwrap(round.current)
        XCTAssertEqual(first.orderedPairs.count, first.pairs.count)
        XCTAssertEqual(round.match(englishID: first.pairs[0].word.id, meaningID: first.pairs[1].word.id), .incorrect)
        XCTAssertEqual(round.match(englishID: first.pairs[0].word.id, meaningID: first.pairs[0].word.id), .correct)
        XCTAssertEqual(round.creditedWordIDs, Set([first.pairs[0].word.id]))
        XCTAssertNoThrow(try round.validate())
        let restored = try JSONDecoder().decode(PracticeRound.self, from: JSONEncoder().encode(round))
        XCTAssertEqual(try XCTUnwrap(restored.current).orderedPairs.map(\.word.id), first.orderedPairs.map(\.word.id))
        XCTAssertEqual(restored.referencedWords.map(\.id).sorted(), values.map(\.id).sorted())
    }

    func testSentenceRequiresExactInflectionWithoutLeakingAnswer() throws {
        var target = word("r", "radiate", "放射")
        target.usages = [WordUsage(key: "v", pos: "v.", phonetic: nil, senses: [WordSense(key: "s", meaning: "放射", primary: true, examples: [WordExample(text: "~ radiates.", translation: nil), WordExample(text: "The sun radiates heat.", translation: nil)])])]
        var round = try PracticeEngine.make(kind: .sentence, words: [target])
        let question = try XCTUnwrap(round.current)
        XCTAssertEqual(question.blankedText, "The sun ________ heat.")
        XCTAssertEqual(question.answer, "radiates")
        XCTAssertFalse(question.answerHint?.contains("radiates") ?? true)
        XCTAssertEqual(round.submit("radiate"), .incorrect)
        XCTAssertEqual(round.submit("radiates"), .correct)
        XCTAssertTrue(try XCTUnwrap(round.current).completed)
        XCTAssertNil(try XCTUnwrap(round.current).answerRevealed)
        XCTAssertEqual(round.creditedWordIDs, Set(["r"]))
    }

    func testTextEntryRevealsAfterThreeMissesWithoutCreditAndCanAdvance() throws {
        var target = word("r", "radiate", "放射")
        target.usages = [WordUsage(key: "v", pos: "v.", phonetic: nil, senses: [WordSense(key: "s", meaning: "放射", primary: true, examples: [WordExample(text: "The sun radiates heat.", translation: nil)])])]
        var round = try PracticeEngine.make(kind: .sentence, words: [target])

        XCTAssertEqual(round.submit("wrong-one"), .incorrect)
        XCTAssertEqual(round.submit("wrong-two"), .incorrect)
        XCTAssertEqual(round.submit("wrong-three"), .incorrect)
        let question = try XCTUnwrap(round.current)
        XCTAssertTrue(question.completed)
        XCTAssertEqual(question.errors, 3)
        XCTAssertEqual(question.firstAnswerCorrect, false)
        XCTAssertEqual(question.answerRevealed, true)
        XCTAssertTrue(round.creditedWordIDs.isEmpty)
        XCTAssertNoThrow(try round.validate())
        let restored = try JSONDecoder().decode(PracticeRound.self, from: JSONEncoder().encode(round))
        XCTAssertTrue(try XCTUnwrap(restored.current).completed)
        XCTAssertEqual(try XCTUnwrap(restored.current).errors, 3)
        XCTAssertEqual(try XCTUnwrap(restored.current).answerRevealed, true)
        XCTAssertTrue(restored.creditedWordIDs.isEmpty)
        var resumed = restored
        XCTAssertTrue(resumed.advance())
        XCTAssertTrue(resumed.isComplete)
        XCTAssertTrue(resumed.creditedWordIDs.isEmpty)
    }

    func testThirdWrongSpellingAttemptRevealsWithoutCredit() throws {
        let target = word("r", "radiate", "放射")
        var round = try PracticeEngine.make(kind: .spelling, words: [target])
        XCTAssertEqual(round.submit("wrong-one"), .incorrect)
        XCTAssertEqual(round.submit("wrong-two"), .incorrect)
        XCTAssertEqual(round.submit("wrong-three"), .incorrect)
        let question = try XCTUnwrap(round.current)
        XCTAssertEqual(question.answer, "radiate")
        XCTAssertEqual(question.answerRevealed, true)
        XCTAssertTrue(round.creditedWordIDs.isEmpty)
        XCTAssertNoThrow(try round.validate())
    }

    func testLegacyCompletedTextRoundWithThreeErrorsStillValidatesAndKeepsCredit() throws {
        let target = word("r", "radiate", "放射")
        let question = PracticeQuestion(kind: .spelling, word: target, answer: "radiate",
                                        errors: 3, firstAnswerCorrect: false, completed: true)
        var legacy = PracticeRound(kind: .spelling, questions: [question], creditedWordIDs: Set(["r"]))
        XCTAssertNil(question.answerRevealed)
        XCTAssertNoThrow(try legacy.validate())
        let restored = try JSONDecoder().decode(PracticeRound.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(try XCTUnwrap(restored.current).answerRevealed)
        XCTAssertNoThrow(try restored.validate())
        legacy = restored
        XCTAssertTrue(legacy.advance())
    }

    func testListeningRequiresAudioAndKeepsAnswerFieldsEmpty() throws {
        let noAudio = [word("a", "a", "甲"), word("b", "b", "乙"), word("c", "c", "丙"), word("d", "d", "丁")]
        XCTAssertThrowsError(try PracticeEngine.make(kind: .listening, words: noAudio))
        var values = noAudio; values[0].audioHash = "local-hash"
        let round = try PracticeEngine.make(kind: .listening, words: values)
        XCTAssertTrue(round.questions.allSatisfy { $0.word.audioHash == "local-hash" && $0.answer == nil && $0.blankedText == nil })
    }

    func testValidateRejectsCreditsAndUnfinishedPriorQuestion() throws {
        let values = [word("a", "apple", "苹果"), word("b", "book", "书"), word("c", "cat", "猫"), word("d", "dog", "狗")]
        var round = try PracticeEngine.make(kind: .meaning, words: values)
        round.position = 1
        XCTAssertThrowsError(try round.validate())
        round.position = 0; round.creditedWordIDs = Set(["missing"])
        XCTAssertThrowsError(try round.validate())
    }

    func testMixedRoundCanReuseAWordAcrossQuestionKinds() throws {
        let target = word("a", "apple", "苹果")
        var round = PracticeRound(kind: .mixed, questions: [
            PracticeQuestion(kind: .spelling, word: target, answer: "apple"),
            PracticeQuestion(kind: .sentence, word: target, blankedText: "An _____", answer: "apple")
        ])
        XCTAssertEqual(round.submit("apple"), .correct)
        XCTAssertNoThrow(try round.validate())
        XCTAssertTrue(round.advance())
        XCTAssertNoThrow(try round.validate())
        XCTAssertEqual(round.submit("apple"), .correct)
        XCTAssertNoThrow(try round.validate())
        XCTAssertEqual(round.creditedWordIDs, ["a"])
    }

    func testMixedRoundUsesOnlySelectedKinds() throws {
        let values = [
            word("a", "apple", "苹果"), word("b", "book", "书"),
            word("c", "cat", "猫"), word("d", "dog", "狗")
        ]
        let round = try PracticeEngine.make(
            kind: .mixed,
            words: values,
            limit: 10,
            mixedKinds: [.meaning]
        )
        XCTAssertFalse(round.questions.isEmpty)
        XCTAssertTrue(round.questions.allSatisfy { $0.kind == .meaning })
    }

    func testMixedRoundDoesNotFallbackToUnselectedKindsWhenMaterialIsMissing() throws {
        let values = [
            word("a", "an", "一"), word("b", "be", "是"),
            word("c", "do", "做"), word("d", "go", "走")
        ]
        XCTAssertThrowsError(try PracticeEngine.make(
            kind: .mixed,
            words: values,
            mixedKinds: [.completion]
        ))
    }

    func testMixedKindPreferenceEncodingRoundTripsAndRejectsMixedKind() {
        let selected: Set<PracticeKind> = [.spelling, .listening, .mixed]
        let encoded = PracticeEngine.encodeMixedKinds(selected)
        XCTAssertEqual(PracticeEngine.decodeMixedKinds(encoded), [.listening, .spelling])
        XCTAssertEqual(PracticeEngine.decodeMixedKinds(""), PracticeEngine.defaultMixedKinds)
    }

    func testEveryExerciseRoundCompletesAndKeepsCreditsStable() throws {
        var values = [word("a", "radiate", "辐射"), word("b", "wander", "漫游"), word("c", "anchor", "锚"), word("d", "gentle", "温和的"), word("e", "object", "反对"), word("f", "obtain", "获得")]
        for index in values.indices {
            values[index].audioHash = "audio-" + values[index].id
            values[index].usages = [WordUsage(key: "v", pos: "v.", phonetic: nil, senses: [WordSense(key: "s", meaning: values[index].meaning, primary: true, examples: [WordExample(text: "We \(values[index].word) today.", translation: nil)])])]
        }
        for kind in PracticeKind.allCases {
            var round = try PracticeEngine.make(kind: kind, words: values)
            try round.validate()
            while let question = round.current {
                switch question.kind {
                case .meaning, .listening:
                    let wrong = try XCTUnwrap(question.choices.first { $0.word.id != question.word.id })
                    XCTAssertEqual(round.choose(wrong.id), .incorrect)
                    try round.validate()
                    XCTAssertEqual(round.choose(question.word.id), .correct)
                case .matching:
                    for pair in question.pairs { XCTAssertTrue(round.match(englishID: pair.id, meaningID: pair.id).accepted) }
                case .completion, .sentence, .spelling:
                    XCTAssertEqual(round.submit("wrong-answer"), .incorrect)
                    XCTAssertEqual(round.submit(try XCTUnwrap(question.answer)), .correct)
                case .mixed: XCTFail("Unresolved mixed kind")
                }
                try round.validate()
                XCTAssertTrue(round.advance())
                try round.validate()
            }
            XCTAssertTrue(round.isComplete)
        }
    }
    private func word(_ id: String, _ english: String, _ meaning: String, inactive: Bool? = nil) -> MobileWord {
        MobileWord(id: id, revision: "r1", catalogID: "catalog", word: english, meaning: meaning, pos: "n.", phonetic: "", category: "required", unit: "Unit 1", printedPage: 1, order: Int(id.unicodeScalars.first?.value ?? 0), usages: [], parts: [], audioHash: nil, audioUsageKey: nil, audioNote: nil, packageID: nil, inactive: inactive)
    }
}
