import Foundation
import SwiftUI
import IWordDomain
import IWordStorage
import Combine

@MainActor final class LearningModel: ObservableObject {
    @Published private(set) var state = LocalState()
    @Published private(set) var events: [JournalEvent] = []
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var inStudy = false
    @Published var completed: StudySession?
    @Published var exportURL: URL?
    @Published private(set) var updateIndex: ContentIndex?
    @Published private(set) var updateBusy = false
    @Published private(set) var updateProgress: Double = 0
    @Published private(set) var updateStatus = ""
    @Published private(set) var updateError: String?
    @Published private(set) var backupBusy = false
    @Published private(set) var backupProgress: Double = 0
    @Published private(set) var backupStatus = ""
    @Published private(set) var backupError: String?
    @Published private(set) var serverBackups: [RemoteBackup] = []
    @Published private(set) var localBackups: [URL] = []
    @Published private(set) var restorePreview: PreparedBackup?
    private var backupTask: Task<Void, Never>?
    private var backupClient: MobileContentClient?
    private var backupGeneration = UUID()
    private var updateTask: Task<Void, Never>?
    private var contentClient: MobileContentClient?
    let coach = AICoachController()
    private var coachObservation: AnyCancellable?
    let audio = LocalAudio()
    let medley = MedleyController()
    private var store: SQLiteStore?
    private var stepUptime = ProcessInfo.processInfo.systemUptime
    private var stepWall = Date()
    private var pendingAudio: [JournalEvent] = []
    private var audioObservation: AnyCancellable?
    private var persistenceFailed = false
    private var viewedWordToken = UUID()
    private var playbackSource: String?
    private var practiceAudioToken = UUID()
    @Published var preferencesSavedVersion = 0
    @Published var associationSavedVersion = 0
    @Published var notificationOpened = false

    init() {
        _ = LocalReminder.shared
        audio.onWillPlay = { [weak self] in self?.medley.yieldAudio() }
        medley.player.onWillPlay = { [weak self] in
            guard let self else { return }
            self.viewedWordToken = UUID(); self.practiceAudioToken = UUID()
            self.audio.stop(deactivateSession: false)
        }
        audio.onEvent = { [weak self] kind, fields in
            guard let self else { return }
            var context = fields
            if let source = self.playbackSource { context["source"] = source }
            self.pendingAudio.append(self.event(kind, context))
            self.flushAudioEvents()
        }
        audioObservation = audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        coach.bind(snapshot: { [weak self] in
            guard let self, self.ready else { return nil }; return (self.state, self.events)
        }, persist: { [weak self] archive, kind, fields, expectedIdentity in
            guard let self else { return false }
            while self.busy { do { try await Task.sleep(nanoseconds: 30_000_000); try Task.checkCancellation() } catch { return false } }
            guard self.ready, !self.backupBusy, self.state.profile.id + "|" + self.state.profile.deviceID == expectedIdentity else { return false }
            self.busy = true; defer { self.busy = false; self.flushAudioEvents() }
            var draft = self.state; draft.profile.aiCoach = archive
            return await self.commit(draft, [self.event(kind, fields)])
        })
        coachObservation = coach.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Task { await load() }
    }
    private func event(_ kind: String, _ fields: [String: String] = [:], at: Date = Date()) -> JournalEvent {
        var context = fields
        context["deviceID"] = state.profile.deviceID; context["profileID"] = state.profile.id
        context["ruleVersion"] = "mobile-rule-v3"; context["timeZone"] = "Asia/Shanghai"
        context["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        if let session = state.active, context["source"] == nil || context["source"] == session.mode {
            if context["sessionID"] == nil { context["sessionID"] = session.id }
            if context["source"] == nil { context["source"] = session.mode }
            if let kind = session.reviewKind { context["reviewKind"] = kind }
            if let step = session.current, context["wordID"] == nil || context["wordID"] == step.word.id {
                context["stepID"] = step.id; context["wordID"] = step.word.id; context["contentRevision"] = step.word.revision
                context["stepKind"] = step.kind; context["retry"] = String(step.retry)
            }
        }
        return JournalEvent(kind: kind, fields: context, occurredAt: at)
    }
    private func load() async {
        busy = true
        do {
            let loaded = try await Task.detached { () -> (SQLiteStore, LocalState, [JournalEvent]) in
                let store = try SQLiteStore(url: ContentInstaller.root().appendingPathComponent("study.sqlite"))
                var state = try LocalState.load(store: store)
                let events = try store.events(), previous = state
                LearningHistory.backfill(state: &state, events: events)
                // One-time recovery period; preserve the configured daily limit and all history.
                if state.profile.gentleStartedAt == nil, state.progress.values.contains(where: { $0.learned }) {
                    state.profile.gentleStartedAt = Date()
                }
                let now = Date()
                var migrationEvents: [JournalEvent] = []
                if AssociationLearning.beginIfNeeded(state: &state, now: now) {
                    if try store.records(.profile, as: LocalProfile.self).isEmpty {
                        migrationEvents.append(JournalEvent(kind: "PROFILE_CREATED", fields: [:], occurredAt: now))
                    }
                    migrationEvents.append(JournalEvent(kind: "ASSOCIATION_PLAN_STARTED", fields: [
                        "dailyNewWords": String(state.profile.preferences.dailyNewWords), "ruleVersion": "mobile-association-v1"
                    ], occurredAt: now))
                }
                let changes = try state.changes(from: previous)
                if !changes.isEmpty { try store.commit(operationID: UUID().uuidString, changes: changes, events: migrationEvents) }
                return (store, state, events + migrationEvents)
            }.value
            store = loaded.0; state = loaded.1; events = loaded.2
            // Persist the first local identity before any learning command.
            if try loaded.0.records(.profile, as: LocalProfile.self).isEmpty {
                try loaded.0.commit(operationID: UUID().uuidString, changes: [StoreChange(.profile, key: "local", value: state.profile)], events: [event("PROFILE_CREATED")])
            }
            ready = true
        } catch { message = "无法读取学习档案：\(error.localizedDescription)" }
        busy = false
        if ready { applicationActive() }
        if ready && state.words.isEmpty && ProcessInfo.processInfo.environment["IWORD_UI_TEST_SAMPLE"] == "1" { importSample() }
    }
    private func captureTime(_ session: inout StudySession) {
        guard session.position < session.steps.count else { return }
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, uptime - stepUptime)
        session.steps[session.position].activeMs += Int64(elapsed * 1000)
        if abs(now.timeIntervalSince(stepWall) - elapsed) > 120 { session.steps[session.position].clockAnomaly = true }
        stepUptime = uptime; stepWall = now
    }
    /// Publish only after SQLite commits; storage failure leaves UI and counters at the old step.
    @discardableResult private func commit(_ draft: LocalState, _ journal: [JournalEvent], after: (() -> Void)? = nil) async -> Bool {
        guard let store else { return false }
        let audioEvents = pendingAudio; pendingAudio.removeAll()
        let operation = UUID().uuidString
        let all = (journal + audioEvents).map { event -> JournalEvent in var result = event; result.operationID = operation; return result }
        do {
            let changes = try draft.changes(from: state)
            let accepted = try await Task.detached { try store.commit(operationID: operation, changes: changes, events: all) }.value
            guard accepted else { return false }
            persistenceFailed = false; state = draft; events += all; after?(); return true
        } catch { persistenceFailed = true; pendingAudio.insert(contentsOf: audioEvents, at: 0); message = "保存失败，当前步骤未提交：\(error.localizedDescription)"; return false }
    }
    private func run(_ action: @escaping () async -> Void) {
        guard ready, !busy else { return }; busy = true
        Task { await action(); busy = false; flushAudioEvents() }
    }
    private func flushAudioEvents() {
        guard ready, !busy, !persistenceFailed, !pendingAudio.isEmpty else { return }
        run { await self.commit(self.state, []) }
    }
    func setSlot(_ value: String) { run { var draft = self.state; draft.profile.slot = value; await self.commit(draft, [self.event("SLOT_SELECTED", ["slot": value])]) } }
    func saveBaseURL(_ raw: String) -> Bool {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = ""
        if !raw.isEmpty {
            guard var url = URLComponents(string: raw), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { message = "请填写完整的 https:// 地址，保留部署路径，不包含账号或查询参数。"; return false }
            url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/" : "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            guard let value = url.url else { message = "地址格式不正确。"; return false }; address = value.absoluteString
        }
        let value = address
        cancelUpdate(); contentClient = nil; updateIndex = nil
        cancelBackupTransfer(); backupClient = nil; serverBackups = []
        run { var draft = self.state; draft.profile.serverBaseURL = value; await self.commit(draft, [self.event("SERVER_ADDRESS_CHANGED")]) }
        return true
    }
    func importPackage(_ source: URL) {
        run {
            let accessible = source.startAccessingSecurityScopedResource(); defer { if accessible { source.stopAccessingSecurityScopedResource() } }
            do {
                let (manifest, incoming) = try await Task.detached { try ContentInstaller.install(source) }.value
                if let catalog = self.state.words.first?.catalogID, catalog != manifest.catalogId { throw ContentFailure(message: "这是另一套词库，首版请使用当前红宝书数据集。") }
                var draft = self.state
                Self.mergeContent(manifest: manifest, incoming: incoming, into: &draft)
                await self.commit(draft, [self.event("CONTENT_INSTALLED", ["packageID": manifest.packageId, "revision": manifest.revision, "wordCount": String(incoming.count)])]) {
                    self.message = "已导入\(manifest.title)，共 \(incoming.count) 词，学习进度已保留。"
                }
            } catch { self.message = "导入失败：\(error.localizedDescription)" }
        }
    }
    func importSample() {
        guard let source = Bundle.main.url(forResource: "sample", withExtension: "zip") else { message = "未找到内置样本词条包。"; return }
        importPackage(source)
    }
    /// One unit is replaced as a set; historical states and frozen steps remain in the same transaction.
    static func mergeContent(manifest: MobileManifest, incoming: [MobileWord], into draft: inout LocalState) {
        let ids = Set(incoming.map(\.id))
        let units = Set(incoming.map { $0.category + "\u{0}" + $0.unit })
        var words = Dictionary(uniqueKeysWithValues: draft.words.map { ($0.id, $0) })
        for var word in draft.words where !ids.contains(word.id) {
            if word.packageID == manifest.packageId || (!manifest.packageId.contains("sample") && units.contains(word.category + "\u{0}" + word.unit)) {
                word.inactive = true; words[word.id] = word
            }
        }
        for var word in incoming { word.packageID = manifest.packageId; word.inactive = false; words[word.id] = word }
        draft.words = words.values.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        draft.profile.installedPackages = draft.profile.installedPackages ?? [:]
        draft.profile.installedPackages?[manifest.packageId] = manifest.revision
    }
    func cancelUpdate() {
        updateTask?.cancel()
    }
    func checkUpdates(phone: String, name: String) {
        guard ready, !updateBusy else { return }
        guard let base = URL(string: state.profile.serverBaseURL), base.scheme == "https" else {
            updateError = "请先在设置中填写词库服务器地址。"; return
        }
        let normalized = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: "^(\\+86)?1[3-9][0-9]{9}$", options: .regularExpression) != nil else {
            updateError = "请输入电脑端使用的手机号。"; return
        }
        updateBusy = true; updateError = nil; updateStatus = "正在连接词库服务器…"; updateProgress = 0
        updateTask = Task {
            defer { updateBusy = false; updateTask = nil }
            do {
                let client = MobileContentClient(base: base)
                try await client.connect(phone: normalized, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                let index = try await client.index(); try Task.checkCancellation()
                if let catalog = state.words.first?.catalogID, catalog != index.catalogId { throw ContentFailure(message: "服务器提供另一套词库，当前档案不会自动替换。请核对服务器地址。") }
                contentClient = client; updateIndex = index
                updateStatus = index.packages.isEmpty ? "服务器尚未发布单元。" : "检查完成，选择需要的单元下载。"
            } catch { updateError = Task.isCancelled ? "已取消检查。" : error.localizedDescription; updateStatus = "" }
        }
    }
    func downloadPackage(_ item: RemotePackage) {
        guard ready, !updateBusy, let client = contentClient, let index = updateIndex else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard item.minAppVersion.compare(version, options: .numeric) != .orderedDescending else { updateError = "这个单元需要较新的App，请先升级。"; return }
        updateBusy = true; updateProgress = 0; updateError = nil; updateStatus = "正在下载 \(item.title)…"
        updateTask = Task {
            var downloaded: URL?
            defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded) }; updateBusy = false; updateTask = nil }
            do {
                try ContentInstaller.checkSpace(required: item.bytes + 400 * 1024 * 1024)
                let file = try await client.download(item) { [weak self] progress in
                    Task { @MainActor in self?.updateProgress = progress }
                }
                downloaded = file; try Task.checkCancellation(); updateStatus = "正在校验词条与录音…"
                let validation = Task.detached { () throws -> (MobileManifest, [MobileWord]) in
                    try Task.checkCancellation()
                    guard try ContentInstaller.hash(Data(contentsOf: file, options: .mappedIfSafe)) == item.sha256 else { throw ContentFailure(message: "下载文件校验失败，请重试。") }
                    return try ContentInstaller.install(file)
                }
                let (manifest, incoming) = try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
                try Task.checkCancellation()
                guard manifest.catalogId == index.catalogId, manifest.packageId == item.packageId, manifest.revision == item.revision,
                      incoming.count == item.wordCount else { throw ContentFailure(message: "单元包与服务器索引不一致，请重新检查更新。") }
                // A learning write may finish during the download; never overwrite its newer state.
                while busy { try await Task.sleep(nanoseconds: 30_000_000); try Task.checkCancellation() }
                busy = true; updateStatus = "正在保存到手机…"
                var draft = state; Self.mergeContent(manifest: manifest, incoming: incoming, into: &draft)
                draft.profile.onlinePackages = draft.profile.onlinePackages ?? []
                draft.profile.onlinePackages?.insert(item.packageId)
                let accepted = await commit(draft, [event("CONTENT_DOWNLOADED", ["packageID": item.packageId, "revision": item.revision, "bytes": String(item.bytes)])])
                busy = false; flushAudioEvents()
                guard accepted else { throw ContentFailure(message: "本地保存失败，旧词库仍可使用。") }
                updateStatus = "已更新 \(item.title)，共 \(incoming.count) 词。"; updateProgress = 1
            } catch { updateError = Task.isCancelled ? "已取消，原有词库和进度已保留。" : error.localizedDescription; updateStatus = "" }
        }
    }
    var withdrawnPackageIDs: Set<String> {
        guard let index = updateIndex else { return [] }
        return (state.profile.onlinePackages ?? []).subtracting(index.packages.map(\.packageId))
    }
    func applyWithdrawals() {
        guard !updateBusy, !withdrawnPackageIDs.isEmpty else { return }
        let removed = withdrawnPackageIDs
        run {
            var draft = self.state
            for i in draft.words.indices where draft.words[i].packageID.map({ removed.contains($0) }) == true { draft.words[i].inactive = true }
            for key in removed { draft.profile.installedPackages?.removeValue(forKey: key); draft.profile.onlinePackages?.remove(key) }
            await self.commit(draft, [self.event("CONTENT_WITHDRAWN", ["packageCount": String(removed.count)])])
        }
    }
    func start(review: Bool = false, assessmentOnly: Bool = false, distantMemory: Bool = false) {
        if let active = state.active {
            run {
                var draft = self.state, resumed = active
                self.markAutomaticAudio(&resumed)
                resumed.paused = false; draft.sessions[resumed.id] = resumed
                await self.commit(draft, [self.event("SESSION_RESUMED", ["sessionID": resumed.id])]) { self.enter(resumed) }
            }
            return
        }
        run {
            let now = Date(), day = LocalState.studyDay(now), slot = self.state.profile.slot
            var draft = self.state, steps: [StudyStep] = [], mode = review || distantMemory ? "review" : "standard"
            if review || distantMemory {
                let selected = distantMemory ? LearningSelection.distantMemories(state: draft) : LearningSelection.consolidation(state: draft, now: now, limit: 5)
                steps = MeaningLearning.steps(words: selected, state: draft)
            } else {
                let due = AICoachArchive.prioritizedReviews(LearningSelection.standardReviews(state: draft, now: now, slot: slot), state: draft, now: now)
                let unchecked = draft.availableWords.filter { draft.progress[$0.id]?.familiarity == nil }
                let threshold = min(5, draft.availableWords.count)
                let checked = draft.progress.values.filter { $0.familiarity != nil }.count
                let budget = draft.budgets[day] ?? DailyBudget(id: day)
                let limit = LearningRules.newWordLimit(slot: slot, morningUsed: budget.morning, afternoonUsed: budget.afternoon, dailyUsed: budget.total, dailyLimit: AICoachArchive.effectiveDailyLimit(state: draft, now: now))
                let newWords = LearningSelection.newWords(state: draft)
                if assessmentOnly || (due.isEmpty && !unchecked.isEmpty && (checked < threshold || (limit > 0 && newWords.isEmpty))) {
                    mode = "assessment"; steps = unchecked.prefix(5).map { StudyStep(word: $0, kind: "assessment") }
                } else {
                    var targets = Array(due.prefix(5))
                    let paused = MeaningLearning.pauseNewWords(state: draft, now: now)
                    let fresh = Array(newWords.prefix(paused ? 0 : min(max(0, limit), max(0, 5 - targets.count))))
                    targets += fresh
                    if targets.isEmpty && paused {
                        targets = LearningSelection.consolidation(state: draft, now: now, limit: 5)
                    }
                    steps = MeaningLearning.steps(words: targets, state: draft)
                }
            }
            guard !steps.isEmpty else {
                let learned = draft.availableWords.contains { draft.progress[$0.id]?.learned == true }
                self.message = learned && draft.profile.associationPlanStartedAt != nil
                    ? "这些词刚练过，先留一点回忆间隔。稍后再学，也可以主动选择遥远的记忆或听音串烧。"
                    : review || distantMemory ? "还没有可复习的已学词，请先完成一组学习。" : "暂无到期复习或可学习的新词，可以稍后回来，或进行巩固复习。"
                return
            }
            var session = StudySession(mode: mode, studyDay: day, slot: slot, steps: steps)
            session.ruleVersion = "mobile-rule-v3"
            session.reviewKind = distantMemory ? "distant" : review ? "consolidation" : nil
            self.markAutomaticAudio(&session)
            draft.sessions[session.id] = session; draft.profile.activeSessionID = session.id
            await self.commit(draft, [self.event("SESSION_STARTED", ["sessionID": session.id, "source": mode, "reviewKind": session.reviewKind ?? "", "stepCount": String(steps.count)])]) { self.enter(session) }
        }
    }
    private func enter(_ session: StudySession) {
        medley.yieldAudio()
        completed = nil; inStudy = true; stepUptime = ProcessInfo.processInfo.systemUptime; stepWall = Date()
        playbackSource = nil
        if let step = session.current { audio.play(step.word, twice: true) }
    }
    /// Persist assistance before audio starts. Re-rendering or revealing a meaning does not replay.
    private func markAutomaticAudio(_ session: inout StudySession) {
        guard session.position < session.steps.count, session.steps[session.position].kind == "recall",
              session.steps[session.position].word.audioHash != nil else { return }
        if session.steps[session.position].meaningEvidenceVersion == 3 {
            session.steps[session.position].automaticAudio = true
        } else {
            // Do not reinterpret an already-started legacy attempt.
            session.steps[session.position].audioAssisted = true
        }
    }
    func pause() {
        audio.stop(deactivateSession: !medley.player.isActive)
        run {
            guard var session = self.state.active else { self.inStudy = false; return }
            self.captureTime(&session); session.paused = true
            var draft = self.state; draft.sessions[session.id] = session
            await self.commit(draft, [self.event("SESSION_PAUSED", ["activeMs": String(session.current?.activeMs ?? 0)])]) { self.inStudy = false }
        }
    }
    func suspend() {
        coach.applicationBackgrounded()
        medley.backgrounded()
        if inStudy { pause(); return }
        if medley.player.isActive { return }
        stopPracticeAudio()
    }
    func action(_ kind: String, value: String = "", expectedStepID: String? = nil, expectedPosition: Int? = nil) {
        run {
            guard var session = self.state.active, var step = session.current else { return }
            guard expectedStepID == nil || expectedStepID == step.id else { return }
            if kind == "spell-letter", let position = expectedPosition, position != step.spelling?.position { return }
            self.captureTime(&session); step = session.steps[session.position]; session.paused = false
            let now = Date(); var draft = self.state
            var progress = draft.progress[step.word.id] ?? WordProgress(id: step.word.id)
            var fields: [String: String] = ["value": value, "activeMs": String(step.activeMs), "retry": String(step.retry), "stepKind": step.kind, "familiarity": progress.familiarity ?? "unassessed"]
            var advance = false
            switch kind {
            case "reveal": step.revealed = true; if step.observedAt == nil { step.observedAt = now; step.reactionMs = step.activeMs }
            case "spoken-answer":
                guard let correct = SpokenMeaning.submit(value, to: &step) else { return }
                fields["correct"] = String(correct)
                fields["attempt"] = String(step.spokenAttempts ?? 0)
                fields["recognitionMode"] = "on-device"
                if step.observedAt == nil { step.observedAt = now; step.reactionMs = step.activeMs }
            case "spoken-error":
                guard step.kind == "recall", !step.revealed else { return }
                fields["reason"] = String(value.prefix(200))
                fields["counted"] = "false"
            case "association-view":
                guard (step.kind == "learn" || step.revealed), let note = step.association, note.source == "personal",
                      step.associationViewed != true else { return }
                AssociationLearning.expose(&step, state: &draft, now: now)
                fields["associationVersion"] = note.version
                fields["associationSource"] = note.source
                fields["associationCue"] = note.cue
                fields["associationStory"] = note.story
            case "hint":
                guard step.kind == "recall", !step.revealed else { return }
                step.hinted = true; step.hintLevel = min(2, (step.hintLevel ?? 0) + 1)
                fields["hintLevel"] = String(step.hintLevel ?? 1)
                if let note = step.association, note.source == "personal" {
                    step.associationHintLevel = step.hintLevel
                    fields["associationHintLevel"] = String(step.hintLevel ?? 1)
                    fields["associationVersion"] = note.version
                    fields["associationCue"] = note.cue
                    fields["associationStory"] = note.story
                    AssociationLearning.expose(&step, state: &draft, now: now)
                }
                if step.observedAt == nil { step.observedAt = now; step.reactionMs = step.activeMs }
            case "recognize":
                guard step.kind == "recognition", step.recognitionCorrect != true, (step.recognitionMistakes ?? 0) < 2,
                      step.meaningChoices?.contains(where: { $0.id == value }) == true else { return }
                step.selectedMeaningID = value; step.recognitionCorrect = value == step.word.id
                if step.recognitionCorrect != true { step.recognitionMistakes = (step.recognitionMistakes ?? 0) + 1 }
                fields["correct"] = String(step.recognitionCorrect == true)
                fields["mistakes"] = String(step.recognitionMistakes ?? 0)
            case "recognize-next":
                guard step.kind == "recognition", step.recognitionCorrect == true || (step.recognitionMistakes ?? 0) >= 2 else { return }
                fields["correct"] = String(step.recognitionCorrect == true)
                fields["mistakes"] = String(step.recognitionMistakes ?? 0)
                advance = true
            case "assess":
                guard step.kind == "assessment", ["known", "familiar", "unknown"].contains(value) else { return }
                progress.familiarity = value; fields["recalled"] = value == "known" ? "true" : "false"; advance = true
            case "learn":
                guard step.kind == "learn" else { return }
                if !progress.learned {
                    progress.learned = true; progress.firstLearnedAt = now; progress.schedule = LearningRules.afterLearning(now: now)
                    var budget = draft.budgets[session.studyDay] ?? DailyBudget(id: session.studyDay)
                    budget.total += 1; if session.slot == "morning" { budget.morning += 1 } else { budget.afternoon += 1 }
                    draft.budgets[budget.id] = budget
                } else { progress.schedule.lastContactAt = now }
                advance = true
            case "rate":
                guard step.kind == "recall", step.revealed, let selected = RecallRating(rawValue: value) else { return }
                let rating: RecallRating = step.hinted && [.slow, .easy].contains(selected) ? .hint : selected
                fields["previousContactAt"] = progress.schedule.lastContactAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                let interval = step.observedAt.map { $0.timeIntervalSince(progress.schedule.lastContactAt ?? $0) } ?? 0
                let independent = MeaningLearning.independent(step, rating: rating)
                let assisted = step.meaningEvidenceVersion == 3 ? step.spellingBeforeRecall == true : step.audioAssisted || step.spelling != nil
                let result = LearningRules.afterRecall(state: progress.schedule, rating: rating, hinted: step.hinted, observedAt: step.observedAt ?? now, now: now, voluntary: session.mode == "review" || step.clockAnomaly, audioAssisted: assisted)
                progress.schedule = result.state; progress.latestRating = rating; progress.latestHinted = step.hinted
                fields["rating"] = rating.rawValue; fields["hinted"] = String(step.hinted); fields["audioAssisted"] = String(step.audioAssisted)
                fields["spellingAssisted"] = String(step.meaningEvidenceVersion == 3 ? step.spellingBeforeRecall == true : step.spelling != nil)
                if step.meaningEvidenceVersion == 3 {
                    fields["meaningEvidenceVersion"] = "3"; fields["meaningIndependent"] = String(independent)
                    fields["automaticAudio"] = String(step.automaticAudio == true)
                }
                // A learning card earlier in this frozen round may have introduced this version.
                if let note = step.association {
                    step.associationExposedAt = draft.profile.associationExposureDates?[AssociationLearning.exposureKey(step.word, note: note)]
                }
                fields["associationHintLevel"] = String(step.associationHintLevel ?? 0)
                fields["associationVersion"] = step.association?.version ?? ""
                fields["associationSource"] = step.association?.source ?? ""
                fields["associationExposedAt"] = step.associationExposedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                fields["spokenAttempts"] = String(step.spokenAttempts ?? 0)
                fields["spokenCorrect"] = step.spokenCorrect.map { $0 ? "true" : "false" } ?? ""
                fields["actualIntervalMs"] = String(Int64(max(0, interval) * 1000))
                fields["clockAnomaly"] = String(result.clockAnomaly || step.clockAnomaly)
                fields["reactionMs"] = String(step.reactionMs ?? step.activeMs)
                fields["delayedSuccess"] = String(result.delayedSuccess && session.mode != "review" && !step.clockAnomaly && independent)
                step.meaningFailure = rating == .forgot || rating == .hint
                if step.meaningFailure == true {
                    let followUp = MeaningLearning.followUp(after: step, session: session, state: draft)
                    session.insertFollowUp(followUp)
                    fields["restedAfterFailure"] = String(followUp.count == 1)
                }
                advance = true
            case "spell-start":
                guard step.kind == "recall", step.revealed || session.mode == "review" else { return }
                if !step.revealed { step.spellingBeforeRecall = true }
                step.spelling = SpellingRound(word: step.word.word); step.spellingVisible = true; step.spellingMistakes = 0
            case "spell-close": step.spellingVisible = false
            case "spell-letter":
                guard var round = step.spelling, step.spellingVisible, !round.isComplete, round.choices.contains(value) else { return }
                fields["position"] = String(round.position); fields["choices"] = round.choices.joined()
                let correct = round.choose(value); fields["correct"] = String(correct)
                if !correct { step.spellingMistakes += 1 }
                step.spelling = round; fields["complete"] = String(round.isComplete); fields["mistakes"] = String(step.spellingMistakes)
            default: return
            }
            session.steps[session.position] = step; draft.progress[progress.id] = progress
            if kind == "learn" || kind == "rate" {
                LearningHistory.credit(state: &draft, wordID: step.word.id, source: kind == "learn" && step.relearning != true ? "learn" : session.mode, roundID: session.id, now: now)
            }
            if advance { session.position += 1; self.markAutomaticAudio(&session) }
            if session.position == session.steps.count {
                session.completedAt = now; draft.profile.activeSessionID = nil; draft.profile.latestFinishedID = session.id
            }
            draft.sessions[session.id] = session
            let frozenSession = session
            let eventKind = kind == "association-view" ? "ASSOCIATION_VIEWED" : kind.uppercased()
            await self.commit(draft, [self.event(eventKind, fields)]) {
                if advance {
                    self.audio.stop(deactivateSession: !self.medley.player.isActive); self.stepUptime = ProcessInfo.processInfo.systemUptime; self.stepWall = Date()
                    if frozenSession.completedAt != nil { self.completed = frozenSession; self.inStudy = false }
                    else if let current = frozenSession.current { self.playbackSource = nil; self.audio.play(current.word, twice: true) }
                    if frozenSession.completedAt != nil { self.refreshReminderSchedule() }
                }
            }
        }
    }
    func playWord(_ word: MobileWord, twice: Bool) {
        // Capture the first aid time before starting playback, with the same durable step update.
        run {
            var draft = self.state
            if var session = draft.active, session.current?.kind == "recall", session.current?.word.id == word.id {
                self.captureTime(&session)
                if session.steps[session.position].meaningEvidenceVersion != 3 { session.steps[session.position].audioAssisted = true }
                if session.steps[session.position].observedAt == nil { session.steps[session.position].observedAt = Date(); session.steps[session.position].reactionMs = session.steps[session.position].activeMs }
                draft.sessions[session.id] = session
            }
            await self.commit(draft, [self.event("AUDIO_SELECTED", ["wordID": word.id])]) { self.audio.play(word, twice: twice) }
        }
    }
    func feedback(_ value: String) {
        run {
            guard var session = self.completed else { return }
            session.feedback = value; var draft = self.state; draft.sessions[session.id] = session
            await self.commit(draft, [self.event("SESSION_FEEDBACK", ["sessionID": session.id, "value": value])]) { self.completed = nil }
        }
    }
    func stopViewedWord() { viewedWordToken = UUID(); audio.stop(deactivateSession: !medley.player.isActive) }
    func viewedWord(_ word: MobileWord, source: String = "vocabulary", twice: Bool = true) {
        let token = UUID(); viewedWordToken = token
        audio.stop(deactivateSession: !medley.player.isActive)
        run {
            var draft = self.state
            if var progress = draft.progress[word.id], progress.learned {
                progress.schedule.lastContactAt = Date(); draft.progress[word.id] = progress
            }
            await self.commit(draft, [self.event("WORD_VIEWED", ["wordID": word.id, "contentRevision": word.revision, "source": source])]) {
                guard self.viewedWordToken == token else { return }
                self.playbackSource = source; self.audio.play(word, twice: twice)
            }
        }
    }
    func exportLogs() { exportStudyReport() }
}

private enum ArchiveWork {
    static func run<T>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: action)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

private struct PendingServerBackup: Codable {
    var fileName: String
    var server: String
    var accountHash: String
}

extension LearningModel {
    private func beginBackup(_ action: @escaping () async throws -> Void) {
        guard ready, !busy, !updateBusy, !backupBusy else { return }
        busy = true; backupBusy = true; backupError = nil; backupProgress = 0
        let generation = UUID(); backupGeneration = generation
        backupTask = Task {
            defer {
                if self.backupGeneration == generation {
                    self.backupBusy = false; self.busy = false; self.backupTask = nil; self.flushAudioEvents()
                }
            }
            do { try await action() }
            catch is CancellationError { self.backupStatus = "已取消，当前学习档案未替换。" }
            catch { self.backupError = error.localizedDescription; self.backupStatus = "操作未完成，已有数据仍保留。" }
        }
    }
    func cancelBackupTransfer() { backupTask?.cancel() }
    private func checkpointForBackup() async throws {
        audio.stop(deactivateSession: !medley.player.isActive)
        var draft = state
        if inStudy, var session = draft.active {
            captureTime(&session); session.paused = true; draft.sessions[session.id] = session
        }
        guard await commit(draft, [event("SNAPSHOT_REQUESTED")]) else { throw ContentFailure(message: "学习记录尚未保存，暂不能生成备份。") }
        inStudy = false
    }
    func exportStudyReport() {
        beginBackup {
            self.backupStatus = "正在整理七天报告…"
            try await self.checkpointForBackup()
            guard let store = self.store else { return }
            let root = try ContentInstaller.root()
            let url = try await ArchiveWork.run { try StudyReportExport.create(store: store, root: root) }
            try Task.checkCancellation()
            self.backupStatus = "报告已生成。"; self.exportURL = url
        }
    }
    func createLocalBackup() {
        beginBackup {
            self.backupStatus = "正在保存完整备份与录音…"
            try await self.checkpointForBackup()
            let url = try await self.makeBackup()
            self.backupStatus = "完整备份已保存到本机，可分享保存到“文件”。"
            self.refreshLocalBackups(); self.exportURL = url
        }
    }
    private func makeBackup() async throws -> URL {
        guard let store else { throw ContentFailure(message: "本地档案尚未就绪。") }
        let root = try ContentInstaller.root()
        return try await ArchiveWork.run { try BackupArchive.create(store: store, reportBuilder: StudyReport.files, root: root) }
    }
    func refreshLocalBackups() {
        do {
            let directory = try ContentInstaller.root().appendingPathComponent("backups")
            localBackups = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]))?.filter { $0.pathExtension == "zip" }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left > right
            } ?? []
        } catch { backupError = error.localizedDescription }
    }
    func shareBackup(_ url: URL) { guard !backupBusy else { return }; exportURL = url }
    func previewRestore(_ url: URL) {
        beginBackup {
            self.discardRestorePreview(); self.backupStatus = "正在校验备份…"
            let accessible = url.startAccessingSecurityScopedResource()
            defer { if accessible { url.stopAccessingSecurityScopedResource() } }
            let prepared = try await ArchiveWork.run { try BackupArchive.prepareRestore(from: url) }
            if Task.isCancelled { prepared.cleanup(); throw CancellationError() }
            self.restorePreview = prepared; self.backupStatus = "备份校验通过，请核对后确认恢复。"
        }
    }
    func discardRestorePreview() { restorePreview?.cleanup(); restorePreview = nil }
    func confirmRestore() {
        coach.cancel()
        medley.end()
        guard let prepared = restorePreview else { return }
        beginBackup {
            self.backupStatus = "正在备份当前档案…"
            try await self.checkpointForBackup()
            let rollback = try await self.makeBackup()
            self.refreshLocalBackups()
            try Task.checkCancellation()
            guard let store = self.store else { return }
            self.backupStatus = "正在恢复档案…"
            // After validation, restoration is a non-cancellable atomic SQLite operation.
            try await Task.detached { try BackupArchive.restore(prepared, into: store) }.value
            let loaded = try await Task.detached { (try LocalState.load(store: store), try store.events()) }.value
            self.state = loaded.0; self.events = loaded.1; self.completed = nil; self.inStudy = false
            // A restored branch must not retry an upload captured from the previous local branch.
            let pending = try ContentInstaller.root().appendingPathComponent("pending-server-backup.json")
            try? FileManager.default.removeItem(at: pending)
            var draft = self.state
            LearningHistory.backfill(state: &draft, events: self.events)
            draft.profile.deviceID = UUID().uuidString
            let branch = UUID().uuidString
            var restoreEvents = [self.event("BACKUP_RESTORED", ["backupID": prepared.manifest.backupID, "branchID": branch])]
            if AssociationLearning.beginIfNeeded(state: &draft, now: Date()) {
                restoreEvents.append(self.event("ASSOCIATION_PLAN_STARTED", [
                    "dailyNewWords": String(draft.profile.preferences.dailyNewWords), "ruleVersion": "mobile-association-v1"
                ]))
            }
            guard await self.commit(draft, restoreEvents) else {
                throw ContentFailure(message: "数据已恢复，恢复事件暂未写入；重新打开可读取档案。恢复前备份：\(rollback.lastPathComponent)")
            }
            self.cancelUpdate(); self.contentClient = nil; self.updateIndex = nil; self.backupClient = nil; self.serverBackups = []
            self.discardRestorePreview(); self.refreshLocalBackups(); self.refreshReminderSchedule(); self.coach.applicationActive()
            self.backupStatus = "已恢复。当前档案的恢复前备份仍保存在本机；请只在这部手机继续学习。"
        }
    }
    private func connectBackup(phone: String, name: String) async throws -> MobileContentClient {
        let phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.range(of: "^1[0-9]{10}$", options: .regularExpression) != nil else { throw ContentFailure(message: "请填写11位手机号。") }
        guard let base = URL(string: state.profile.serverBaseURL), base.scheme == "https", base.host != nil else { throw ContentFailure(message: "请先设置词库服务器地址。") }
        let client = MobileContentClient(base: base)
        try await client.connect(phone: phone, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        backupClient = client; return client
    }
    func refreshServerBackups(phone: String, name: String) {
        beginBackup {
            self.backupStatus = "正在连接服务器…"
            let client = try await self.connectBackup(phone: phone, name: name)
            self.serverBackups = try await client.backups()
            self.backupStatus = "服务器保存了 \(self.serverBackups.count) 份备份。"
        }
    }
    func syncToServer(phone: String, name: String) {
        beginBackup {
            self.backupStatus = "正在连接服务器…"
            let client = try await self.connectBackup(phone: phone, name: name)
            let root = try ContentInstaller.root(), pendingFile = root.appendingPathComponent("pending-server-backup.json")
            let account = ContentInstaller.hash(Data(phone.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            var url: URL?
            if let bytes = try? Data(contentsOf: pendingFile), let pending = try? JSONDecoder().decode(PendingServerBackup.self, from: bytes),
               pending.server == self.state.profile.serverBaseURL, pending.accountHash == account,
               pending.fileName == URL(fileURLWithPath: pending.fileName).lastPathComponent {
                let candidate = root.appendingPathComponent("backups/" + pending.fileName)
                if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
            }
            if url == nil {
                self.backupStatus = "正在生成完整学习备份…"
                try await self.checkpointForBackup()
                url = try await self.makeBackup()
                let pending = PendingServerBackup(fileName: url!.lastPathComponent, server: self.state.profile.serverBaseURL, accountHash: account)
                try JSONEncoder().encode(pending).write(to: pendingFile, options: .atomic)
                self.refreshLocalBackups()
            }
            guard let upload = url else { return }
            let prepared = try await ArchiveWork.run { try BackupArchive.prepareRestore(from: upload) }
            defer { prepared.cleanup() }
            let digest = try await ArchiveWork.run { try BackupArchive.fileHash(upload) }
            self.backupStatus = "正在上传，失败后可重试同一份备份…"
            let result = try await client.uploadBackup(upload, id: prepared.manifest.backupID, sha256: digest) { value in
                Task { @MainActor in self.backupProgress = value }
            }
            try? FileManager.default.removeItem(at: pendingFile)
            self.backupProgress = 1
            self.backupStatus = "已同步到服务器 · \(result.wordCount) 词 · \(result.eventCount) 条日志。快照时间：\(result.createdAt)"
            // Upload confirmation is durable before the local journal records success.
            _ = await self.commit(self.state, [self.event("SERVER_BACKUP_CONFIRMED", ["backupID": result.backupID])])
            self.serverBackups = (try? await client.backups()) ?? self.serverBackups
        }
    }
    func downloadServerBackup(_ item: RemoteBackup) {
        beginBackup {
            guard let client = self.backupClient else { throw ContentFailure(message: "请先连接并读取服务器备份。") }
            self.backupStatus = "正在下载服务器备份…"
            let url = try await client.downloadBackup(item) { value in Task { @MainActor in self.backupProgress = value } }
            defer { try? FileManager.default.removeItem(at: url) }
            let prepared = try await ArchiveWork.run { try BackupArchive.prepareRestore(from: url) }
            guard prepared.manifest.backupID == item.backupID, prepared.manifest.profileID == item.profileID else { prepared.cleanup(); throw ContentFailure(message: "备份身份与服务器索引不一致。") }
            if Task.isCancelled { prepared.cleanup(); throw CancellationError() }
            self.discardRestorePreview(); self.restorePreview = prepared
            self.backupStatus = "备份已下载并校验，确认后才会恢复。"
        }
    }
}


extension LearningModel {
    func practiceCommand(_ kind: String, _ mutation: @escaping (inout LocalState) throws -> [String: String]) {
        guard !inStudy, completed == nil, !updateBusy else { message = "请先暂停当前学习或结束本组，再进入练习。"; return }
        run {
            do {
                var draft = self.state
                let previous = draft.profile.practiceRound
                var fields = try mutation(&draft)
                if let round = draft.profile.practiceRound {
                    try round.validate()
                    let old = previous?.id == round.id ? previous?.creditedWordIDs ?? [] : []
                    var contacts = round.creditedWordIDs.subtracting(old)
                    if fields["correct"] == "true", let wordID = fields["wordID"], round.creditedWordIDs.contains(wordID) { contacts.insert(wordID) }
                    for wordID in contacts {
                        LearningHistory.credit(state: &draft, wordID: wordID, source: "practice", roundID: round.id, now: Date())
                    }
                    fields["practiceID"] = round.id
                }
                fields["source"] = "practice"
                await self.commit(draft, [self.event(kind.hasPrefix("PRACTICE_") ? kind : "PRACTICE_" + kind.uppercased(), fields)])
            } catch { self.message = error.localizedDescription }
        }
    }
    func playPracticeWord(_ word: MobileWord, automatic: Bool) {
        let token = UUID(); practiceAudioToken = token
        Task {
            while self.busy {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard self.practiceAudioToken == token else { return }
            }
            guard self.practiceAudioToken == token, !self.inStudy else { return }
            self.run {
                await self.commit(self.state, [self.event("PRACTICE_AUDIO", ["source": "practice", "wordID": word.id, "automatic": String(automatic)])]) {
                    guard self.practiceAudioToken == token else { return }
                    self.playbackSource = "practice"; self.audio.play(word, twice: automatic)
                }
            }
        }
    }
    func stopPracticeAudio() { practiceAudioToken = UUID(); audio.stop(deactivateSession: !medley.player.isActive) }
    func applicationActive() {
        guard ready else { return }
        coach.applicationActive()
        LocalReminder.shared.onOpen = { [weak self] in
            self?.notificationOpened = true
            self?.setSlot("evening")
        }
        if LocalReminder.shared.openRequested { LocalReminder.shared.openRequested = false; notificationOpened = true; setSlot("evening") }
        refreshReminderSchedule()
    }
    func refreshReminderSchedule() {
        let snapshot = state
        Task { await LocalReminder.shared.refresh(state: snapshot) }
    }
    func saveLearningPreferences(_ preferences: LearningPreferences) {
        run {
            var preferences = preferences
            guard (0...50).contains(preferences.dailyNewWords), ["sequential", "recommended"].contains(preferences.order),
                  (0...23).contains(preferences.reminderHour), (0...59).contains(preferences.reminderMinute) else {
                self.message = "请检查学习数量和提醒时间。"; return
            }
            if preferences.reminderEnabled, !(await LocalReminder.shared.authorize()) {
                preferences.reminderEnabled = false
                self.message = "通知尚未获准，其余偏好已保存。如需提醒，可在手机设置中允许iWord通知后重新开启。"
            }
            var draft = self.state; draft.profile.learningPreferences = preferences
            await self.commit(draft, [self.event("PREFERENCES_SAVED", ["dailyNewWords": String(preferences.dailyNewWords), "order": preferences.order])]) {
                self.preferencesSavedVersion += 1; self.refreshReminderSchedule()
            }
        }
    }
}

extension LearningModel {
    func association(for word: MobileWord) -> PersonalAssociation? {
        AssociationLearning.note(for: word, state: state)
    }

    func saveAssociation(_ input: PersonalAssociation, for word: MobileWord) {
        guard input.valid else { message = "字形分段最多100字、线索最多200字、联想最多500字。"; return }
        run {
            var note = input
            note.chunks = note.chunks.trimmingCharacters(in: .whitespacesAndNewlines)
            note.cue = note.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            note.story = note.story.trimmingCharacters(in: .whitespacesAndNewlines)
            if note.cue.isEmpty && !note.story.isEmpty {
                note.cue = note.chunks.isEmpty ? "想想你为这个词写下的联想画面。" : "看看这个分段：" + note.chunks
            }
            note.source = "personal"; note.version = UUID().uuidString; note.updatedAt = Date()
            var draft = self.state
            var notes = draft.profile.associationNotes ?? [:]
            notes[AssociationLearning.key(word)] = note; draft.profile.associationNotes = notes
            // New notes are used in future rounds. Already-frozen questions keep their version.
            await self.commit(draft, [self.event("ASSOCIATION_SAVED", [
                "source": "association", "wordID": word.id, "associationVersion": note.version,
                "associationSource": note.source, "associationCue": note.cue, "associationStory": note.story
            ])]) { self.associationSavedVersion += 1 }
        }
    }
}
