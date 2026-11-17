import XCTest
@testable import IWordDomain

final class SpellingRoundTests: XCTestCase {
    func testDecodedSpellingStateRejectsUnsafeIndicesAndCandidateSets() throws {
        let round = SpellingRound(word: "radiate")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(round)) as! [String: Any]
        object["position"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(SpellingRound.self, from: JSONSerialization.data(withJSONObject: object)))
        object["position"] = 0; object["candidateSets"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(SpellingRound.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testWrongChoiceStaysOnPositionAndCountsErrors() {
        var round = SpellingRound(
            word: "letter",
            candidateSets: [
                ["l", "a", "b", "c", "d", "e"],
                ["e", "a", "b", "c", "d", "f"],
                ["t", "a", "b", "c", "d", "f"],
                ["t", "g", "h", "i", "j", "k"],
                ["e", "l", "m", "n", "o", "p"],
                ["r", "s", "u", "v", "w", "x"]])

        XCTAssertEqual(round.chooseResult("a"), .incorrect(errorCount: 1))
        XCTAssertEqual(round.position, 0)
        XCTAssertEqual(round.errors, [1, 0, 0, 0, 0, 0])
        XCTAssertFalse(round.isComplete)
    }

    func testCorrectChoiceAdvancesAndRepeatedLettersUseNewSet() {
        var round = SpellingRound(word: "letter")
        let firstSet = round.candidates
        XCTAssertTrue(firstSet.contains("l"))

        XCTAssertEqual(round.chooseResult("l"), .correct(nextPosition: 1))
        XCTAssertNotEqual(round.candidates, firstSet)
        XCTAssertTrue(round.candidates.contains("e"))

        XCTAssertEqual(round.chooseResult("e"), .correct(nextPosition: 2))
        let firstT = round.candidates
        XCTAssertEqual(round.chooseResult("t"), .correct(nextPosition: 3))
        XCTAssertNotEqual(round.candidates, firstT)
        XCTAssertTrue(round.candidates.contains("t"))
    }

    func testGeneratedChoicesAreShuffledAndSeedReproducible() {
        let first = SpellingRound(word: "apple", seed: 1)
        let same = SpellingRound(word: "apple", seed: 1)
        let different = SpellingRound(word: "apple", seed: 2)
        let seededRounds = (1...32).map { SpellingRound(word: "apple", seed: UInt64($0)) }
        let answerPositions = Set(seededRounds.compactMap { $0.candidates.firstIndex(of: "a") })

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first.candidates, different.candidates)
        XCTAssertEqual(Set(first.candidates).count, 9)
        XCTAssertTrue(first.candidates.contains("a"))
        XCTAssertGreaterThanOrEqual(answerPositions.count, 4)
        XCTAssertTrue(answerPositions.contains(0))
        XCTAssertTrue(answerPositions.contains(where: { $0 > 0 }))
    }

    func testNonCandidateIsRejectedWithoutCountingAnError() {
        var round = SpellingRound(
            word: "go",
            candidateSets: [["g", "a", "b", "c", "d", "e"], ["o", "a", "b", "c", "d", "f"]])

        XCTAssertEqual(round.chooseResult("z"), .invalid)
        XCTAssertEqual(round.errors, [0, 0])
        XCTAssertFalse(round.choose("z"))
        XCTAssertEqual(round.errors, [0, 0])
    }

    func testCompletionResetAndCodableRoundTripPreserveProgress() throws {
        var round = SpellingRound(word: "go")
        _ = round.chooseResult("g")
        let wrong = round.candidates.first { $0 != "o" }!
        _ = round.chooseResult(wrong)

        let data = try JSONEncoder().encode(round)
        let restored = try JSONDecoder().decode(SpellingRound.self, from: data)
        XCTAssertEqual(restored, round)
        XCTAssertEqual(restored.position, 1)
        XCTAssertEqual(restored.errors, [0, 1])

        XCTAssertEqual(round.chooseResult("o"), .completed)
        XCTAssertTrue(round.isComplete)
        XCTAssertFalse(round.choose("o"))
        round.reset()
        XCTAssertEqual(round.position, 0)
        XCTAssertFalse(round.isComplete)
        XCTAssertEqual(round.errors, [0, 0])
    }

    func testMalformedProgressDoesNotDecode() throws {
        let round = SpellingRound(word: "go", seed: 11)
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(round), options: []) as! [String: Any]
        object["position"] = 99
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [])

        XCTAssertThrowsError(try JSONDecoder().decode(SpellingRound.self, from: malformed))
    }

    func testRepeatedLettersChangeDistractorMembership() {
        var round = SpellingRound(word: "letter", seed: 42)
        XCTAssertTrue(round.choose("l"))
        XCTAssertTrue(round.choose("e"))
        let firstT = Set(round.candidates)
        XCTAssertTrue(round.choose("t"))
        XCTAssertNotEqual(firstT, Set(round.candidates))
    }

    func testGeneratedRoundUsesNineUniqueChoicesPerPosition() {
        let round = SpellingRound(word: "book", seed: 17)
        XCTAssertEqual(round.candidates.count, 9)
        XCTAssertEqual(Set(round.candidates).count, 9)
        XCTAssertTrue(round.candidates.contains("b"))
    }

    func testSixChoiceArchivedRoundStillDecodesAndResets() throws {
        var old = SpellingRound(
            word: "go",
            candidateSets: [["g", "a", "b", "c", "d", "e"], ["o", "a", "b", "c", "d", "f"]])
        XCTAssertEqual(old.candidates.count, 6)
        _ = old.choose("g")
        let restored = try JSONDecoder().decode(SpellingRound.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(restored.candidates.count, 6)
        XCTAssertEqual(restored.position, 1)
        old.reset()
        XCTAssertEqual(old.position, 0)
        XCTAssertEqual(old.candidates.count, 6)
    }
}
