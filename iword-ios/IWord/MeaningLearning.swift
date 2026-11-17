import Foundation
import IWordDomain

struct MeaningChoice: Codable, Equatable, Identifiable {
    var id: String
    var meaning: String
}

/// Meaning recognition is scaffolding, never an independent recall or mastery credit.
/// Examples come from the installed content; unavailable context is omitted, not invented.
enum MeaningLearning {
    static func coreMeaning(_ word: MobileWord) -> String {
        let senses = word.usages.flatMap { $0.senses }
        let selected = senses.first(where: { $0.primary == true }) ?? senses.first
        let text = selected?.meaning.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = text.isEmpty ? word.meaning : text
        let first = source.components(separatedBy: CharacterSet(charactersIn: "；;\n")).first ?? source
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func context(_ word: MobileWord) -> WordExample? {
        let senses = word.usages.flatMap { $0.senses }
        let primary = senses.first(where: { $0.primary == true }) ?? senses.first
        return primary?.examples?.first(where: { !$0.text.isEmpty })
    }

    static func cue(_ word: MobileWord, level: Int) -> String {
        if level >= 2 { return coreMeaning(word) }
        if let example = context(word), !example.translation.orEmpty.isEmpty {
            return "想想这个场景：" + example.translation.orEmpty
        }
        if let example = context(word) { return "想想这个搭配：" + example.text }
        return "词性：" + (word.pos.isEmpty ? "先想一个大致意思，也可以直接看答案。" : word.pos + "。想不起就看看答案。")
    }

    static func choices(for word: MobileWord, candidates: [MobileWord]) -> [MeaningChoice] {
        let answer = coreMeaning(word)
        guard !answer.isEmpty else { return [] }
        var seen: Set<String> = [answer]
        var values = [MeaningChoice(id: word.id, meaning: answer)]
        for candidate in candidates.sorted(by: { $0.id < $1.id }) where candidate.id != word.id && candidate.word != word.word {
            let meaning = coreMeaning(candidate)
            // Reject exact and overlapping glosses to avoid two plausible answers.
            guard !meaning.isEmpty, seen.allSatisfy({ !$0.contains(meaning) && !meaning.contains($0) }) else { continue }
            seen.insert(meaning); values.append(MeaningChoice(id: candidate.id, meaning: meaning))
            if values.count == 3 { break }
        }
        // A one-option question supplies no useful discrimination. Skip it.
        return values.count >= 2 ? values.shuffled() : []
    }

    static func step(_ word: MobileWord, kind: String, retry: Int = 0, relearning: Bool = false, choices: [MeaningChoice]? = nil) -> StudyStep {
        var result = StudyStep(word: word, kind: kind, retry: retry)
        result.meaningEvidenceVersion = 3; result.relearning = relearning
        result.meaningChoices = choices; result.recognitionMistakes = 0
        return result
    }

    static func needsSupport(_ progress: WordProgress?) -> Bool {
        guard let progress, progress.learned else { return true }
        return progress.latestHinted || progress.latestRating == .forgot || progress.latestRating == .hint || progress.latestRating == nil
    }

    static func steps(words: [MobileWord], state: LocalState, retry: Int = 0) -> [StudyStep] {
        var result: [StudyStep] = [], recalls: [StudyStep] = []
        var seen: Set<String> = []
        for word in words where seen.insert(StudySession.wordKey(word)).inserted {
            if state.progress[word.id]?.learned != true || retry > 0 {
                result.append(step(word, kind: "learn", retry: retry, relearning: state.progress[word.id]?.learned == true))
                let options = choices(for: word, candidates: state.availableWords)
                if !options.isEmpty { result.append(step(word, kind: "recognition", retry: retry, choices: options)) }
            }
            recalls.append(step(word, kind: "recall", retry: retry))
        }
        // Other words intervene between supported recognition and unaided recall.
        return (result + recalls).map { AssociationLearning.decorate($0, state: state) }
    }

    static func followUp(after step: StudyStep, session: StudySession, state: LocalState) -> [StudyStep] {
        guard step.kind == "recall", step.meaningFailure == true else { return [] }
        if state.profile.associationPlanStartedAt != nil {
            // One supported revisit, then leave the word until a later round.
            // Recognition/repeated immediate quizzes are not evidence of lasting recall.
            return [AssociationLearning.decorate(Self.step(step.word, kind: "learn", retry: step.retry + 1, relearning: true), state: state)]
        }
        let previous = session.steps.prefix(session.position).filter {
            $0.word.id == step.word.id && $0.kind == "recall" && ($0.meaningFailure == true || $0.hinted)
        }.count
        if previous == 0 { return steps(words: [step.word], state: state, retry: step.retry + 1) }
        return [Self.step(step.word, kind: "learn", retry: step.retry + 1, relearning: true)]
    }

    static func independent(_ step: StudyStep, rating: RecallRating) -> Bool {
        guard step.kind == "recall", [.easy, .slow].contains(rating), !step.hinted else { return false }
        if step.meaningEvidenceVersion == 3 { return step.spellingBeforeRecall != true }
        return !step.audioAssisted && step.spelling == nil
    }

    static func pauseNewWords(state: LocalState, now: Date) -> Bool {
        if let start = state.profile.gentleStartedAt, now < start.addingTimeInterval(3 * 86_400) { return true }
        return state.availableWords.filter { state.progress[$0.id]?.learned == true && needsSupport(state.progress[$0.id]) }.count >= 5
    }
}
