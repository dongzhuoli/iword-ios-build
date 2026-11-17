import Foundation
import IWordStorage
import ZIPFoundation

struct StudyReportSummary {
    var start: Date
    var end: Date
    var learnedUnknown: Int
    var learnedFamiliar: Int
    var assessedKnown: Int
    var standardRecalls: Int
    var reviewRecalls: Int
    var delayedSamples: Int
    var delayedIndependent: Int
    var delayedAssisted: Int
    var firstDelayedSamples: Int
    var firstDelayedSuccess: Int
    var hints: Int
    var audioAssisted: Int
    var spellingSelections: Int
    var spellingErrors: Int
    var activeMs: Int64
    var weakWords: [String]
    var days: [ReportDay]
    var associationReport: AssociationReportSummary
    var recognitionCompleted = 0
    var recognitionCorrect = 0
    var delayedRate: String { delayedSamples == 0 ? "暂无样本" : "\(Int(Double(delayedIndependent) / Double(delayedSamples) * 100))%" }
}
struct ReportDay {
    var day: String
    var newWords: Int
    var recalls: Int
    var reviews: Int
    var activeMs: Int64
}

/// Reports read one committed snapshot. Delayed recall never includes voluntary review, retry,
/// clock anomalies or audio/hint-assisted success in its independent-success numerator.
enum StudyReport {
    static func summary(state: LocalState, events: [JournalEvent], now: Date = Date()) -> StudyReportSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let recent = events.filter { $0.occurredAt >= start && $0.occurredAt <= now }
        let rates = recent.filter { $0.kind == "RATE" }
        let steps = Dictionary(state.sessions.values.flatMap { session in session.steps.map { ($0.id, $0) } }, uniquingKeysWith: { first, _ in first })
        func retry(_ event: JournalEvent) -> Int { Int(event.fields["retry"] ?? "") ?? steps[event.fields["stepID"] ?? ""]?.retry ?? 0 }
        let retryByStep = Dictionary(uniqueKeysWithValues: steps.map { ($0.key, $0.value.retry) })
        func eligible(_ event: JournalEvent) -> Bool {
            event.kind == "RATE" && event.fields["source"] == "standard" && retry(event) == 0 && event.fields["clockAnomaly"] != "true"
                && (Int64(event.fields["actualIntervalMs"] ?? "") ?? 0) >= 43_200_000
        }
        func independent(_ event: JournalEvent) -> Bool {
            if event.fields["meaningEvidenceVersion"] == "3" {
                return ["easy", "slow"].contains(event.fields["rating"] ?? "") && event.fields["meaningIndependent"] == "true"
                    && event.fields["hinted"] != "true" && event.fields["spellingAssisted"] != "true"
            }
            return ["easy", "slow"].contains(event.fields["rating"] ?? "") && event.fields["hinted"] != "true" && event.fields["audioAssisted"] != "true"
                && event.fields["spellingAssisted"] != "true"
        }
        let delayed = rates.filter(eligible)
        var first: [String: JournalEvent] = [:]
        for event in events.filter(eligible).sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let id = event.fields["wordID"], first[id] == nil else { continue }
            first[id] = event
        }
        let firstRecent = first.values.filter { $0.occurredAt >= start && $0.occurredAt <= now }
        // firstLearnedAt is durable, so supplemental learn/retries cannot inflate new-word counts.
        let newlyLearned = state.progress.values.filter { value in value.firstLearnedAt.map { $0 >= start && $0 <= now } ?? false }
        let unknown = newlyLearned.filter { $0.familiarity == "unknown" }.count
        let familiar = newlyLearned.filter { $0.familiarity != "unknown" }.count
        // Steps store cumulative active time; count each step once rather than summing every event.
        // Historical unfinished steps crossing midnight are apportioned by recorded incremental time below.
        var activeByDay: [String: Int64] = [:]
        var maximum: [String: Int64] = [:]
        for event in events.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let step = event.fields["stepID"], let cumulative = Int64(event.fields["activeMs"] ?? ""), cumulative >= 0 else { continue }
            let previous = maximum[step] ?? 0
            maximum[step] = max(previous, cumulative)
            if event.occurredAt >= start && event.occurredAt <= now {
                activeByDay[LocalState.studyDay(event.occurredAt), default: 0] += max(0, cumulative - previous)
            }
        }
        let days = (0..<7).map { offset -> ReportDay in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let day = LocalState.studyDay(date)
            return ReportDay(day: day, newWords: newlyLearned.filter { $0.firstLearnedAt.map { LocalState.studyDay($0) == day } ?? false }.count,
                             recalls: rates.filter { LocalState.studyDay($0.occurredAt) == day && $0.fields["source"] != "review" }.count,
                             reviews: rates.filter { LocalState.studyDay($0.occurredAt) == day && $0.fields["source"] == "review" }.count, activeMs: activeByDay[day] ?? 0)
        }
        let wordNames = Dictionary(state.words.map { ($0.id, $0.word) }, uniquingKeysWith: { first, _ in first })
        let failures = rates.filter { $0.fields["rating"] == "forgot" || $0.fields["rating"] == "hint" }
        let frequency = Dictionary(grouping: failures, by: { $0.fields["wordID"] ?? "" })
        let weak = frequency.keys.filter { !$0.isEmpty }.sorted { frequency[$0]!.count == frequency[$1]!.count ? $0 < $1 : frequency[$0]!.count > frequency[$1]!.count }
            .prefix(20).map { (wordNames[$0] ?? "已停用词条") + " · \(frequency[$0]!.count) 次需帮助" }
        let associationReport = AssociationReport.summary(events: events, start: start, end: now, retryByStep: retryByStep)
        return StudyReportSummary(start: start, end: now, learnedUnknown: unknown, learnedFamiliar: familiar,
                                  assessedKnown: recent.filter { $0.kind == "ASSESS" && $0.fields["value"] == "known" }.count,
                                  standardRecalls: rates.filter { $0.fields["source"] != "review" }.count, reviewRecalls: rates.filter { $0.fields["source"] == "review" }.count,
                                  delayedSamples: delayed.count, delayedIndependent: delayed.filter(independent).count,
                                  delayedAssisted: delayed.filter { !independent($0) && ["easy", "slow", "hint"].contains($0.fields["rating"] ?? "") }.count,
                                  firstDelayedSamples: firstRecent.count, firstDelayedSuccess: firstRecent.filter(independent).count,
                                  hints: rates.filter { $0.fields["hinted"] == "true" || $0.fields["rating"] == "hint" }.count,
                                  audioAssisted: rates.filter { $0.fields["audioAssisted"] == "true" }.count,
                                  spellingSelections: recent.filter { $0.kind == "SPELL-LETTER" }.count,
                                  spellingErrors: recent.filter { $0.kind == "SPELL-LETTER" && $0.fields["correct"] == "false" }.count,
                                  activeMs: activeByDay.values.reduce(0, +), weakWords: weak, days: days,
                                  associationReport: associationReport,
                                  recognitionCompleted: recent.filter { $0.kind == "RECOGNIZE-NEXT" }.count,
                                  recognitionCorrect: recent.filter { $0.kind == "RECOGNIZE-NEXT" && $0.fields["correct"] == "true" }.count)
    }
    static func csv(_ value: String) -> String {
        // Spreadsheet formula injection also includes leading whitespace and control characters.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.first.map { "=+-@".contains($0) } == true || value.hasPrefix("\t") || value.hasPrefix("\r") ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    static func files(state: LocalState, events: [JournalEvent], now: Date) throws -> [String: Data] {
        let report = summary(state: state, events: events, now: now)
        func data(_ text: String) -> Data { Data(text.utf8) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        // All events remain available for longitudinal analysis; report statistics cover the stated seven days.
        // Only explicitly allowed diagnostic fields are exported. Credentials and full phone numbers never are.
        let fields: Set<String> = ["reportID", "deviceID", "profileID", "ruleVersion", "timeZone", "appVersion", "sessionID", "source", "stepID", "wordID", "contentRevision", "value", "activeMs", "retry", "stepKind", "familiarity", "rating", "hinted", "audioAssisted", "spellingAssisted", "actualIntervalMs", "previousContactAt", "clockAnomaly", "reactionMs", "delayedSuccess", "position", "choices", "correct", "complete", "mistakes", "recalled", "slot", "hash", "rate", "voice", "packageID", "revision", "wordCount", "backupID", "branchID", "practiceID", "questionID", "kind", "exerciseKind", "answer", "attempt", "firstCorrect", "selected", "matched", "completed", "count", "automatic", "dailyNewWords", "order", "practiceKind", "mixedKinds", "reviewKind", "roundID", "questionCount", "unitID", "errors", "firstAnswerCorrect", "meaningEvidenceVersion", "meaningIndependent", "automaticAudio", "hintLevel", "restedAfterFailure", "spokenAttempts", "spokenCorrect", "recognitionMode", "counted", "associationHintLevel", "associationVersion", "associationExposedAt", "associationSource", "associationCue", "associationStory"]
        let journal = try events.map { event -> Data in
            var safe = event; safe.fields = event.fields.filter { fields.contains($0.key) }
            return try encoder.encode(safe)
        }.reduce(into: Data()) { $0.append($1); $0.append(10) }
        var summaryCSV = "\u{FEFF}指标,数值\r\n"
        let metrics: [(String, String)] = [("新学陌生词", String(report.learnedUnknown)), ("新学眼熟及未分类词", String(report.learnedFamiliar)), ("学前认识次数", String(report.assessedKnown)),
                       ("常规回忆次数", String(report.standardRecalls)), ("巩固回忆次数", String(report.reviewRecalls)), ("至少12小时延迟样本", String(report.delayedSamples)),
                       ("延迟独立成功", String(report.delayedIndependent)), ("延迟辅助成功", String(report.delayedAssisted)), ("延迟独立回忆率", report.delayedRate),
                       ("隔天首次回忆样本", String(report.associationReport.samples)), ("隔天首次直接想起", String(report.associationReport.directRecall)),
                       ("隔天首次联想辅助", String(report.associationReport.associationAssisted)), ("隔天首次其他辅助", String(report.associationReport.otherAssisted)),
                       ("隔天首次没想起", String(report.associationReport.notRecalled)), ("隔天首次直接想起率", report.associationReport.directRate),
                       ("隔天首次有联想版本", String(report.associationReport.withAssociationVersion)), ("隔天首次无联想版本", String(report.associationReport.withoutAssociationVersion)),
                       ("首次延迟样本", String(report.firstDelayedSamples)), ("首次延迟独立成功", String(report.firstDelayedSuccess)), ("前台活动毫秒近似值", String(report.activeMs)), ("词义辨认完成", String(report.recognitionCompleted)), ("词义辨认正确", String(report.recognitionCorrect))]
        for pair in metrics { summaryCSV += csv(pair.0) + "," + csv(pair.1) + "\r\n" }
        let names = Dictionary(state.words.map { ($0.id, $0.word) }, uniquingKeysWith: { first, _ in first })
        var recalls = "\u{FEFF}eventID,time,wordID,word,source,rating,hinted,audioAssisted,spellingAssisted,retry,actualIntervalMs,previousContactAt,reactionMs,clockAnomaly,meaningEvidenceVersion,meaningIndependent,automaticAudio,spokenAttempts,spokenCorrect,associationHintLevel,associationVersion,associationExposedAt,associationSource\r\n"
        let formatter = ISO8601DateFormatter()
        for event in events where event.kind == "RATE" {
            let row = [event.id, formatter.string(from: event.occurredAt), event.fields["wordID"] ?? "", names[event.fields["wordID"] ?? ""] ?? ""]
                + ["source", "rating", "hinted", "audioAssisted", "spellingAssisted", "retry", "actualIntervalMs", "previousContactAt", "reactionMs", "clockAnomaly", "meaningEvidenceVersion", "meaningIndependent", "automaticAudio", "spokenAttempts", "spokenCorrect", "associationHintLevel", "associationVersion", "associationExposedAt", "associationSource"].map { event.fields[$0] ?? "" }
            recalls += row.map(csv).joined(separator: ",") + "\r\n"
        }
        let daily = report.days.map { "<tr><td>\(html($0.day))</td><td>\($0.newWords)</td><td>\($0.recalls)</td><td>\($0.reviews)</td><td>\($0.activeMs / 60000)</td></tr>" }.joined()
        let cards = metrics.map { "<div class='metric'><span>\(html($0.0))</span><b>\(html($0.1))</b></div>" }.joined()
        let weak = report.weakWords.map { "<li>\(html($0))</li>" }.joined()
        let association = report.associationReport
        let page = """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>iWord 七天报告</title>
        <style>body{margin:0;background:#f4f7fb;color:#172b45;font:16px -apple-system,Arial,sans-serif}main{max-width:900px;margin:auto;padding:28px}h1{font-size:28px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.metric{background:white;border-radius:14px;padding:18px;display:flex;flex-direction:column;gap:12px}.metric span{font-size:13px;color:#69788d}.metric b{font-size:25px;color:#2855d9}table{width:100%;border-collapse:collapse;background:white}td,th{text-align:center;padding:12px;border-bottom:1px solid #e2e8f0}p{line-height:1.7;color:#69788d}.table{overflow:auto}li{padding:8px}</style>
        <main><h1>iWord · 七天报告</h1><p>\(html(LocalState.studyDay(report.start))) — \(html(LocalState.studyDay(now))) · 上海时区<br>快照：\(html(formatter.string(from: now)))</p>
        <div class="grid">\(cards)</div><h2>每天的学习</h2><div class="table"><table><tr><th>日期</th><th>新学</th><th>常规回忆</th><th>巩固回忆</th><th>活动分钟</th></tr>\(daily)</table></div>
        <h2>隔天首次回忆</h2><p>样本 \(association.samples) 次 · 直接想起 \(association.directRecall) 次（\(html(association.directRate))）· 联想辅助 \(association.associationAssisted) 次 · 其他辅助 \(association.otherAssisted) 次 · 没想起 \(association.notRecalled) 次。版本样本：有 \(association.withAssociationVersion)，无 \(association.withoutAssociationVersion)。\(association.needsCaution ? "样本较少，暂不据此判断记忆效果。" : "")</p>
        <h2>容易忘的词</h2>\(weak.isEmpty ? "<p>暂无需要帮助的回忆样本。</p>" : "<ul>\(weak)</ul>")
        <p>延迟样本：至少间隔12小时的常规首次尝试，不含补学重试、巩固练习和时钟异常。隔天首次回忆优先使用事件中的上次接触时间；旧记录缺少该字段时按实际间隔反推北京时间日期，结果仅作兼容估计。v3独立词义回忆不含释义提示、选项或答题前拼写；英文朗读单独记录。旧记录沿用旧口径；样本少时不据此判断能力。熟词筛选不计为新学陌生词。没有样本时不计算百分比。活动时长由前台动作累计近似，不等于专注时间。原始事件和CSV保留全部历史，便于后续分析。</p></main></html>
        """
        return ["report/report.html": data(page), "report/summary.csv": data(summaryCSV), "report/recalls.csv": data(recalls), "report/events.jsonl": journal,
                "report/word-states.json": try encoder.encode(state.progress.values.sorted { $0.id < $1.id })]
    }
}

/// A report is shareable analysis, separate from the complete restorable backup.
enum StudyReportExport {
    static func create(store: SQLiteStore, root: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let snapshot = staging.appendingPathComponent("report.sqlite")
        try store.backup(to: snapshot)
        let frozen = try SQLiteStore(url: snapshot, readOnly: true)
        let state = try LocalState.load(store: frozen), events = try frozen.events()
        let files = try StudyReport.files(state: state, events: events, now: now)
        let output = root.appendingPathComponent("reports", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let target = output.appendingPathComponent("iword-report-" + UUID().uuidString.lowercased() + ".zip")
        do {
            let archive = try Archive(url: target, accessMode: .create)
            var list: [PackageFile] = []
            for (path, data) in files.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let file = staging.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                try archive.addEntry(with: path, fileURL: file, compressionMethod: .deflate)
                list.append(PackageFile(path: path, sha256: ContentInstaller.hash(data), bytes: data.count))
            }
            let manifest: [String: Any] = ["kind": "iword-study-report", "schemaVersion": 1, "createdAt": ISO8601DateFormatter().string(from: now),
                                           "files": list.map { ["path": $0.path, "sha256": $0.sha256, "bytes": $0.bytes] }]
            let path = staging.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: path)
            try archive.addEntry(with: "manifest.json", fileURL: path, compressionMethod: .deflate)
            return target
        } catch { try? fm.removeItem(at: target); throw error }
    }
}
