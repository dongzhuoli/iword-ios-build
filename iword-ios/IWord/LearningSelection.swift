import Foundation

/// Pure selection helpers shared by the study launcher and history views.
enum LearningSelection {
    private static let categoryRank = ["required": 0, "basic": 1, "extra": 2]

    static func newWords(state: LocalState) -> [MobileWord] {
        let candidates = state.availableWords.filter { word in
            guard let progress = state.progress[word.id] else { return false }
            return !progress.learned && progress.familiarity != "known"
        }
        let ordered = candidates.sorted(by: bookOrder)
        guard state.profile.preferences.order == "recommended" else { return ordered }

        // Assessment familiarity is an explicit user signal. Unknown words
        // lead, followed by familiar words, while each group stays in book
        // order so recommendations remain explainable and deterministic.
        let unknown = ordered.filter { state.progress[$0.id]?.familiarity == nil || state.progress[$0.id]?.familiarity == "unknown" }
        let familiar = ordered.filter { state.progress[$0.id]?.familiarity == "familiar" }
        return unknown + familiar
    }

    static func consolidation(
        state: LocalState,
        now: Date = Date(),
        limit: Int = 10
    ) -> [MobileWord] {
        guard limit > 0 else { return [] }
        let learned = state.availableWords.filter {
            state.progress[$0.id]?.learned == true && AssociationLearning.ready(state.progress[$0.id], state: state, now: now)
        }
        guard !learned.isEmpty else { return [] }
        let previous = previousReviewIDs(state: state)
        let ranked = learned.sorted { left, right in
            let l = consolidationRank(state.progress[left.id], now: now)
            let r = consolidationRank(state.progress[right.id], now: now)
            if l.weak != r.weak { return l.weak && !r.weak }
            if l.lastContact != r.lastContact { return l.lastContact < r.lastContact }
            if l.practiceCount != r.practiceCount { return l.practiceCount < r.practiceCount }
            return bookOrder(left, right)
        }
        let weak = ranked.filter { isWeak(state.progress[$0.id]) }
        let nonWeak = ranked.filter { !isWeak(state.progress[$0.id]) }
        let freshNonWeak = nonWeak.filter { !previous.contains($0.id) }
        let repeatedNonWeak = nonWeak.filter { previous.contains($0.id) }
        var result = Array(weak.prefix(limit))
        if result.count < limit {
            result += freshNonWeak.prefix(limit - result.count)
        }
        if result.count < limit {
            result += repeatedNonWeak.prefix(limit - result.count)
        }
        return Array(result.prefix(limit))
    }

    /// Longest time since a completed learning contact first; weakness does not affect this queue.
    static func distantMemories(state: LocalState, limit: Int = 10) -> [MobileWord] {
        guard limit > 0 else { return [] }
        return Array(state.availableWords.filter { state.progress[$0.id]?.learned == true }.sorted { left, right in
            let l = lastStudy(state.progress[left.id]), r = lastStudy(state.progress[right.id])
            if l != r { return l < r }
            return bookOrder(left, right)
        }.prefix(limit))
    }

    private static func lastStudy(_ progress: WordProgress?) -> Date {
        progress?.lastStudiedAt ?? progress?.schedule.lastContactAt ?? progress?.firstLearnedAt ?? .distantPast
    }

    static func standardReviews(state: LocalState, now: Date, slot: String) -> [MobileWord] {
        let learned = state.availableWords.filter {
            state.progress[$0.id]?.learned == true && AssociationLearning.ready(state.progress[$0.id], state: state, now: now)
        }
        let due = learned.filter { word in
            guard let date = state.progress[word.id]?.schedule.dueAt else { return false }
            return date <= now
        }.sorted { left, right in
            let l = state.progress[left.id]?.schedule.dueAt ?? .distantPast
            let r = state.progress[right.id]?.schedule.dueAt ?? .distantPast
            return l == r ? bookOrder(left, right) : l < r
        }
        let dueIDs = Set(due.map(\.id))
        let day = LocalState.studyDay(now)
        let evening = slot == "evening" || slot == "night"
        guard evening else { return Array(due.prefix(10)) }

        let completedEveningRecall = completedEveningRecallIDs(state: state, day: day)
        let newToday = learned.filter { word in
            guard !completedEveningRecall.contains(word.id) || dueIDs.contains(word.id) else { return false }
            if let first = state.progress[word.id]?.firstLearnedAt, LocalState.studyDay(first) == day { return true }
            return state.sessions.values.contains { session in
                session.studyDay == day
                    && session.steps.prefix(min(session.position, session.steps.count)).contains { $0.kind == "learn" && $0.word.id == word.id }
            }
        }.sorted(by: bookOrder)
        var result = newToday
        let included = Set(result.map(\.id))
        let supplemental = due.filter { word in
            guard !included.contains(word.id) else { return false }
            // A completed evening recall is not forced again unless the word
            // is genuinely due, in which case it remains eligible.
            return dueIDs.contains(word.id) || !completedEveningRecall.contains(word.id)
        }
        result += supplemental.prefix(10)
        return result
    }

    private static func completedEveningRecallIDs(state: LocalState, day: String) -> Set<String> {
        var ids = Set<String>()
        for session in state.sessions.values where session.mode == "standard" && session.slot == "evening" && session.studyDay == day {
            for step in session.steps.prefix(min(session.position, session.steps.count)) where step.kind == "recall" {
                ids.insert(step.word.id)
            }
        }
        return ids
    }

    private static func previousReviewIDs(state: LocalState) -> Set<String> {
        guard let session = state.sessions.values
            .filter({ $0.mode == "review" })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first else { return [] }
        return Set(session.steps.prefix(min(session.position, session.steps.count)).map { $0.word.id })
    }

    private static func isWeak(_ progress: WordProgress?) -> Bool {
        guard let progress else { return false }
        guard let rating = progress.latestRating else { return progress.latestHinted }
        return progress.latestHinted || rating != .easy
    }

    private static func consolidationRank(_ progress: WordProgress?, now: Date) -> (weak: Bool, lastContact: Date, practiceCount: Int) {
        guard let progress else { return (false, .distantPast, 0) }
        return (
            isWeak(progress),
            lastStudy(progress),
            progress.practiceCount ?? 0)
    }

    private static func bookOrder(_ left: MobileWord, _ right: MobileWord) -> Bool {
        let lCategory = categoryRank[left.category] ?? 3
        let rCategory = categoryRank[right.category] ?? 3
        if lCategory != rCategory { return lCategory < rCategory }
        let unit = left.unit.localizedStandardCompare(right.unit)
        if unit != .orderedSame { return unit == .orderedAscending }
        if left.order != right.order { return left.order < right.order }
        return left.id < right.id
    }
}
