import Foundation

/// The outcome of selecting one of the candidate letters.
public enum SpellingChoiceResult: Equatable {
    case invalid
    case incorrect(errorCount: Int)
    case correct(nextPosition: Int)
    case completed
}

/// State for the optional spelling exercise.
///
/// Candidate sets are persisted so a resumed task shows exactly the same
/// choices. The default generator uses system randomness; a seed or explicit
/// candidate sets can be supplied for reproducible tests.
public struct SpellingRound: Codable, Equatable {
    public let word: String
    public let letters: [Character]
    public private(set) var position: Int
    public private(set) var candidates: [Character]
    public private(set) var errors: [Int]
    public private(set) var isComplete: Bool

    private let candidateSets: [[Character]]

    /// The correctly filled prefix, convenient for text-field-free views.
    public var filled: String {
        String(letters.prefix(position))
    }

    /// Candidate letters as one-character strings for SwiftUI lists.
    public var choices: [String] {
        candidates.map(String.init)
    }

    public init(word: String, candidateSets: [[Character]]? = nil, seed: UInt64? = nil) {
        let normalized = word.lowercased()
        let letters = Array(normalized)
        precondition(!letters.isEmpty, "SpellingRound requires a non-empty word")

        let sets = candidateSets ?? Self.makeCandidateSets(for: letters, seed: seed)
        Self.validate(word: normalized, letters: letters, candidateSets: sets)

        self.word = normalized
        self.letters = letters
        self.position = 0
        self.candidateSets = sets
        self.candidates = sets[0]
        self.errors = Array(repeating: 0, count: letters.count)
        self.isComplete = false
    }

    /// Selects a candidate. Wrong choices stay on the current position;
    /// correct choices advance and replace the candidate set.
    @discardableResult
    public mutating func chooseResult(_ letter: Character) -> SpellingChoiceResult {
        guard !isComplete else { return .completed }
        let lowered = Array(String(letter).lowercased())
        guard lowered.count == 1, let normalized = lowered.first,
              candidates.contains(normalized) else { return .invalid }
        guard normalized == letters[position] else {
            errors[position] += 1
            return .incorrect(errorCount: errors[position])
        }

        position += 1
        if position == letters.count {
            isComplete = true
            candidates = []
            return .completed
        }
        candidates = candidateSets[position]
        return .correct(nextPosition: position)
    }

    /// String-facing convenience used by app models. A true result means the
    /// selected letter was correct and the round advanced (or completed).
    @discardableResult
    public mutating func choose(_ letter: String) -> Bool {
        guard !isComplete else { return false }
        let characters = Array(letter)
        guard characters.count == 1 else {
            return false
        }
        switch chooseResult(characters[0]) {
        case .invalid, .incorrect:
            return false
        case .correct, .completed:
            return true
        }
    }

    /// Starts the same word again while retaining the persisted candidate sets.
    public mutating func reset() {
        position = 0
        candidates = candidateSets[0]
        errors = Array(repeating: 0, count: letters.count)
        isComplete = false
    }

    private static func makeCandidateSets(for letters: [Character], seed: UInt64?) -> [[Character]] {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var generator = SplitMix64(seed: seed ?? UInt64.random(in: UInt64.min ... UInt64.max))
        var result: [[Character]] = []
        for (index, correct) in letters.enumerated() {
            var distractors = alphabet.filter { $0 != correct }
            distractors.shuffle(using: &generator)
            var set = [correct] + Array(distractors.prefix(8))
            set.shuffle(using: &generator)
            if index > 0 && letters[index - 1] == correct {
                while Set(set) == Set(result[index - 1]) {
                    let replacement = alphabet.first { !set.contains($0) }!
                    set[set.firstIndex { $0 != correct }!] = replacement
                    set.shuffle(using: &generator)
                }
            }
            result.append(set)
        }
        return result
    }

    private static func validate(word: String, letters: [Character], candidateSets: [[Character]]) {
        precondition(!letters.isEmpty, "SpellingRound requires a non-empty word")
        precondition(Array(word) == letters, "Word and letter state must agree")
        precondition(candidateSets.count == letters.count, "One candidate set is required per letter")
        for (index, set) in candidateSets.enumerated() {
            precondition(set.count == 6 || set.count == 9, "Each spelling candidate set must contain six or nine letters")
            precondition(Set(set).count == set.count, "Spelling candidates must be unique")
            precondition(set.contains(letters[index]), "Each set must contain the correct letter")
        }
    }

    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case word
        case letters
        case position
        case candidates
        case errors
        case isComplete
        case candidateSets
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(word, forKey: .word)
        try container.encode(letters.map(String.init), forKey: .letters)
        try container.encode(position, forKey: .position)
        try container.encode(candidates.map(String.init), forKey: .candidates)
        try container.encode(errors, forKey: .errors)
        try container.encode(isComplete, forKey: .isComplete)
        try container.encode(candidateSets.map { $0.map(String.init) }, forKey: .candidateSets)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let word = try container.decode(String.self, forKey: .word)
        let normalized = word.lowercased()
        let letters = try Self.decodeCharacters(
            try container.decode([String].self, forKey: .letters), key: .letters, decoder: decoder)
        guard !letters.isEmpty, normalized == word, letters == Array(word) else {
            throw DecodingError.dataCorruptedError(
                forKey: .letters,
                in: container,
                debugDescription: "Spelling letters do not match the normalized word")
        }
        let candidateStrings = try container.decode([[String]].self, forKey: .candidateSets)
        let candidateSets = try candidateStrings.map { set in
            try Self.decodeCharacters(set, key: .candidateSets, decoder: decoder)
        }
        try Self.validateDecoded(letters: letters, candidateSets: candidateSets, container: container)
        let position = try container.decode(Int.self, forKey: .position)
        let errors = try container.decode([Int].self, forKey: .errors)
        let complete = try container.decode(Bool.self, forKey: .isComplete)
        let currentCandidates = try Self.decodeCharacters(
            try container.decode([String].self, forKey: .candidates), key: .candidates, decoder: decoder)
        guard errors.count == letters.count, errors.allSatisfy({ $0 >= 0 }), position >= 0,
              position <= letters.count, complete == (position == letters.count),
              currentCandidates == (complete ? [] : candidateSets[position]) else {
            throw DecodingError.dataCorruptedError(
                forKey: .position,
                in: container,
                debugDescription: "Spelling progress is inconsistent with candidate sets")
        }
        self.word = word
        self.letters = letters
        self.position = position
        self.candidateSets = candidateSets
        self.candidates = currentCandidates
        self.errors = errors
        self.isComplete = complete
    }

    private static func decodeCharacters(
        _ strings: [String],
        key: CodingKeys,
        decoder: Decoder
    ) throws -> [Character] {
        guard strings.allSatisfy({ Array($0).count == 1 }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [key],
                    debugDescription: "Spelling letters must be one-character strings"))
        }
        return strings.map { Array($0)[0] }
    }

    private static func validateDecoded(
        letters: [Character],
        candidateSets: [[Character]],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard !candidateSets.isEmpty, candidateSets.count == letters.count,
              candidateSets.allSatisfy({ ($0.count == 6 || $0.count == 9) && Set($0).count == $0.count }),
              Set(candidateSets.map(\.count)).count == 1,
              candidateSets.enumerated().allSatisfy({ $0.element.contains(letters[$0.offset]) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .candidateSets,
                in: container,
                debugDescription: "Each position needs six or nine unique candidates including its answer")
        }
    }
}
