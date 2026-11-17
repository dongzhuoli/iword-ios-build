import Foundation

/// Thin model-facing commands. The actual write and the history credit are
/// deliberately owned by LearningModel.practiceCommand so a practice answer is
/// one transaction, not a UI-side counter followed by a second save.
extension LearningModel {
    func startPractice(
        _ kind: PracticeKind,
        unitID: String? = nil,
        mixedKinds: Set<PracticeKind> = PracticeEngine.defaultMixedKinds
    ) {
        let selectedUnitID = unitID
        practiceCommand("PRACTICE_STARTED") { draft in
            let learned = draft.availableWords.filter { draft.progress[$0.id]?.learned == true }
            let pool: [MobileWord]
            if let selectedUnitID {
                pool = VocabularyUnit.grouped(learned).first(where: { $0.id == selectedUnitID })?.words ?? []
            } else {
                pool = learned
            }
            let round = try PracticeEngine.make(kind: kind, words: pool, mixedKinds: mixedKinds)
            try round.validate()
            draft.profile.practiceRound = round
            var fields = [
                "practiceKind": kind.rawValue,
                "roundID": round.id,
                "questionCount": String(round.questions.count),
                "unitID": selectedUnitID ?? "all"
            ]
            if kind == .mixed { fields["mixedKinds"] = PracticeEngine.encodeMixedKinds(mixedKinds) }
            return fields
        }
    }

    func resumePractice() {
        practiceCommand("PRACTICE_RESUMED") { draft in
            guard var round = draft.profile.practiceRound, !round.isComplete else {
                throw ContentFailure(message: "没有可继续的练习。")
            }
            round.paused = false; try round.validate(); draft.profile.practiceRound = round
            return ["roundID": round.id, "position": String(round.position)]
        }
    }

    func pausePractice() {
        stopPracticeAudio()
        practiceCommand("PRACTICE_PAUSED") { draft in
            guard var round = draft.profile.practiceRound, !round.isComplete else {
                throw ContentFailure(message: "当前没有可暂停的练习。")
            }
            round.paused = true; try round.validate(); draft.profile.practiceRound = round
            return ["roundID": round.id, "position": String(round.position)]
        }
    }

    func endPractice() {
        stopPracticeAudio()
        practiceCommand("PRACTICE_ENDED") { draft in
            guard let round = draft.profile.practiceRound else { return [:] }
            draft.profile.practiceRound = nil
            return ["roundID": round.id, "position": String(round.position), "complete": String(round.isComplete)]
        }
    }

    func choosePractice(_ choiceID: String) {
        practiceCommand("PRACTICE_ANSWER") { draft in
            guard var round = draft.profile.practiceRound, let question = round.current else {
                throw ContentFailure(message: "这一轮练习已经结束。")
            }
            let result = round.choose(choiceID)
            guard result != .invalid else { throw ContentFailure(message: "该选项已不可用，请重新选择。") }
            try round.validate(); draft.profile.practiceRound = round
            return self.answerFields(round: round, question: question, result: result)
        }
    }

    func submitPractice(_ value: String) {
        practiceCommand("PRACTICE_ANSWER") { draft in
            guard var round = draft.profile.practiceRound, let question = round.current else {
                throw ContentFailure(message: "这一轮练习已经结束。")
            }
            let result = round.submit(value)
            guard result != .invalid else { throw ContentFailure(message: "当前题目不能这样作答。") }
            try round.validate(); draft.profile.practiceRound = round
            return self.answerFields(round: round, question: question, result: result)
        }
    }

    func matchPractice(englishID: String, meaningID: String) {
        practiceCommand("PRACTICE_ANSWER") { draft in
            guard var round = draft.profile.practiceRound, let question = round.current else {
                throw ContentFailure(message: "这一轮练习已经结束。")
            }
            let result = round.match(englishID: englishID, meaningID: meaningID)
            guard result != .invalid else { throw ContentFailure(message: "该配对已不可用，请重新选择。") }
            try round.validate(); draft.profile.practiceRound = round
            var fields = self.answerFields(round: round, question: question, result: result)
            fields["wordID"] = englishID
            return fields
        }
    }

    func advancePractice() {
        stopPracticeAudio()
        practiceCommand("PRACTICE_NEXT") { draft in
            guard var round = draft.profile.practiceRound, let question = round.current, question.completed else {
                throw ContentFailure(message: "请先完成当前题目。")
            }
            guard round.advance() else { throw ContentFailure(message: "当前题目尚未完成。") }
            try round.validate(); draft.profile.practiceRound = round
            return ["roundID": round.id, "questionID": question.id, "position": String(round.position), "complete": String(round.isComplete)]
        }
    }

    private func answerFields(round: PracticeRound, question: PracticeQuestion, result: PracticeAnswerResult) -> [String: String] {
        let after = round.current ?? question
        return [
            "roundID": round.id,
            "questionID": question.id,
            "wordID": question.word.id,
            "practiceKind": question.kind.rawValue,
            "correct": String(result.accepted),
            "completed": String(after.completed),
            "errors": String(after.errors),
            "firstAnswerCorrect": String(after.firstAnswerCorrect ?? false)
        ]
    }
}
