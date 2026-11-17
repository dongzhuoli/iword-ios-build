import XCTest
import IWordStorage
@testable import IWord

final class StudyReportTests: XCTestCase {
    func testDelayedSamplesExcludeRetryReviewClockAndAssistedSuccess() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = LocalState()
        func event(_ id: String, source: String = "standard", interval: String = "43200000", retry: String = "0", extra: [String: String] = [:], age: Double = 0) -> JournalEvent {
            var fields = ["wordID": id, "source": source, "actualIntervalMs": interval, "retry": retry, "rating": "easy", "activeMs": "1000", "stepID": id]
            fields.merge(extra) { _, new in new }
            return JournalEvent(kind: "RATE", fields: fields, occurredAt: now.addingTimeInterval(-age))
        }
        let events = [event("independent"), event("audio", extra: ["audioAssisted": "true"]), event("spelling", extra: ["spellingAssisted": "true"]),
                      event("hint", extra: ["rating": "hint", "hinted": "true"]), event("review", source: "review"), event("short", interval: "43199999"),
                      event("retry", retry: "1"), event("clock", extra: ["clockAnomaly": "true"])]
        state.progress["unknown"] = WordProgress(id: "unknown", familiarity: "unknown", learned: true, firstLearnedAt: now)
        state.progress["familiar"] = WordProgress(id: "familiar", familiarity: "familiar", learned: true, firstLearnedAt: now)
        let report = StudyReport.summary(state: state, events: events, now: now)
        XCTAssertEqual(report.delayedSamples, 4); XCTAssertEqual(report.delayedIndependent, 1); XCTAssertEqual(report.delayedAssisted, 3)
        XCTAssertEqual(report.delayedRate, "25%")
        XCTAssertEqual(report.learnedUnknown, 1); XCTAssertEqual(report.learnedFamiliar, 1)
        XCTAssertEqual(report.reviewRecalls, 1)
        let empty = StudyReport.summary(state: LocalState(), events: [], now: now)
        XCTAssertEqual(empty.delayedRate, "暂无样本")
    }
    func testCumulativeTimesNotCountedTwiceAndFirstDelayedUsesEntireHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = JournalEvent(kind: "RATE", fields: ["wordID": "a", "source": "standard", "actualIntervalMs": "50000000", "rating": "forgot", "stepID": "old", "activeMs": "7000"], occurredAt: now.addingTimeInterval(-9 * 86400))
        let events = [old, JournalEvent(kind: "HINT", fields: ["stepID": "current", "activeMs": "1000"], occurredAt: now.addingTimeInterval(-10)),
                      JournalEvent(kind: "RATE", fields: ["stepID": "current", "wordID": "a", "source": "standard", "actualIntervalMs": "50000000", "rating": "easy", "activeMs": "3000"], occurredAt: now)]
        let report = StudyReport.summary(state: LocalState(), events: events, now: now)
        XCTAssertEqual(report.activeMs, 3000); XCTAssertEqual(report.firstDelayedSamples, 0); XCTAssertEqual(report.delayedSamples, 1)
    }
    func testReportEscapesHTMLAndCSVAndOmitsSecrets() throws {
        let event = JournalEvent(kind: "RATE", fields: ["phone": "13800138000", "csrfToken": "secret-test", "reason": "sensitive-url", "wordID": "a", "source": "standard", "rating": "forgot"])
        let files = try StudyReport.files(state: LocalState(), events: [event], now: Date())
        let json = String(data: files["report/events.jsonl"]!, encoding: .utf8)!
        XCTAssertFalse(json.contains("13800138000")); XCTAssertFalse(json.contains("secret-test")); XCTAssertFalse(json.contains("sensitive-url"))
        XCTAssertEqual(StudyReport.csv(" =SUM(1,2)"), "\"' =SUM(1,2)\"")
        XCTAssertEqual(StudyReport.html("<script>&"), "&lt;script&gt;&amp;")
        XCTAssertEqual(files.count, 5)
    }

    func testMeaningEvidenceV3KeepsAutomaticAudioIndependentWhileV2AudioIsAssisted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func rate(_ wordID: String, extra: [String: String]) -> JournalEvent {
            var fields = ["wordID": wordID, "source": "standard", "actualIntervalMs": "43200000",
                           "retry": "0", "rating": "easy", "stepID": wordID]
            fields.merge(extra) { _, new in new }
            return JournalEvent(kind: "RATE", fields: fields, occurredAt: now.addingTimeInterval(-13 * 60 * 60))
        }

        let events = [
            rate("v3", extra: ["meaningEvidenceVersion": "3", "meaningIndependent": "true", "automaticAudio": "true"]),
            rate("v2", extra: ["audioAssisted": "true"])
        ]
        let report = StudyReport.summary(state: LocalState(), events: events, now: now)
        XCTAssertEqual(report.delayedSamples, 2)
        XCTAssertEqual(report.delayedIndependent, 1)
        XCTAssertEqual(report.delayedAssisted, 1)
        XCTAssertEqual(report.delayedRate, "50%")
        XCTAssertEqual(report.audioAssisted, 1)
    }

    func testSpokenEvidenceExportsWithoutAutomaticRecallCredit() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [JournalEvent(kind: "SPOKEN-ANSWER", fields: [
            "wordID": "target", "value": "发光", "attempt": "1", "correct": "true", "recognitionMode": "on-device"
        ], occurredAt: now), JournalEvent(kind: "SPOKEN-ERROR", fields: [
            "wordID": "target", "reason": "未识别到语音", "counted": "false"
        ], occurredAt: now)]
        let summary = StudyReport.summary(state: LocalState(), events: events, now: now)
        XCTAssertEqual(summary.delayedSamples, 0)
        XCTAssertEqual(summary.standardRecalls, 0)
        let files = try StudyReport.files(state: LocalState(), events: events, now: now)
        let json = try XCTUnwrap(String(data: try XCTUnwrap(files["report/events.jsonl"]), encoding: .utf8))
        XCTAssertTrue(json.contains("on-device"))
        XCTAssertTrue(json.contains("\"counted\":\"false\""))
    }

    func testRecognitionIsCountedSeparatelyAndMeaningEvidenceFieldsAreExported() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recognition = JournalEvent(kind: "RECOGNIZE-NEXT", fields: [
            "wordID": "target", "choices": "target,other", "selected": "target", "correct": "true",
            "meaningEvidenceVersion": "3", "meaningIndependent": "false", "automaticAudio": "true",
            "secret": "must-not-export"
        ], occurredAt: now)
        let events = [recognition,
                      JournalEvent(kind: "RECOGNIZE-NEXT", fields: ["wordID": "other", "correct": "false"], occurredAt: now)]
        let report = StudyReport.summary(state: LocalState(), events: events, now: now)
        XCTAssertEqual(report.recognitionCompleted, 2)
        XCTAssertEqual(report.recognitionCorrect, 1)
        XCTAssertEqual(report.delayedSamples, 0)

        let files = try StudyReport.files(state: LocalState(), events: events, now: now)
        let json = String(data: try XCTUnwrap(files["report/events.jsonl"]), encoding: .utf8)
        XCTAssertTrue(json?.contains("\"choices\":\"target,other\"") == true)
        XCTAssertTrue(json?.contains("\"selected\":\"target\"") == true)
        XCTAssertTrue(json?.contains("\"correct\":\"true\"") == true)
        XCTAssertTrue(json?.contains("\"meaningEvidenceVersion\":\"3\"") == true)
        XCTAssertTrue(json?.contains("\"meaningIndependent\":\"false\"") == true)
        XCTAssertTrue(json?.contains("\"automaticAudio\":\"true\"") == true)
        XCTAssertFalse(json?.contains("must-not-export") == true)
    }

    func testAssociationReportRequiresCrossDayFourHoursAndKeepsFirstAttempt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 8, hour: 12))!
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour))!
        }
        func rate(_ wordID: String, at occurredAt: Date, interval: Int64, rating: String = "easy", extra: [String: String] = [:]) -> JournalEvent {
            var fields = ["wordID": wordID, "source": "standard", "actualIntervalMs": String(interval), "retry": "0",
                           "rating": rating, "meaningEvidenceVersion": "3", "meaningIndependent": "true"]
            fields.merge(extra) { _, new in new }
            return JournalEvent(kind: "RATE", fields: fields, occurredAt: occurredAt)
        }
        let events = [
            rate("short", at: date(2, 2), interval: 3 * 60 * 60 * 1000), // crosses Beijing midnight but is under four hours
            rate("same-day", at: date(2, 10), interval: 5 * 60 * 60 * 1000),
            rate("failed-first", at: date(3, 3), interval: 5 * 60 * 60 * 1000, rating: "forgot"),
            rate("failed-first", at: date(3, 4), interval: 5 * 60 * 60 * 1000),
            rate("valid", at: date(4, 3), interval: 5 * 60 * 60 * 1000),
            rate("retry", at: date(4, 3), interval: 5 * 60 * 60 * 1000, extra: ["retry": "1"]),
            rate("clock", at: date(4, 3), interval: 5 * 60 * 60 * 1000, extra: ["clockAnomaly": "true"]),
            rate("legacy", at: date(4, 3), interval: 5 * 60 * 60 * 1000, extra: ["meaningEvidenceVersion": "2"]),
            rate("recorded-contact", at: date(4, 3), interval: 5 * 60 * 60 * 1000,
                 extra: ["previousContactAt": ISO8601DateFormatter().string(from: date(4, 1))])
        ]
        let report = AssociationReport.summary(events: events, start: date(1, 0), end: now)
        XCTAssertEqual(report.samples, 2)
        XCTAssertEqual(report.directRecall, 1)
        XCTAssertEqual(report.notRecalled, 1)
        XCTAssertEqual(report.otherAssisted, 0)
    }

    func testAssociationReportGroupsPromptTypesAndKeepsOldDelayedMetricSeparate() {
        // 03:00 Beijing: a five-hour interval genuinely crosses the study day.
        let now = ISO8601DateFormatter().date(from: "2027-01-15T03:00:00+08:00")!
        func rate(_ wordID: String, extra: [String: String]) -> JournalEvent {
            var fields = ["wordID": wordID, "source": "review", "actualIntervalMs": "18000000", "retry": "0",
                           "rating": "easy", "meaningEvidenceVersion": "3", "meaningIndependent": "true"]
            fields.merge(extra) { _, new in new }
            return JournalEvent(kind: "RATE", fields: fields, occurredAt: now)
        }
        let events = [rate("direct", extra: [:]),
                      rate("association", extra: ["rating": "hint", "hinted": "true", "meaningIndependent": "false", "associationHintLevel": "1", "associationVersion": "v1"]),
                      rate("other", extra: ["rating": "hint", "hinted": "true", "meaningIndependent": "false"]),
                      rate("forgot", extra: ["rating": "forgot", "hinted": "true"])]
        let report = StudyReport.summary(state: LocalState(), events: events, now: now)
        XCTAssertEqual(report.associationReport.samples, 4)
        XCTAssertEqual(report.associationReport.directRecall, 1)
        XCTAssertEqual(report.associationReport.associationAssisted, 1)
        XCTAssertEqual(report.associationReport.otherAssisted, 1)
        XCTAssertEqual(report.associationReport.notRecalled, 1)
        XCTAssertEqual(report.associationReport.withAssociationVersion, 1)
        XCTAssertEqual(report.associationReport.withoutAssociationVersion, 3)
        XCTAssertEqual(report.associationReport.directRate, "25%")
        XCTAssertEqual(report.delayedSamples, 0)
    }

    func testAssociationFieldsAreExportedWithoutAssociationTextInSummary() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = JournalEvent(kind: "ASSOCIATION_VIEWED", fields: [
            "wordID": "a", "associationVersion": "v1", "associationSource": "local",
            "associationCue": "cue text", "associationStory": "story text"
        ], occurredAt: now)
        let rate = JournalEvent(kind: "RATE", fields: [
            "wordID": "a", "source": "standard", "actualIntervalMs": "18000000", "retry": "0",
            "rating": "easy", "meaningEvidenceVersion": "3", "meaningIndependent": "true",
            "associationHintLevel": "1", "associationVersion": "v1", "associationExposedAt": "2027-01-01T00:00:00Z",
            "associationSource": "local"
        ], occurredAt: now)
        let files = try StudyReport.files(state: LocalState(), events: [event, rate], now: now)
        let json = String(data: try XCTUnwrap(files["report/events.jsonl"]), encoding: .utf8)
        let summary = String(data: try XCTUnwrap(files["report/summary.csv"]), encoding: .utf8)
        let recalls = String(data: try XCTUnwrap(files["report/recalls.csv"]), encoding: .utf8)
        let html = String(data: try XCTUnwrap(files["report/report.html"]), encoding: .utf8)
        XCTAssertTrue(json?.contains("associationVersion") == true)
        XCTAssertTrue(json?.contains("cue text") == true)
        XCTAssertTrue(summary?.contains("隔天首次回忆样本") == true)
        XCTAssertTrue(recalls?.contains("associationHintLevel") == true)
        XCTAssertTrue(html?.contains("隔天首次回忆") == true)
    }
}
