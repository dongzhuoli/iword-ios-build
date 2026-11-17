import Foundation

/// The requested exercise family. `mixed` is resolved into one of the six
/// concrete kinds when a round is made, so an unfinished task is stable.
enum PracticeKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case meaning, matching, completion, sentence, listening, spelling, mixed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .meaning: return "英选中义"
        case .matching: return "中英配对"
        case .completion: return "字母补全"
        case .sentence: return "例句填空"
        case .listening: return "听音选义"
        case .spelling: return "中译英拼写"
        case .mixed: return "混合练习"
        }
    }

    /// The concrete exercise kinds available inside a mixed round. Keep this
    /// separate from `allCases` so the mixed selector never includes itself.
    static let mixedCases: [PracticeKind] = [
        .meaning, .matching, .completion, .sentence, .listening, .spelling
    ]
}

struct PracticeChoice: Codable, Equatable, Identifiable {
    var id: String
    var word: MobileWord
}

struct PracticeMatchPair: Codable, Equatable, Identifiable {
    var id: String { word.id }
    var word: MobileWord
}

struct PracticeQuestion: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: PracticeKind
    /// Every word is copied into the question. Content updates therefore cannot
    /// change an answer in a task which has already been started.
    var word: MobileWord
    var choices: [PracticeChoice] = []
    var pairs: [PracticeMatchPair] = []
    /// Chinese-column order is retained independently of the English column.
    /// Older archives fall back to a stable ID ordering.
    var meaningOrderIDs: [String]?
    var blankedText: String?
    var answer: String?
    var letterChoices: [String] = []
    var answerHint: String?
    var selectedChoiceID: String?
    var matchedWordIDs: Set<String> = []
    var errors = 0
    var firstAnswerCorrect: Bool?
    var completed = false
    /// `nil` is retained for archives written before automatic answer reveals
    /// existed. `true` is set only when the current implementation reveals a
    /// text-entry answer after three misses.
    var answerRevealed: Bool? = nil

    var referencedWords: [MobileWord] { [word] + choices.map(\.word) + pairs.map(\.word) }
    var isTextEntry: Bool { kind == .sentence || kind == .spelling }
    var orderedPairs: [PracticeMatchPair] {
        let ids = Set(pairs.map(\.word.id))
        if let meaningOrderIDs, meaningOrderIDs.count == pairs.count, Set(meaningOrderIDs) == ids {
            let byID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.word.id, $0) })
            return meaningOrderIDs.compactMap { byID[$0] }
        }
        return pairs.sorted { $0.word.id < $1.word.id }
    }
}

enum PracticeAnswerResult: Equatable {
    case invalid
    case incorrect
    case correct
    case completed

    var accepted: Bool { self == .correct || self == .completed }
}

struct PracticeRound: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: PracticeKind
    var questions: [PracticeQuestion]
    var position = 0
    var paused = false
    var creditedWordIDs: Set<String> = []

    var current: PracticeQuestion? { position >= 0 && position < questions.count ? questions[position] : nil }
    var isComplete: Bool { position >= questions.count }
    var referencedWords: [MobileWord] {
        var seen = Set<String>()
        return questions.flatMap(\.referencedWords).filter { seen.insert($0.id).inserted }
    }

    /// Reject malformed imported state before it is allowed to become an active
    /// task. This also ensures backup code can trust `referencedWords`.
    func validate() throws {
        guard position >= 0, position <= questions.count,
              Set(questions.map(\.id)).count == questions.count else {
            throw ContentFailure(message: "练习存档的位置或题目编号无效。")
        }
        let completedWords = Set(questions.flatMap { question -> [String] in
            if question.kind == .matching { return Array(question.matchedWordIDs) }
            // Text-entry questions become terminal after the third miss so the
            // learner can reveal the answer and move on, but that outcome must
            // never become a practice credit.
            return question.completed && question.answerRevealed != true ? [question.word.id] : []
        })
        guard creditedWordIDs == completedWords else {
            throw ContentFailure(message: "练习存档包含不属于本轮的完成记录。")
        }
        for (index, question) in questions.enumerated() {
            let pairIDs = Set(question.pairs.map(\.word.id))
            let optionMeanings = Set(question.choices.map {
                $0.word.meaning.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            guard !question.word.id.isEmpty,
                  question.errors >= 0,
                  question.selectedChoiceID.map({ id in question.choices.contains(where: { $0.id == id }) }) ?? true,
                  question.matchedWordIDs.isSubset(of: pairIDs),
                  !(index < position && !question.completed),
                  !(index > position && question.completed),
                  !(position == questions.count && !question.completed) else {
                throw ContentFailure(message: "练习存档的题目状态或完成进度无效。")
            }
            if question.answerRevealed == true {
                guard question.isTextEntry, question.completed, question.errors >= 3,
                      question.firstAnswerCorrect == false else {
                    throw ContentFailure(message: "练习题揭晓状态无效。")
                }
            }
            switch question.kind {
            case .meaning, .listening:
                guard question.choices.count == 4, optionMeanings.count == 4,
                      question.choices.contains(where: { $0.word.id == question.word.id }) else {
                    throw ContentFailure(message: "选择题没有唯一且完整的正确选项。")
                }
                if question.kind == .listening, question.word.audioHash?.trimmed.isEmpty != false {
                    throw ContentFailure(message: "听音题缺少本地录音。")
                }
            case .matching:
                guard question.pairs.count >= 2, pairIDs.contains(question.word.id),
                      question.completed == (question.matchedWordIDs.count == question.pairs.count),
                      question.matchedWordIDs.isSubset(of: creditedWordIDs) else {
                    throw ContentFailure(message: "配对题完成记录不完整。")
                }
                if let order = question.meaningOrderIDs {
                    guard order.count == question.pairs.count, Set(order) == pairIDs else {
                        throw ContentFailure(message: "配对题中文顺序无效。")
                    }
                }
            case .completion:
                guard let answer = question.answer, !answer.isEmpty,
                      question.letterChoices.count == 9,
                      question.letterChoices.contains(where: { $0.caseInsensitiveCompare(answer) == .orderedSame }),
                      Set(question.letterChoices.map { $0.lowercased() }).count == question.letterChoices.count,
                      question.letterChoices.allSatisfy({ $0.count == answer.count }) else {
                    throw ContentFailure(message: "补全题缺少九个唯一的候选字母组。")
                }
            case .sentence, .spelling:
                guard let answer = question.answer, !answer.isEmpty else {
                    throw ContentFailure(message: "输入题缺少答案。")
                }
            case .mixed:
                throw ContentFailure(message: "混合练习不能作为未解析的题目保存。")
            }
            if question.kind != .matching, question.completed && question.answerRevealed != true
                && !creditedWordIDs.contains(question.word.id) {
                throw ContentFailure(message: "练习题完成记录不一致。")
            }
            if (question.errors > 0 || question.completed), question.firstAnswerCorrect == nil {
                throw ContentFailure(message: "练习题缺少首次作答记录。")
            }
        }
    }

    mutating func choose(_ choiceID: String) -> PracticeAnswerResult {
        guard !isComplete, !questions[position].completed,
              let selected = questions[position].choices.first(where: { $0.id == choiceID }) else { return .invalid }
        var question = questions[position]
        question.selectedChoiceID = choiceID
        let correct = selected.word.id == question.word.id
        if question.firstAnswerCorrect == nil { question.firstAnswerCorrect = correct }
        if correct {
            question.completed = true
            creditedWordIDs.insert(question.word.id)
            questions[position] = question
            return .correct
        }
        question.errors += 1; questions[position] = question
        return .incorrect
    }

    mutating func submit(_ raw: String) -> PracticeAnswerResult {
        guard !isComplete, !questions[position].completed,
              let answer = questions[position].answer else { return .invalid }
        var question = questions[position]
        // Case is not a spelling distinction, but the exact example inflection
        // is: `radiate` must not satisfy an example whose answer is `radiates`.
        let correct = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(answer) == .orderedSame
        if question.firstAnswerCorrect == nil { question.firstAnswerCorrect = correct }
        if correct {
            question.completed = true; creditedWordIDs.insert(question.word.id)
            questions[position] = question; return .correct
        }
        question.errors += 1
        if question.isTextEntry && question.errors >= 3 {
            // Keep this question terminal, but deliberately leave the word out
            // of creditedWordIDs. The UI can reveal the answer and advance.
            question.completed = true; question.answerRevealed = true
        }
        questions[position] = question
        return .incorrect
    }

    mutating func match(englishID: String, meaningID: String) -> PracticeAnswerResult {
        guard !isComplete else { return .invalid }
        var question = questions[position]
        guard question.kind == .matching,
              question.pairs.contains(where: { $0.word.id == englishID }),
              question.pairs.contains(where: { $0.word.id == meaningID }),
              !question.matchedWordIDs.contains(englishID), !question.matchedWordIDs.contains(meaningID) else { return .invalid }
        let correct = englishID == meaningID
        if question.firstAnswerCorrect == nil { question.firstAnswerCorrect = correct }
        guard correct else { question.errors += 1; questions[position] = question; return .incorrect }
        question.matchedWordIDs.insert(englishID); creditedWordIDs.insert(englishID)
        if question.matchedWordIDs.count == question.pairs.count { question.completed = true }
        questions[position] = question
        return question.completed ? .completed : .correct
    }

    mutating func advance() -> Bool {
        guard !isComplete, questions[position].completed else { return false }
        position += 1; return true
    }
}

enum PracticeEngine {
    static let mixedKindsDefaultsKey = "practice.mixedKinds"

    static var defaultMixedKinds: Set<PracticeKind> { Set(PracticeKind.mixedCases) }

    static var defaultMixedKindsValue: String {
        encodeMixedKinds(defaultMixedKinds)
    }

    static func encodeMixedKinds(_ kinds: Set<PracticeKind>) -> String {
        PracticeKind.mixedCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
    }

    static func decodeMixedKinds(_ value: String) -> Set<PracticeKind> {
        let values = Set(value.split(separator: ",").compactMap { PracticeKind(rawValue: String($0)) })
            .intersection(defaultMixedKinds)
        return values.isEmpty ? defaultMixedKinds : values
    }

    static func make(
        kind: PracticeKind,
        words: [MobileWord],
        limit: Int = 10,
        mixedKinds: Set<PracticeKind> = PracticeEngine.defaultMixedKinds
    ) throws -> PracticeRound {
        let pool = uniqueActive(words)
        guard !pool.isEmpty else { throw ContentFailure(message: "没有可用于练习的已学词。") }
        let cap = max(1, limit)
        let questions: [PracticeQuestion]
        if kind == .matching {
            questions = [try matching(pool: pool, limit: min(6, max(2, cap)))]
        } else if kind == .mixed {
            questions = try mixed(pool, limit: cap, kinds: mixedKinds)
        } else {
            questions = try concrete(kind, pool: pool, limit: cap)
        }
        guard !questions.isEmpty else { throw ContentFailure(message: "这些已学词暂时没有足够可靠的练习材料。") }
        return PracticeRound(kind: kind, questions: questions)
    }

    private static func concrete(_ kind: PracticeKind, pool: [MobileWord], limit: Int) throws -> [PracticeQuestion] {
        switch kind {
        case .meaning: return try meanings(pool, limit: limit)
        case .matching: return [try matching(pool: pool, limit: min(6, max(2, limit)))]
        case .completion: return completions(pool, limit: limit)
        case .sentence: return sentences(pool, limit: limit)
        case .listening: return try listenings(pool, limit: limit)
        case .spelling: return spellings(pool, limit: limit)
        case .mixed: return []
        }
    }

    private static func meanings(_ pool: [MobileWord], limit: Int) throws -> [PracticeQuestion] {
        let usable = uniqueMeanings(pool.filter { !$0.meaning.trimmed.isEmpty })
        guard normalizedMeanings(usable).count >= 4 else { throw ContentFailure(message: "至少需要四个词义不同的已学词，才能出英选中义。") }
        return usable.shuffled().compactMap { word in
            let distractors = usable.filter { normalize($0.meaning) != normalize(word.meaning) }.shuffled().prefix(3)
            guard distractors.count == 3 else { return nil }
            return PracticeQuestion(kind: .meaning, word: word,
                                    choices: ([word] + Array(distractors)).map { PracticeChoice(id: $0.id, word: $0) }.shuffled())
        }.prefix(limit).map { $0 }
    }

    private static func matching(pool: [MobileWord], limit: Int) throws -> PracticeQuestion {
        let values = uniqueMeanings(pool).shuffled().prefix(min(6, limit)).map { PracticeMatchPair(word: $0) }
        guard values.count >= 2 else { throw ContentFailure(message: "至少需要两个词义不同的已学词，才能中英配对。") }
        var meaningOrder = values.map(\.word.id).shuffled()
        if meaningOrder == values.map(\.word.id), meaningOrder.count > 1 { meaningOrder.append(meaningOrder.removeFirst()) }
        return PracticeQuestion(kind: .matching, word: values[0].word, pairs: values, meaningOrderIDs: meaningOrder)
    }

    private static func completions(_ pool: [MobileWord], limit: Int) -> [PracticeQuestion] {
        pool.shuffled().compactMap { word in
            guard let range = blankRange(in: word.word) else { return nil }
            let answer = String(word.word[range])
            let template = word.word.replacingCharacters(in: range, with: String(repeating: "_", count: answer.count))
            return PracticeQuestion(kind: .completion, word: word, blankedText: template, answer: answer,
                                    letterChoices: completionChoices(answer).shuffled(), answerHint: "补全缺少的字母")
        }.prefix(limit).map { $0 }
    }

    private static func sentences(_ pool: [MobileWord], limit: Int) -> [PracticeQuestion] {
        pool.shuffled().compactMap { word in
            guard let material = sentenceMaterial(for: word) else { return nil }
            return PracticeQuestion(kind: .sentence, word: word, blankedText: material.template,
                                    answer: material.form, answerHint: material.note)
        }.prefix(limit).map { $0 }
    }

    private static func listenings(_ pool: [MobileWord], limit: Int) throws -> [PracticeQuestion] {
        let audio = pool.filter { !($0.audioHash?.trimmed.isEmpty ?? true) }
        guard audio.count >= 1 else { throw ContentFailure(message: "已学词中没有本地原书录音，暂不能听音练习。") }
        guard normalizedMeanings(pool).count >= 4 else { throw ContentFailure(message: "至少需要四个词义不同的已学词，才能听音选义。") }
        return audio.shuffled().compactMap { word in
            let distractors = uniqueMeanings(pool.filter { normalize($0.meaning) != normalize(word.meaning) }).shuffled().prefix(3)
            guard distractors.count == 3 else { return nil }
            return PracticeQuestion(kind: .listening, word: word,
                                    choices: ([word] + Array(distractors)).map { PracticeChoice(id: $0.id, word: $0) }.shuffled())
        }.prefix(limit).map { $0 }
    }

    private static func spellings(_ pool: [MobileWord], limit: Int) -> [PracticeQuestion] {
        pool.shuffled().compactMap { word in
            let value = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil, !word.meaning.trimmed.isEmpty else { return nil }
            let first = value.prefix(1).uppercased()
            let ambiguous = pool.contains { other in
                other.id != word.id && normalize(other.meaning) == normalize(word.meaning)
                    && other.pos == word.pos && other.word.count == value.count
                    && other.word.prefix(1).uppercased() == first
                    && other.word.caseInsensitiveCompare(value) != .orderedSame
            }
            guard !ambiguous else { return nil }
            return PracticeQuestion(kind: .spelling, word: word, answer: value,
                                    answerHint: "首字母 \(first) · \(value.count) 个字母")
        }.prefix(limit).map { $0 }
    }

    private static func mixed(_ pool: [MobileWord], limit: Int, kinds: Set<PracticeKind>) throws -> [PracticeQuestion] {
        let selected = PracticeKind.mixedCases.filter(kinds.contains)
        guard !selected.isEmpty else { throw ContentFailure(message: "混合练习至少需要选择一种题型。") }

        // Build candidates only for selected kinds. A kind with insufficient
        // material is skipped; it must never cause an unselected kind to be
        // added as a fallback.
        var candidates = selected.reduce(into: [PracticeKind: [PracticeQuestion]]()) { result, kind in
            result[kind] = (try? concrete(kind, pool: pool, limit: limit)) ?? []
        }
        var output: [PracticeQuestion] = []
        var pendingKinds = selected.shuffled()
        while output.count < limit, !pendingKinds.isEmpty {
            for index in pendingKinds.indices.reversed() {
                let kind = pendingKinds[index]
                guard var values = candidates[kind], !values.isEmpty else {
                    pendingKinds.remove(at: index)
                    continue
                }
                output.append(values.removeFirst())
                candidates[kind] = values
                if output.count == limit { break }
                if values.isEmpty { pendingKinds.remove(at: index) }
            }
        }
        guard !output.isEmpty else { throw ContentFailure(message: "所选混合题型没有足够可靠的练习材料。") }
        return output
    }

    private static func uniqueActive(_ words: [MobileWord]) -> [MobileWord] {
        var ids = Set<String>()
        return words.filter { $0.inactive != true && ids.insert($0.id).inserted }
    }
    private static func normalize(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static func normalizedMeanings(_ words: [MobileWord]) -> Set<String> { Set(words.map { normalize($0.meaning) }.filter { !$0.isEmpty }) }
    private static func uniqueMeanings(_ words: [MobileWord]) -> [MobileWord] {
        var values = Set<String>(); return words.filter { !normalize($0.meaning).isEmpty && values.insert(normalize($0.meaning)).inserted }
    }
    private static func blankRange(in word: String) -> Range<String.Index>? {
        let letters = word.indices.filter { word[$0].isLetter }
        guard letters.count >= 3 else { return nil }
        let length = min(3, max(1, letters.count / 3)); let startOffset = max(1, (letters.count - length) / 2)
        guard startOffset + length < letters.count else { return nil }
        return letters[startOffset]..<letters[startOffset + length]
    }
    private static func completionChoices(_ answer: String) -> [String] {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let common = ["a", "e", "i", "o", "u", "r", "s", "t", "n", "l", "an", "er", "re", "or", "in", "ed", "ar", "ra", "di", "at", "ti", "on", "ion", "ing", "ate", "ent", "ant", "rad", "rea", "ter"]
        var values = [answer]
        for candidate in common.filter({ $0.count == answer.count }).shuffled() where values.count < 9 {
            if !values.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { values.append(candidate) }
        }
        while values.count < 9 {
            let candidate = String((0..<answer.count).map { _ in alphabet.randomElement()! })
            if !values.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { values.append(candidate) }
        }
        return values
    }
    private static func sentenceMaterial(for word: MobileWord) -> (template: String, form: String, note: String)? {
        guard !word.word.trimmed.isEmpty else { return nil }
        for example in word.usages.flatMap({ $0.senses }).flatMap({ $0.examples ?? [] }) where !example.text.contains("~") {
            if let value = sentenceMaterial(word: word, example: example) { return value }
        }
        return nil
    }
    private static func sentenceMaterial(word: MobileWord, example: WordExample) -> (template: String, form: String, note: String)? {
        let forms = forms(for: word.word)
        let pattern = "(?i)\\b(" + forms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = example.text as NSString
        let matches = expression.matches(in: example.text, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first,
              matches.allSatisfy({ ns.substring(with: $0.range).caseInsensitiveCompare(ns.substring(with: first.range)) == .orderedSame }) else { return nil }
        let form = ns.substring(with: first.range)
        var template = example.text
        for match in matches.reversed() {
            let range = Range(match.range, in: template)!
            template.replaceSubrange(range, with: String(repeating: "_", count: form.count))
        }
        let note = form.caseInsensitiveCompare(word.word) == .orderedSame ? "按原句填写" : "原句使用了词条的实际变形。"
        return (template, form, note)
    }
    private static func forms(for lemma: String) -> [String] {
        let lower = lemma.lowercased()
        let irregular = ["be": ["am", "is", "are", "was", "were", "been", "being"], "go": ["goes", "went", "gone", "going"], "do": ["does", "did", "done", "doing"], "have": ["has", "had", "having"], "make": ["makes", "made", "making"], "take": ["takes", "took", "taken", "taking"], "write": ["writes", "wrote", "written", "writing"], "run": ["runs", "ran", "running"]]
        var result: Set<String> = [lower]
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) { result.insert(String(lower.dropLast()) + "ies"); result.insert(String(lower.dropLast()) + "ied") }
        else if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("z") || lower.hasSuffix("ch") || lower.hasSuffix("sh") { result.insert(lower + "es"); result.insert(lower + "ed") }
        else { result.insert(lower + "s"); result.insert(lower.hasSuffix("e") ? lower + "d" : lower + "ed") }
        if lower.hasSuffix("e") { result.insert(String(lower.dropLast()) + "ing") } else { result.insert(lower + "ing") }
        for value in irregular[lower] ?? [] { result.insert(value) }
        return Array(result)
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
