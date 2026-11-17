import CryptoKit
import Foundation
import IWordStorage
import ZIPFoundation

struct BackupManifest: Codable {
    var schemaVersion: Int
    var kind: String
    var backupID: String
    var profileID: String
    var deviceID: String
    var createdAt: String
    var appVersion: String
    var wordCount: Int
    var eventCount: Int
    var files: [PackageFile]
}
struct PreparedBackup {
    let manifest: BackupManifest
    let stagingURL: URL
    let snapshotURL: URL
    let state: LocalState
    let events: [JournalEvent]
    func cleanup() { try? FileManager.default.removeItem(at: stagingURL) }
}

/// Archives a consistent SQLite snapshot and all audio referenced by current or frozen content.
enum BackupArchive {
    typealias ReportBuilder = (LocalState, [JournalEvent], Date) throws -> [String: Data]
    private static let reportPaths: Set<String> = ["report/report.html", "report/summary.csv", "report/recalls.csv", "report/events.jsonl", "report/word-states.json"]
    private static let maxArchiveBytes: Int64 = 500 * 1024 * 1024
    private static let maxExpandedBytes: UInt64 = 1024 * 1024 * 1024
    private static let maxFileCount = 20000

    static func create(store: SQLiteStore, reportBuilder: ReportBuilder, root: URL? = nil, now: Date = Date()) throws -> URL {
        let fm = FileManager.default, root = try root ?? ContentInstaller.root(), id = UUID().uuidString.lowercased()
        let staging = root.appendingPathComponent("backup-staging-\(id)", isDirectory: true)
        let snapshot = staging.appendingPathComponent("snapshot.sqlite")
        let destination = root.appendingPathComponent("backups/\(id).zip")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try store.backup(to: snapshot)
        let frozen = try SQLiteStore(url: snapshot, readOnly: true)
        let state = try LocalState.load(store: frozen), events = try frozen.events()
        try validate(state: state, events: events)
        let reports = try reportBuilder(state, events, now)
        guard Set(reports.keys) == reportPaths else { throw ContentFailure(message: "备份报告文件不完整。") }
        var files = [try file(path: "snapshot.sqlite", url: snapshot)]
        for (path, data) in reports {
            let url = staging.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url); files.append(try file(path: path, url: url))
        }
        files += try collectAudio(state: state, staging: staging)
        files.sort { $0.path < $1.path }
        let expanded = files.reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
        guard expanded <= maxExpandedBytes, files.count < maxFileCount else { throw ContentFailure(message: "完整备份超过本版容量限制。") }
        try ContentInstaller.checkSpace(required: Int64(expanded) + 20 * 1024 * 1024)
        let manifest = BackupManifest(schemaVersion: 1, kind: "iword-mobile-backup", backupID: id, profileID: state.profile.id, deviceID: state.profile.deviceID,
                                      createdAt: ISO8601DateFormatter().string(from: now), appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                                      wordCount: state.words.count, eventCount: events.count, files: files)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        let temporary = staging.appendingPathComponent("archive.zip")
        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            for path in ["manifest.json"] + files.map(\.path) {
                try Task.checkCancellation()
                try archive.addEntry(with: path, fileURL: staging.appendingPathComponent(path), compressionMethod: .deflate)
            }
            guard Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maxArchiveBytes else { throw ContentFailure(message: "完整备份超过500MB限制。") }
            try fm.moveItem(at: temporary, to: destination); return destination
        } catch { try? fm.removeItem(at: destination); throw error }
    }

    static func prepareRestore(from source: URL) throws -> PreparedBackup {
        let fm = FileManager.default, size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, Int64(size) <= maxArchiveBytes else { throw ContentFailure(message: "备份文件为空或超过500MB限制。") }
        try ContentInstaller.checkSpace(required: 1024 * 1024 * 1024 + Int64(size))
        let archive = try Archive(url: source, accessMode: .read)
        let staging = fm.temporaryDirectory.appendingPathComponent("iword-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var names: Set<String> = [], expanded: UInt64 = 0
            for entry in archive {
                try Task.checkCancellation()
                guard entry.type == .file, ContentInstaller.safePath(entry.path), allowed(entry.path), names.insert(entry.path).inserted else { throw ContentFailure(message: "备份包含非法路径、附件或重复文件。") }
                expanded += entry.uncompressedSize
                guard expanded <= maxExpandedBytes, names.count <= maxFileCount, entry.path != "manifest.json" || entry.uncompressedSize <= 5 * 1024 * 1024 else { throw ContentFailure(message: "备份展开内容超过安全限制。") }
                let target = staging.appendingPathComponent(entry.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path, contents: nil)
                let handle = try FileHandle(forWritingTo: target)
                do {
                    var actual: UInt64 = 0
                    let crc = try archive.extract(entry) { chunk in
                        try Task.checkCancellation(); actual += UInt64(chunk.count)
                        guard actual <= entry.uncompressedSize, actual <= maxExpandedBytes else { throw ContentFailure(message: "备份解压大小与声明不一致。") }
                        try handle.write(contentsOf: chunk)
                    }
                    try handle.close()
                    guard crc == entry.checksum, actual == entry.uncompressedSize else { throw ContentFailure(message: "备份解压完整性校验失败。") }
                } catch { try? handle.close(); throw error }
            }
            guard names.contains("manifest.json") else { throw ContentFailure(message: "备份缺少清单。") }
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
            try validate(manifest: manifest, names: names, staging: staging)
            let snapshot = staging.appendingPathComponent("snapshot.sqlite"), frozen = try SQLiteStore(url: snapshot, readOnly: true)
            let state = try LocalState.load(store: frozen), events = try frozen.events()
            try validate(state: state, events: events)
            guard manifest.profileID == state.profile.id, manifest.deviceID == state.profile.deviceID, manifest.wordCount == state.words.count, manifest.eventCount == events.count else { throw ContentFailure(message: "备份清单与学习数据不一致。") }
            let requiredAudio = Set(allWords(state).compactMap(\.audioHash))
            guard requiredAudio.allSatisfy({ names.contains("audio/\($0).mp3") }) else { throw ContentFailure(message: "备份缺少学习任务所需录音。") }
            return PreparedBackup(manifest: manifest, stagingURL: staging, snapshotURL: snapshot, state: state, events: events)
        } catch { try? fm.removeItem(at: staging); throw error }
    }

    static func restore(_ prepared: PreparedBackup, into store: SQLiteStore) throws {
        let fm = FileManager.default, root = try ContentInstaller.root().appendingPathComponent("audio", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Immutable audio can be installed before the SQLite switch; unused files are harmless on failure.
        for item in prepared.manifest.files where item.path.hasPrefix("audio/") {
            let source = prepared.stagingURL.appendingPathComponent(item.path)
            guard try fileHash(source) == item.sha256 else { throw ContentFailure(message: "录音校验失败。") }
            let target = root.appendingPathComponent(URL(fileURLWithPath: item.path).lastPathComponent)
            if fm.fileExists(atPath: target.path), try fileHash(target) == item.sha256 { continue }
            try Data(contentsOf: source).write(to: target, options: .atomic)
        }
        try store.restore(from: prepared.snapshotURL)
    }
    static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }; hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func allowed(_ path: String) -> Bool {
        path == "manifest.json" || path == "snapshot.sqlite" || reportPaths.contains(path) || path.range(of: "^audio/[a-f0-9]{64}\\.mp3$", options: .regularExpression) != nil
    }
    private static func file(path: String, url: URL) throws -> PackageFile {
        PackageFile(path: path, sha256: try fileHash(url), bytes: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    private static func allWords(_ state: LocalState) -> [MobileWord] {
        var words = state.words
        for session in state.sessions.values { words.append(contentsOf: session.steps.map(\.word)) }
        if let practice = state.profile.practiceRound { words.append(contentsOf: practice.referencedWords) }
        if let coach = state.profile.aiCoach {
            for report in coach.reports { words.append(contentsOf: report.words) }
        }
        return words
    }
    private static func collectAudio(state: LocalState, staging: URL) throws -> [PackageFile] {
        let fm = FileManager.default
        return try Set(allWords(state).compactMap(\.audioHash)).sorted().map { hash in
            guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ContentFailure(message: "录音标识无效。") }
            let source = try ContentInstaller.audioURL(hash)
            guard fm.fileExists(atPath: source.path), try fileHash(source) == hash else { throw ContentFailure(message: "本机缺少或损坏了一段录音，请先更新词库后再备份。") }
            let path = "audio/\(hash).mp3", target = staging.appendingPathComponent("audio/\(hash).mp3")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target); return try file(path: path, url: target)
        }
    }
    private static func validate(manifest: BackupManifest, names: Set<String>, staging: URL) throws {
        let declared = Set(manifest.files.map(\.path))
        guard manifest.schemaVersion == 1, manifest.kind == "iword-mobile-backup", UUID(uuidString: manifest.backupID) != nil,
              manifest.backupID == manifest.backupID.lowercased(), !manifest.profileID.isEmpty, !manifest.deviceID.isEmpty,
              ISO8601DateFormatter().date(from: manifest.createdAt) != nil, manifest.wordCount >= 0, manifest.eventCount >= 0,
              declared.count == manifest.files.count, names == declared.union(["manifest.json"]), declared.contains("snapshot.sqlite"), reportPaths.isSubset(of: declared) else { throw ContentFailure(message: "备份类型、版本或文件清单不兼容。") }
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard manifest.appVersion.compare(app, options: .numeric) != .orderedDescending else { throw ContentFailure(message: "备份来自较新版本，请先升级App。") }
        for item in manifest.files {
            guard item.path != "manifest.json", allowed(item.path), item.bytes >= 0, item.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ContentFailure(message: "备份文件清单无效。") }
            let url = staging.appendingPathComponent(item.path)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == item.bytes, try fileHash(url) == item.sha256 else { throw ContentFailure(message: "备份文件哈希校验失败。") }
            if item.path.hasPrefix("audio/") && item.path != "audio/\(item.sha256).mp3" { throw ContentFailure(message: "备份录音内容与标识不一致。") }
        }
    }
    private static func validate(state: LocalState, events: [JournalEvent]) throws {
        guard !state.profile.id.isEmpty, !state.profile.deviceID.isEmpty, Set(state.words.map(\.id)).count == state.words.count, Set(events.map(\.id)).count == events.count else { throw ContentFailure(message: "备份档案标识不完整或有重复记录。") }
        if let active = state.profile.activeSessionID {
            guard let task = state.sessions[active], task.completedAt == nil, task.position < task.steps.count else { throw ContentFailure(message: "备份未完成任务引用无效。") }
        }
        if let latest = state.profile.latestFinishedID, state.sessions[latest] == nil { throw ContentFailure(message: "备份最近任务引用无效。") }
        let wordIDs = Set(state.words.map(\.id)).union(state.sessions.values.flatMap { $0.steps.map { $0.word.id } })
        guard state.progress.keys.allSatisfy({ wordIDs.contains($0) }), state.budgets.values.allSatisfy({ $0.total >= 0 && $0.morning >= 0 && $0.afternoon >= 0 }) else { throw ContentFailure(message: "备份学习进度引用或预算无效。") }
        let preferences = state.profile.preferences
        guard (0...50).contains(preferences.dailyNewWords), ["sequential", "recommended"].contains(preferences.order),
              (0...23).contains(preferences.reminderHour), (0...59).contains(preferences.reminderMinute) else { throw ContentFailure(message: "备份学习偏好无效。") }
        try state.profile.practiceRound?.validate()
        try state.profile.aiCoach?.validate()
        guard (state.profile.associationNotes ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.count <= 200 && $0.value.valid }) else {
            throw ContentFailure(message: "备份个人联想内容无效。")
        }
        guard state.progress.values.allSatisfy({ ($0.studyCount ?? 0) >= 0 && ($0.learningCount ?? 0) >= 0 && ($0.reviewCount ?? 0) >= 0 && ($0.practiceCount ?? 0) >= 0 }) else { throw ContentFailure(message: "备份学习次数无效。") }
        guard (state.profile.associationExposureDates ?? [:]).keys.allSatisfy({ !$0.isEmpty && $0.count <= 400 }) else {
            throw ContentFailure(message: "备份联想使用记录无效。")
        }
        for task in state.sessions.values {
            guard task.position >= 0, task.position <= task.steps.count, Set(task.steps.map(\.id)).count == task.steps.count,
                  task.steps.allSatisfy({ step in
                      step.retry >= 0 && step.activeMs >= 0 && step.spellingMistakes >= 0 && ["assessment", "learn", "recognition", "recall"].contains(step.kind)
                          && (0...2).contains(step.recognitionMistakes ?? 0) && (0...2).contains(step.hintLevel ?? 0)
                          && (step.meaningEvidenceVersion == nil || step.meaningEvidenceVersion == 3)
                          && (step.kind != "recognition" || Self.validMeaningChoices(step))
                          && SpokenMeaning.valid(step)
                          && (0...2).contains(step.associationHintLevel ?? 0)
                          && (step.association?.valid ?? true)
                          && ((step.associationHintLevel ?? 0) == 0 || (step.hinted && step.association != nil))
                          && (step.spelling.map { $0.word == step.word.word.lowercased() } ?? true)
                  }) else { throw ContentFailure(message: "备份学习步骤无效。") }
        }
    }
    private static func validMeaningChoices(_ step: StudyStep) -> Bool {
        guard let choices = step.meaningChoices, (2...3).contains(choices.count),
              Set(choices.map(\.id)).count == choices.count,
              choices.contains(where: { $0.id == step.word.id }),
              choices.allSatisfy({ !$0.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              step.selectedMeaningID == nil || choices.contains(where: { $0.id == step.selectedMeaningID }) else { return false }
        if let selected = step.selectedMeaningID { return step.recognitionCorrect == (selected == step.word.id) }
        return step.recognitionCorrect == nil
    }

}
