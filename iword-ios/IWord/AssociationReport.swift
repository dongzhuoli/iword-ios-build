import Foundation
import IWordStorage

/// The separate-day first-recall measure is intentionally independent of the
/// historical 12-hour delayed-recall measure.
struct AssociationReportSummary {
    var samples: Int
    var directRecall: Int
    var associationAssisted: Int
    var otherAssisted: Int
    var notRecalled: Int
    var withAssociationVersion: Int = 0
    var withoutAssociationVersion: Int = 0

    var denominator: Int { samples }
    var direct: Int { directRecall }
    var association: Int { associationAssisted }
    var other: Int { otherAssisted }
    var forgot: Int { notRecalled }
    var directRate: String {
        samples == 0 ? "暂无样本" : "\(Int(Double(directRecall) / Double(samples) * 100))%"
    }
    var needsCaution: Bool { samples < 10 }
}

private struct AssociationDayKey: Hashable {
    let wordID: String
    let day: String
}

enum AssociationReport {
    static func summary(events: [JournalEvent], start: Date, end: Date,
                        retryByStep: [String: Int] = [:]) -> AssociationReportSummary {
        let recentRates = events.filter {
            $0.kind == "RATE" && $0.occurredAt >= start && $0.occurredAt <= end && $0.fields["wordID"]?.isEmpty == false
        }
        let iso8601 = ISO8601DateFormatter()
        func order(_ lhs: JournalEvent, _ rhs: JournalEvent) -> Bool {
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.id < rhs.id
        }
        // Select the first attempt for each word and Beijing study day before
        // applying eligibility. A failed first attempt must not be replaced by
        // a later successful retry on that day.
        let firstByWordAndDay = Dictionary(grouping: recentRates, by: {
            AssociationDayKey(wordID: $0.fields["wordID"] ?? "", day: LocalState.studyDay($0.occurredAt))
        }).compactMap { _, values in values.sorted(by: order).first }

        let eligible = firstByWordAndDay.filter { event in
            guard event.fields["source"] == "standard" || event.fields["source"] == "review",
                  (Int(event.fields["retry"] ?? "") ?? retryByStep[event.fields["stepID"] ?? ""] ?? 0) == 0,
                  event.fields["clockAnomaly"] != "true",
                  event.fields["meaningEvidenceVersion"] == "3",
                  let interval = Int64(event.fields["actualIntervalMs"] ?? ""), interval >= 14_400_000 else { return false }
            let previousContact: Date
            if let recorded = event.fields["previousContactAt"], !recorded.isEmpty {
                guard let parsed = iso8601.date(from: recorded) else { return false }
                previousContact = parsed
            } else {
                // Older RATE events did not persist the schedule timestamp;
                // their interval-based date is only an explicit fallback.
                previousContact = event.occurredAt.addingTimeInterval(-Double(interval) / 1000)
            }
            return LocalState.studyDay(previousContact) < LocalState.studyDay(event.occurredAt)
        }

        var direct = 0
        var association = 0
        var other = 0
        var forgot = 0
        for event in eligible {
            let rating = event.fields["rating"] ?? ""
            let easyOrSlow = rating == "easy" || rating == "slow"
            let associationLevel = Int(event.fields["associationHintLevel"] ?? "") ?? 0
            let independent = easyOrSlow && event.fields["meaningIndependent"] == "true"
                && event.fields["hinted"] != "true" && event.fields["spellingAssisted"] != "true"
            if rating == "forgot" || !["easy", "slow", "hint"].contains(rating) {
                forgot += 1
            } else if associationLevel > 0 {
                association += 1
            } else if independent {
                direct += 1
            } else {
                other += 1
            }
        }
        let withVersion = eligible.filter { !($0.fields["associationVersion"] ?? "").isEmpty }.count
        return AssociationReportSummary(samples: eligible.count, directRecall: direct,
                                        associationAssisted: association, otherAssisted: other,
                                        notRecalled: forgot, withAssociationVersion: withVersion,
                                        withoutAssociationVersion: eligible.count - withVersion)
    }
}
