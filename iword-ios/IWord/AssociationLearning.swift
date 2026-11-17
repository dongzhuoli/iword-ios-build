import Foundation

/// A personal memory device, deliberately separate from verified morphology/etymology.
struct PersonalAssociation: Codable, Equatable {
    var chunks: String = ""
    var cue: String = ""
    var story: String = ""
    var source: String = "personal"
    var version: String = UUID().uuidString
    var updatedAt: Date?
    var isEmpty: Bool { cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var valid: Bool { chunks.count <= 100 && cue.count <= 200 && story.count <= 500 && !version.isEmpty && version.count <= 100 && ["personal", "your-example", "suggestion"].contains(source) }
}

enum AssociationLearning {
    static func key(_ word: MobileWord) -> String { word.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func note(for word: MobileWord, state: LocalState) -> PersonalAssociation? {
        let value = state.profile.associationNotes?[key(word)]
        guard let value, value.source == "personal", !value.isEmpty else { return nil }
        return value
    }

    /// Apply once, preserve lower limits/zero and every later manual preference change.
    @discardableResult static func beginIfNeeded(state: inout LocalState, now: Date) -> Bool {
        guard state.profile.associationPlanStartedAt == nil else { return false }
        state.profile.associationPlanStartedAt = now
        var preferences = state.profile.preferences
        preferences.dailyNewWords = min(preferences.dailyNewWords, 6)
        state.profile.learningPreferences = preferences
        return true
    }

    static func decorate(_ step: StudyStep, state: LocalState) -> StudyStep {
        var value = step
        value.association = note(for: step.word, state: state)
        if let note = value.association {
            value.associationExposedAt = state.profile.associationExposureDates?[exposureKey(step.word, note: note)]
        }
        return value
    }

    static func exposureKey(_ word: MobileWord, note: PersonalAssociation) -> String { key(word) + "|" + note.version }

    static func expose(_ step: inout StudyStep, state: inout LocalState, now: Date) {
        guard let note = step.association else { return }
        var dates = state.profile.associationExposureDates ?? [:]
        let key = exposureKey(step.word, note: note)
        if dates[key] == nil { dates[key] = now }
        step.associationExposedAt = dates[key]
        step.associationViewed = true
        state.profile.associationExposureDates = dates
    }

    /// Only automatic study/consolidation queues use the breathing interval.
    /// Explicit distant-memory listening/review remains available to the user.
    static func ready(_ progress: WordProgress?, state: LocalState, now: Date) -> Bool {
        guard state.profile.associationPlanStartedAt != nil, let progress else { return true }
        guard let last = progress.lastStudiedAt ?? progress.schedule.lastContactAt ?? progress.firstLearnedAt else { return true }
        let struggling = MeaningLearning.needsSupport(progress)
        return now.timeIntervalSince(last) >= (struggling ? 30 * 60 : 4 * 60 * 60)
    }

}
