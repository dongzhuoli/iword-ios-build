import Foundation
import IWordStorage

/// Applies durable learning credits without changing the scheduling contract.
/// A round is the unit of counting: a learn step followed by its recall step
/// contributes once, while a retry in the same round only refreshes recency.
enum LearningHistory {
    private static let sources: Set<String> = ["learn", "standard", "review", "practice"]

    static func backfill(state: inout LocalState, events: [JournalEvent]) {
        struct HistoricalCredit {
            let roundID: String
            let source: String
            let at: Date
        }
        var grouped: [String: [JournalEvent]] = [:]
        for event in events where event.kind == "LEARN" || event.kind == "RATE" {
            guard let sessionID = event.fields["sessionID"], !sessionID.isEmpty,
                  let wordID = event.fields["wordID"], !wordID.isEmpty else { continue }
            grouped[sessionID + "\u{1f}" + wordID, default: []].append(event)
        }

        var byWord: [String: [HistoricalCredit]] = [:]
        for eventsForRound in grouped.values {
            guard let first = eventsForRound.first,
                  let sessionID = first.fields["sessionID"],
                  let wordID = first.fields["wordID"] else { continue }
            let sourceEvent = eventsForRound.first(where: { $0.kind == "LEARN" })
                ?? eventsForRound.filter { $0.kind == "RATE" }.sorted { $0.occurredAt < $1.occurredAt }.last
            guard let sourceEvent else { continue }
            let source: String
            if sourceEvent.kind == "LEARN" {
                source = "learn"
            } else {
                source = sourceEvent.fields["source"] ?? "standard"
            }
            guard sources.contains(source) else { continue }
            let creditedAt = eventsForRound.map(\.occurredAt).max() ?? sourceEvent.occurredAt
            byWord[wordID, default: []].append(
                HistoricalCredit(roundID: sessionID, source: source, at: creditedAt))
        }

        for (wordID, credits) in byWord {
            let sorted = credits.sorted { $0.at < $1.at }
            guard !sorted.isEmpty else { continue }
            var progress = state.progress[wordID] ?? WordProgress(id: wordID)
            var credited = progress.creditedRoundIDs ?? []
            if let legacy = progress.lastCreditedRoundID { credited.insert(legacy) }
            let unseen = sorted.filter { !credited.contains($0.roundID) }
            let learning = unseen.filter { $0.source == "learn" }.count
            let reviews = unseen.filter { $0.source == "standard" || $0.source == "review" }.count
            let practice = unseen.filter { $0.source == "practice" }.count
            if progress.studyCount == nil { progress.studyCount = unseen.count }
            if progress.learningCount == nil { progress.learningCount = learning }
            if progress.reviewCount == nil { progress.reviewCount = reviews }
            if progress.practiceCount == nil { progress.practiceCount = practice }
            if progress.lastStudiedAt == nil { progress.lastStudiedAt = sorted.last?.at }
            if progress.previousStudiedAt == nil, sorted.count > 1 {
                progress.previousStudiedAt = sorted.dropLast().last?.at
            }
            if progress.lastCreditedRoundID == nil { progress.lastCreditedRoundID = sorted.last?.roundID }
            credited.formUnion(sorted.map(\.roundID))
            progress.creditedRoundIDs = credited
            state.progress[wordID] = progress
        }
    }

    static func credit(
        state: inout LocalState,
        wordID: String,
        source: String,
        roundID: String,
        now: Date
    ) {
        guard sources.contains(source), !wordID.isEmpty, !roundID.isEmpty else { return }
        var progress = state.progress[wordID] ?? WordProgress(id: wordID)
        var credited = progress.creditedRoundIDs ?? []
        if let legacy = progress.lastCreditedRoundID { credited.insert(legacy) }
        if credited.contains(roundID) {
            // A repeated recall in the same session is not a second study, but
            // it is still the most recent completed contact.
            if let last = progress.lastStudiedAt {
                progress.lastStudiedAt = max(last, now)
            } else {
                progress.lastStudiedAt = now
            }
            if source == "practice" {
                progress.schedule.lastContactAt = max(progress.schedule.lastContactAt ?? now, now)
            }
            state.progress[wordID] = progress
            return
        }

        if let last = progress.lastStudiedAt {
            if now > last {
                progress.previousStudiedAt = last
                progress.lastStudiedAt = now
                progress.lastCreditedRoundID = roundID
            } else if now > (progress.previousStudiedAt ?? .distantPast) {
                progress.previousStudiedAt = now
            }
        } else {
            progress.lastStudiedAt = now
            progress.lastCreditedRoundID = roundID
        }
        credited.insert(roundID)
        progress.creditedRoundIDs = credited
        progress.studyCount = (progress.studyCount ?? 0) + 1
        switch source {
        case "learn": progress.learningCount = (progress.learningCount ?? 0) + 1
        case "standard", "review": progress.reviewCount = (progress.reviewCount ?? 0) + 1
        case "practice":
            progress.practiceCount = (progress.practiceCount ?? 0) + 1
            // Practice must establish a fresh interval baseline, but must not
            // alter dueAt or stability and therefore cannot cause delay credit.
            progress.schedule.lastContactAt = max(progress.schedule.lastContactAt ?? now, now)
        default: break
        }
        state.progress[wordID] = progress
    }
}
