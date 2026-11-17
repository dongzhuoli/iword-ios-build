import Foundation
import IWordDomain
import IWordStorage

struct WordExample: Codable, Equatable { var text: String; var translation: String? }
struct WordSense: Codable, Equatable { var key: String; var meaning: String; var primary: Bool?; var examples: [WordExample]? }
struct WordUsage: Codable, Equatable { var key: String; var pos: String; var phonetic: String?; var senses: [WordSense] }
struct WordPart: Codable, Equatable { var type: String; var text: String; var translation: String?; var usageKey: String?; var senseKey: String? }

struct MobileWord: Codable, Equatable, Identifiable {
    var id: String
    var revision: String
    var catalogID: String
    var word: String
    var meaning: String
    var pos: String
    var phonetic: String
    var category: String
    var unit: String
    var printedPage: Int
    var order: Int
    var usages: [WordUsage]
    var parts: [WordPart]
    var audioHash: String?
    var audioUsageKey: String?
    var audioNote: String?
    var packageID: String?
    var inactive: Bool?
    var example: WordExample? { usages.flatMap { $0.senses }.flatMap { $0.examples ?? [] }.first }
    var hint: String {
        if let example, !example.translation.orEmpty.isEmpty { return "想想这个情景：\(example.translation.orEmpty)" }
        if let phrase = example?.text { return "试着回想这个搭配：\(phrase)" }
        return "它在 \(unit) 的书内第 \(printedPage) 页，读音是 /\(phonetic)/。"
    }
}
extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

struct LocalProfile: Codable, Equatable {
    var id = UUID().uuidString
    var name = "我的学习档案"
    var deviceID = UUID().uuidString
    var slot = "morning"
    var serverBaseURL = ""
    var activeSessionID: String?
    var latestFinishedID: String?
    var installedPackages: [String: String]?
    var onlinePackages: Set<String>?
    var gentleStartedAt: Date?
    var associationPlanStartedAt: Date?
    var associationNotes: [String: PersonalAssociation]?
    var associationExposureDates: [String: Date]?
    var learningPreferences: LearningPreferences?
    var practiceRound: PracticeRound?
    var aiCoach: AICoachArchive?
    var preferences: LearningPreferences { learningPreferences ?? LearningPreferences() }
}
struct WordProgress: Codable, Equatable {
    var id: String
    var familiarity: String?
    var learned = false
    var firstLearnedAt: Date?
    var schedule = ScheduleState()
    var latestRating: RecallRating?
    var latestHinted = false
    var studyCount: Int?
    var lastStudiedAt: Date?
    var previousStudiedAt: Date?
    var creditedRoundIDs: Set<String>?
    var lastCreditedRoundID: String?
    var learningCount: Int?
    var reviewCount: Int?
    var practiceCount: Int?
}
struct DailyBudget: Codable, Equatable {
    var id: String
    var morning = 0
    var afternoon = 0
    var total = 0
}
struct StudyStep: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var word: MobileWord
    var kind: String
    var retry = 0
    var hinted = false
    var revealed = false
    var audioAssisted = false
    var observedAt: Date?
    var reactionMs: Int64?
    var activeMs: Int64 = 0
    var clockAnomaly = false
    var spelling: SpellingRound?
    var spellingVisible = false
    var spellingMistakes = 0
    // Optional additions keep pre-v3 frozen sessions and backups decodable.
    var meaningChoices: [MeaningChoice]?
    var selectedMeaningID: String?
    var recognitionCorrect: Bool?
    var recognitionMistakes: Int?
    var hintLevel: Int?
    var automaticAudio: Bool?
    var meaningEvidenceVersion: Int?
    var spellingBeforeRecall: Bool?
    var meaningFailure: Bool?
    var relearning: Bool?
    var spokenAttempts: Int?
    var spokenTranscript: String?
    var spokenCorrect: Bool?
    var association: PersonalAssociation?
    var associationHintLevel: Int?
    var associationExposedAt: Date?
    var associationViewed: Bool?
}
struct StudySession: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var mode: String
    var studyDay: String
    var slot: String
    var createdAt = Date()
    var completedAt: Date?
    var steps: [StudyStep]
    var position = 0
    var feedback: String?
    var reviewKind: String?
    var ruleVersion = "mobile-rule-v2"
    var paused = false
    var current: StudyStep? { position < steps.count ? steps[position] : nil }
    mutating func insertFollowUp(_ followUp: [StudyStep]) {
        guard position >= 0, position < steps.count else { return }
        steps.insert(contentsOf: followUp, at: position + 1)
    }
    /// A word completes only after its final queued step, including failure follow-ups.
    static func wordKey(_ word: MobileWord) -> String { word.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var totalWordCount: Int { Set(steps.map { Self.wordKey($0.word) }).count }
    var completedWordCount: Int {
        let offset = max(0, min(position, steps.count))
        let started = Set(steps.prefix(offset).map { Self.wordKey($0.word) })
        let remaining = Set(steps.dropFirst(offset).map { Self.wordKey($0.word) })
        return started.subtracting(remaining).count
    }
}
struct LocalState {
    var profile = LocalProfile()
    var words: [MobileWord] = []
    var progress: [String: WordProgress] = [:]
    var budgets: [String: DailyBudget] = [:]
    var sessions: [String: StudySession] = [:]
    var active: StudySession? { profile.activeSessionID.flatMap { sessions[$0] } }
    var availableWords: [MobileWord] { words.filter { $0.inactive != true } }
    var weakWords: [MobileWord] {
        availableWords.filter {
            guard let value = progress[$0.id], value.learned, let rating = value.latestRating else { return false }
            return value.latestHinted || rating != .easy
        }
    }
    static func studyDay(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func load(store: SQLiteStore) throws -> LocalState {
        var value = LocalState()
        let profiles = try store.records(.profile, as: LocalProfile.self)
        let words = try store.records(.content, as: MobileWord.self)
        let progress = try store.records(.wordState, as: WordProgress.self)
        let budgets = try store.records(.budget, as: DailyBudget.self)
        let sessions = try store.records(.session, as: StudySession.self)
        guard profiles.count <= 1, Set(words.map(\.id)).count == words.count,
              Set(progress.map(\.id)).count == progress.count, Set(budgets.map(\.id)).count == budgets.count,
              Set(sessions.map(\.id)).count == sessions.count else { throw ContentFailure(message: "档案中存在重复标识，无法安全读取。") }
        value.profile = profiles.first ?? LocalProfile()
        value.words = words.sorted { $0.order < $1.order }
        value.progress = Dictionary(uniqueKeysWithValues: progress.map { ($0.id, $0) })
        value.budgets = Dictionary(uniqueKeysWithValues: budgets.map { ($0.id, $0) })
        value.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return value
    }
    /// Only changed records are written. Old session copies keep their content and audio revisions.
    func changes(from old: LocalState) throws -> [StoreChange] {
        var result: [StoreChange] = []
        func append<T: Encodable & Equatable>(_ table: StoreTable, key: String, value: T, previous: T?) throws {
            if let previous, value == previous { return }
            result.append(try StoreChange(table, key: key, value: value))
        }
        try append(.profile, key: "local", value: profile, previous: old.profile)
        let oldWords = Dictionary(uniqueKeysWithValues: old.words.map { ($0.id, $0) })
        // Content is immutable between installs. Avoid encoding 6000 rich entries on each letter/audio event.
        for word in words {
            if let previous = oldWords[word.id], previous == word { continue }
            try append(.content, key: word.id, value: word, previous: oldWords[word.id])
        }
        for (key, value) in progress { try append(.wordState, key: key, value: value, previous: old.progress[key]) }
        for (key, value) in budgets { try append(.budget, key: key, value: value, previous: old.budgets[key]) }
        for (key, value) in sessions { try append(.session, key: key, value: value, previous: old.sessions[key]) }
        return result
    }
}

/// Unit identity includes category and catalog: required/basic can both contain Unit 1.
struct VocabularyUnit: Identifiable {
    var id: String
    var category: String
    var title: String
    var words: [MobileWord]
    static func categoryTitle(_ value: String) -> String {
        ["required": "必考词", "basic": "基础词", "extra": "超纲词"][value] ?? value
    }
    static func grouped(_ words: [MobileWord]) -> [VocabularyUnit] {
        let buckets = Dictionary(grouping: words.filter { $0.inactive != true }) { word in
            [word.catalogID, word.category, word.unit].map { "\($0.utf8.count):\($0)" }.joined()
        }
        return buckets.map { key, values in
            VocabularyUnit(id: key, category: values[0].category,
                           title: values[0].unit.isEmpty ? "未分单元" : values[0].unit,
                           words: values.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order })
        }.sorted {
            let ranks = ["required": 0, "basic": 1, "extra": 2]
            let left = ranks[$0.category] ?? 3, right = ranks[$1.category] ?? 3
            if left != right { return left < right }
            if $0.category != $1.category { return $0.category < $1.category }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
