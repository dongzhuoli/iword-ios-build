import Foundation

/// Only learning material is archived. Endpoint, credential and login details live in Keychain instead.
struct SavedCoachReport: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var createdAt: Date
    var dataThrough: Date
    var fingerprint: String
    var configurationVersion: String
    var report: AICoachReport
    var words: [MobileWord]
    var validationNotes: [String] = []
    var attempts: [String: CoachExerciseProgress] = [:]
}
struct CoachExerciseProgress: Codable, Equatable {
    var attempts = 0
    var firstCorrect: Bool?
    var complete = false
    var revealed = false
    var selectedIndex: Int?
    var answeredAt: Date?
    var hintUsed: Bool?
    var lastCorrect: Bool?
    /// These results are practice evidence only; no scheduling/mastery state is passed here.
    mutating func answer(_ question: AICoachExercise, choiceIndex: Int? = nil,
                         spelling: String? = nil, recalled: Bool? = nil, now: Date = Date()) {
        guard !complete else { return }
        let correct: Bool
        switch question.kind {
        case .meaningChoice:
            guard let choices = question.choiceWordIDs, let choiceIndex, choices.indices.contains(choiceIndex) else { return }
            selectedIndex = choiceIndex; correct = choices[choiceIndex] == question.wordID
        case .spelling:
            guard let spelling, let expected = question.answer, !expected.isEmpty else { return }
            correct = spelling.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(expected) == .orderedSame
        case .meaningRecall:
            guard revealed, let recalled else { return }; correct = recalled
        }
        lastCorrect = correct
        if firstCorrect == nil { firstCorrect = correct && hintUsed != true && (question.kind == .meaningRecall || !revealed) }
        attempts = min(3, attempts + 1)
        complete = correct || attempts == 3 || question.kind == .meaningRecall
        if complete { revealed = true }
        answeredAt = now
    }
}
struct AdoptedCoachPlan: Codable, Equatable {
    var reportID: String
    var day: String
    var dailyNewWords: Int
    var reviewWordIDs: [String]
    var morningReviewIDs: [String]?
    var afternoonReviewIDs: [String]?
    var eveningReviewIDs: [String]?
}
struct AICoachArchive: Codable, Equatable {
    var automaticEnabled = false
    var automaticEnabledAt: Date?
    var reports: [SavedCoachReport] = []
    var adoptedPlan: AdoptedCoachPlan?
    var latest: SavedCoachReport? { reports.first }
    static func effectiveDailyLimit(state: LocalState, now: Date) -> Int {
        let configured = state.profile.preferences.dailyNewWords
        guard let plan = state.profile.aiCoach?.adoptedPlan, plan.day == LocalState.studyDay(now) else { return configured }
        return max(0, min(configured, plan.dailyNewWords))
    }
    /// A plan can prioritize eligible old words; it cannot remove the spacing/rest safeguard.
    static func prioritizedReviews(_ normal: [MobileWord], state: LocalState, now: Date) -> [MobileWord] {
        guard let plan = state.profile.aiCoach?.adoptedPlan, plan.day == LocalState.studyDay(now) else { return normal }
        let byID = Dictionary(state.availableWords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let completed = Set(state.sessions.values.filter { $0.studyDay == plan.day }.flatMap { session in
            session.steps.prefix(min(session.position, session.steps.count)).filter { $0.kind == "recall" }.map { $0.word.id }
        })
        let plannedIDs: [String]
        switch state.profile.slot {
        case "morning": plannedIDs = plan.morningReviewIDs ?? plan.reviewWordIDs
        case "afternoon": plannedIDs = plan.afternoonReviewIDs ?? plan.reviewWordIDs
        default: plannedIDs = plan.eveningReviewIDs ?? plan.reviewWordIDs
        }
        let priority = plannedIDs.filter { !completed.contains($0) }.compactMap { id -> MobileWord? in
            guard let word = byID[id], state.progress[id]?.learned == true,
                  AssociationLearning.ready(state.progress[id], state: state, now: now) else { return nil }
            return word
        }
        var seen: Set<String> = []
        return (priority + normal).filter { seen.insert(StudySession.wordKey($0)).inserted }
    }
    func validate() throws {
        guard reports.count <= 14, Set(reports.map(\.id)).count == reports.count else {
            throw ContentFailure(message: "AI报告档案无效。")
        }
        if let plan = adoptedPlan {
            guard (0...50).contains(plan.dailyNewWords), plan.reviewWordIDs.count <= 60,
                  plan.day.range(of: "^20[0-9]{2}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
                throw ContentFailure(message: "AI学习计划无效。")
            }
        }
        for saved in reports {
            _ = try AICoachEngine.validateStored(report: saved.report, words: saved.words)
            let questionIDs = Set(saved.report.exercises.map(\.id))
            guard Set(saved.attempts.keys).isSubset(of: questionIDs), !saved.id.isEmpty, saved.id.count <= 100, saved.fingerprint.count == 64,
                  saved.words.count <= 60, Set(saved.words.map(\.id)).count == saved.words.count,
                  saved.validationNotes.count <= 40, saved.attempts.count <= 30,
                  saved.attempts.values.allSatisfy({ (0...3).contains($0.attempts) }) else {
                throw ContentFailure(message: "AI报告或答题记录无效。")
            }
        }
    }
}
