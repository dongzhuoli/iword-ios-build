import Foundation

/// Conservative, offline gloss matching. No sentence translation or remote inference.
/// Never use substring similarity: “不反对” must not match “反对”, nor “光” match “发光”.
enum SpokenMeaning {
    private static let equivalentGroups: [[String]] = [
        ["反对", "不赞成"], ["同意", "赞成"], ["获得", "得到", "取得"],
        ["维持", "保持"], ["废弃", "淘汰"], ["过时", "陈旧"],
        ["义务", "责任"], ["目的", "目标", "宗旨"], ["帮助", "协助"],
        ["发光", "发出光"], ["辐射", "放射"], ["根本", "基本"],
        ["认出", "识别", "辨认"], ["明显", "显然"], ["旅行", "旅程"]
    ]

    static func normalized(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip only answer wrappers, never negation or meaning-bearing characters.
        for prefix in ["这个单词的意思是", "这个词的意思是", "它的意思是", "意思是"] {
            if value.hasPrefix(prefix) { value.removeFirst(prefix.count); break }
        }
        if value.hasSuffix("的意思") { value.removeLast(3) }
        let punctuation = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)
        value = String(value.unicodeScalars.filter { !punctuation.contains($0) })
        if value.count > 2 && value.hasSuffix("的") { value.removeLast() }
        return value
    }

    static func matches(_ transcript: String, word: MobileWord) -> Bool {
        // Limit input before normalization; empty/long utterances are not useful short glosses.
        guard transcript.count <= 200 else { return false }
        let answer = normalized(transcript)
        guard !answer.isEmpty else { return false }
        let meanings = [word.meaning] + word.usages.flatMap { $0.senses.map { $0.meaning } }
        let separators = CharacterSet(charactersIn: "，,；;、/\n：:")
        let aliases = meanings.flatMap { text -> [String] in
            // Parentheses supply qualifications, not separate answers; remove only paired notes.
            let clean = text.replacingOccurrences(of: "[（(][^（）()]*[）)]", with: "", options: .regularExpression)
            return [normalized(text), normalized(clean)] + clean.components(separatedBy: separators).map(normalized)
        }.filter { !$0.isEmpty }
        func accepts(_ candidate: String) -> Bool {
            if aliases.contains(candidate) { return true }
            return equivalentGroups.contains { group in
                let values = group.map(normalized)
                return values.contains(candidate) && aliases.contains(where: { values.contains($0) })
            }
        }
        if accepts(answer) { return true }
        // More than one spoken gloss is allowed only when every clause is valid.
        let clauses = transcript.components(separatedBy: CharacterSet(charactersIn: "，,；;、")).map(normalized).filter { !$0.isEmpty }
        return clauses.count > 1 && clauses.allSatisfy { accepts($0) }
    }

    /// Matching is auxiliary evidence. Self-rating remains explicit after reveal.
    static func submit(_ transcript: String, to step: inout StudyStep) -> Bool? {
        guard step.kind == "recall", !step.revealed, (step.spokenAttempts ?? 0) < 2,
              !normalized(transcript).isEmpty else { return nil }
        let correct = matches(transcript, word: step.word)
        step.spokenAttempts = (step.spokenAttempts ?? 0) + 1
        step.spokenTranscript = String(transcript.prefix(200))
        step.spokenCorrect = correct
        if correct || step.spokenAttempts == 2 { step.revealed = true }
        return correct
    }

    static func valid(_ step: StudyStep) -> Bool {
        let count = step.spokenAttempts ?? 0
        guard (0...2).contains(count), (step.spokenTranscript?.count ?? 0) <= 200 else { return false }
        if count == 0 { return step.spokenTranscript == nil && step.spokenCorrect == nil }
        guard step.kind == "recall", let transcript = step.spokenTranscript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, step.spokenCorrect != nil else { return false }
        return (step.spokenCorrect != true && count != 2) || step.revealed
    }
}
