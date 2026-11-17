import XCTest
import IWordDomain
import IWordStorage
import ZIPFoundation
@testable import IWord

final class BackupArchiveTests: XCTestCase {
    func testCompleteRoundTripPreservesFrozenTaskSpellingBudgetAudioAndJournal() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try SQLiteStore(url: root.appendingPathComponent("study.sqlite"))
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "sample", withExtension: "zip"))
        let (_, words) = try ContentInstaller.install(fixture)
        var state = LocalState(); state.words = words
        let word = try XCTUnwrap(words.first)
        let originalAudio = try XCTUnwrap(word.audioHash)
        let audioURL = try ContentInstaller.audioURL(originalAudio)
        let audioBytes = try Data(contentsOf: audioURL)
        // A content update may remove current audio while the unfinished task still references it.
        state.words[0].audioHash = nil; state.words[0].audioUsageKey = nil
        var step = StudyStep(word: word, kind: "recall")
        step.revealed = true; step.spelling = SpellingRound(word: word.word); step.spellingVisible = true
        if let first = word.word.first { _ = step.spelling?.choose(String(first)) }
        var recognition = MeaningLearning.step(word, kind: "recognition", choices: [
            MeaningChoice(id: word.id, meaning: "核心释义"),
            MeaningChoice(id: "other-word", meaning: "另一个释义")
        ])
        recognition.selectedMeaningID = word.id
        recognition.recognitionCorrect = true
        let association = PersonalAssociation(cue: "一个记忆画面", story: "我自己的联想", version: "backup-association-v1")
        step.association = association; step.associationHintLevel = 1; step.hinted = true
        step.associationExposedAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.profile.associationPlanStartedAt = step.associationExposedAt
        state.profile.associationNotes = [AssociationLearning.key(word): association]
        state.profile.associationExposureDates = [AssociationLearning.exposureKey(word, note: association): step.associationExposedAt!]
        let session = StudySession(mode: "standard", studyDay: "2026-11-11", slot: "morning", steps: [step, recognition])
        state.sessions[session.id] = session; state.profile.activeSessionID = session.id
        state.progress[word.id] = WordProgress(id: word.id, familiarity: "unknown", learned: true, firstLearnedAt: Date())
        state.profile.aiCoach = AICoachArchive(automaticEnabled: true, automaticEnabledAt: Date(timeIntervalSince1970: 1_700_000_000))
        let coachTime = AICoachTimePlan(message: "复习已学词", newWordCount: 0, reviewWordIDs: [word.id])
        let coachReport = AICoachReport(analysisSummary: "测试报告", findings: [], priorityWords: [],
                                        tomorrowPlan: AICoachTomorrowPlan(morning: coachTime, afternoon: coachTime, evening: coachTime),
                                        exercises: [AICoachExercise(id: "coach-q", kind: .meaningRecall, wordID: word.id)])
        var coachSaved = SavedCoachReport(createdAt: Date(), dataThrough: Date(), fingerprint: String(repeating: "a", count: 64),
                                          configurationVersion: "2", report: coachReport, words: [word])
        coachSaved.attempts["coach-q"] = CoachExerciseProgress(attempts: 1, firstCorrect: true, complete: true, revealed: true, lastCorrect: true)
        state.profile.aiCoach?.reports = [coachSaved]
        state.profile.learningPreferences = LearningPreferences(order: "sequential", dailyNewWords: 20)
        var practice = try PracticeEngine.make(kind: .meaning, words: words)
        let target = try XCTUnwrap(practice.current)
        XCTAssertEqual(practice.choose(target.word.id), .correct)
        practice.paused = true
        state.profile.practiceRound = practice
        LearningHistory.credit(state: &state, wordID: word.id, source: "practice", roundID: practice.id, now: Date())
        state.budgets["2026-11-11"] = DailyBudget(id: "2026-11-11", morning: 1, afternoon: 0, total: 1)
        let event = JournalEvent(kind: "RATE", fields: ["wordID": word.id])
        try store.commit(operationID: "first", changes: state.changes(from: LocalState()), events: [event])
        let archive = try BackupArchive.create(store: store, reportBuilder: StudyReport.files, root: root)
        // Keep one synthetic archive for independent cross-platform server/SQLite verification in CI.
        let exported = try ContentInstaller.root().appendingPathComponent("ci-backup-fixture.zip")
        try? fm.removeItem(at: exported)
        try fm.copyItem(at: archive, to: exported)
        let prepared = try BackupArchive.prepareRestore(from: archive); defer { prepared.cleanup() }
        XCTAssertEqual(prepared.manifest.wordCount, words.count); XCTAssertEqual(prepared.events.count, 1)
        XCTAssertEqual(prepared.state.active?.current?.spelling?.position, step.spelling?.position)
        let restoredRecognition = try XCTUnwrap(prepared.state.active?.steps.first(where: { $0.kind == "recognition" }))
        XCTAssertEqual(restoredRecognition.meaningChoices, recognition.meaningChoices)
        XCTAssertEqual(restoredRecognition.selectedMeaningID, word.id)
        XCTAssertEqual(restoredRecognition.recognitionCorrect, true)
        XCTAssertEqual(prepared.state.profile.aiCoach, state.profile.aiCoach)
        XCTAssertEqual(prepared.state.profile.learningPreferences, state.profile.learningPreferences)
        XCTAssertEqual(prepared.state.profile.associationNotes, state.profile.associationNotes)
        XCTAssertEqual(prepared.state.profile.associationExposureDates, state.profile.associationExposureDates)
        XCTAssertEqual(prepared.state.profile.associationPlanStartedAt, state.profile.associationPlanStartedAt)
        XCTAssertEqual(prepared.state.active?.current?.association, association)
        XCTAssertEqual(prepared.state.active?.current?.associationHintLevel, 1)
        XCTAssertEqual(prepared.state.active?.current?.associationExposedAt, step.associationExposedAt)
        XCTAssertEqual(prepared.state.profile.practiceRound, practice)
        XCTAssertEqual(prepared.state.progress[word.id]?.studyCount, 1)
        XCTAssertTrue(prepared.manifest.files.contains { $0.path == "report/report.html" })
        XCTAssertTrue(prepared.manifest.files.contains { $0.path == "audio/\(originalAudio).mp3" })
        XCTAssertEqual(prepared.manifest.files.filter { $0.path.hasPrefix("audio/") }.count, 5)
        try fm.removeItem(at: audioURL)
        try store.commit(operationID: "later", changes: [StoreChange(.budget, key: "later", value: DailyBudget(id: "later", total: 99))], events: [JournalEvent(kind: "LATER")])
        try BackupArchive.restore(prepared, into: store)
        let restored = try LocalState.load(store: store)
        XCTAssertEqual(restored.budgets.count, 1); XCTAssertEqual(restored.budgets["2026-11-11"]?.total, 1)
        XCTAssertEqual(restored.active?.position, 0); XCTAssertEqual(try store.events().map(\.id), [event.id])
        XCTAssertEqual(try Data(contentsOf: audioURL), audioBytes)
        try store.commit(operationID: "restored-write", changes: [], events: [JournalEvent(kind: "RESTORED")])
        let reopened = try SQLiteStore(url: root.appendingPathComponent("study.sqlite"))
        XCTAssertEqual(try reopened.events().map(\.kind), ["RATE", "RESTORED"])
    }

    func testStudyStepWithoutV3FieldsStillDecodesAsLegacyStep() throws {
        let word = MobileWord(id: "legacy", revision: "r1", catalogID: "c1", word: "legacy", meaning: "旧词",
                              pos: "n.", phonetic: "", category: "required", unit: "Unit 1", printedPage: 1, order: 1,
                              usages: [], parts: [], audioHash: nil, audioUsageKey: nil, audioNote: nil, packageID: nil, inactive: false)
        var source = MeaningLearning.step(word, kind: "recall")
        source.meaningChoices = [MeaningChoice(id: word.id, meaning: "旧词"), MeaningChoice(id: "other", meaning: "其他")]
        source.selectedMeaningID = word.id
        source.recognitionCorrect = true
        source.recognitionMistakes = 1
        source.hintLevel = 2
        source.automaticAudio = true
        source.meaningEvidenceVersion = 3
        source.spellingBeforeRecall = true
        source.meaningFailure = true
        source.relearning = true

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        for key in ["meaningChoices", "selectedMeaningID", "recognitionCorrect", "recognitionMistakes", "hintLevel",
                    "automaticAudio", "meaningEvidenceVersion", "spellingBeforeRecall", "meaningFailure", "relearning"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StudyStep.self, from: legacy)
        XCTAssertEqual(decoded.word, word)
        XCTAssertEqual(decoded.kind, "recall")
        XCTAssertNil(decoded.meaningChoices)
        XCTAssertNil(decoded.selectedMeaningID)
        XCTAssertNil(decoded.recognitionCorrect)
        XCTAssertNil(decoded.meaningEvidenceVersion)
        XCTAssertNil(decoded.relearning)
    }

    func testInvalidKindHashAndUnsafeArchivesAreRejectedBeforeRestore() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try SQLiteStore(url: root.appendingPathComponent("study.sqlite"))
        var state = LocalState()
        try store.commit(operationID: "profile", changes: [StoreChange(.profile, key: "local", value: state.profile)], events: [])
        let source = try BackupArchive.create(store: store, reportBuilder: StudyReport.files, root: root)
        let archive = try Archive(url: source, accessMode: .read)
        for variant in ["kind", "hash", "traversal", "newer"] {
            let target = root.appendingPathComponent(variant + ".zip"), zip = try Archive(url: target, accessMode: .create)
            for entry in archive {
                var data = Data(); _ = try archive.extract(entry) { data.append($0) }
                if entry.path == "manifest.json" {
                    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    if variant == "kind" { object["kind"] = "iword-mobile-content" }
                    if variant == "newer" { object["schemaVersion"] = 999 }
                    if variant == "hash" {
                        var files = object["files"] as! [[String: Any]]; files[0]["sha256"] = String(repeating: "0", count: 64); object["files"] = files
                    }
                    data = try JSONSerialization.data(withJSONObject: object)
                }
                let bytes = data
                try zip.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(bytes.count)) { position, length in bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + length)) }
            }
            if variant == "traversal" { try zip.addEntry(with: "../bad", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([1]) } }
            XCTAssertThrowsError(try BackupArchive.prepareRestore(from: target), variant)
            state = try LocalState.load(store: store)
            XCTAssertEqual(state.profile.id, try store.records(.profile, as: LocalProfile.self).first?.id)
        }
    }
}
