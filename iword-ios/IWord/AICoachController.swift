import Foundation
import Combine
import UIKit
import IWordStorage

/// Owns one direct AI operation at a time. Learning commands remain owned by LearningModel.
@MainActor final class AICoachController: ObservableObject {
    @Published private(set) var configuration: AICoachConfiguration?
    @Published private(set) var running = false
    @Published private(set) var syncing = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    private var snapshot: (() -> (LocalState, [IWordStorage.JournalEvent])?)?
    private var persist: ((AICoachArchive, String, [String: String], String) async -> Bool)?
    private var task: Task<Bool, Never>?
    private var syncTask: Task<Void, Never>?
    private var foregroundTimer: Task<Void, Never>?
    private var token = UUID()
    private var lastAutomaticAttempt: Date?
    private var configured = false

    func bind(snapshot: @escaping () -> (LocalState, [IWordStorage.JournalEvent])?,
              persist: @escaping (AICoachArchive, String, [String: String], String) async -> Bool) {
        self.snapshot = snapshot; self.persist = persist
        guard !configured else { return }
        configured = true
        do { configuration = try AICoachKeychain.load() }
        catch { self.error = "AI配置暂时无法读取，请解锁后重新打开或更新配置。" }
        AICoachBackground.register(execute: { [weak self] in await self?.performDueAnalysis() ?? false },
                                   cancel: { [weak self] in self?.cancel() })
    }
    func updateConfiguration(baseURL: String, phone: String, name: String) {
        guard !syncing, !running else { return }
        guard let base = URL(string: baseURL), base.scheme == "https", base.host != nil else {
            error = "请先设置词库服务器地址。"; return
        }
        let phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.range(of: "^(\\+86)?1[3-9][0-9]{9}$", options: .regularExpression) != nil else {
            error = "请输入电脑端使用的手机号。"; return
        }
        syncing = true; error = nil; status = "正在更新AI配置…"
        syncTask = Task {
            defer { syncing = false; syncTask = nil }
            do {
                let client = MobileContentClient(base: base)
                try await client.connect(phone: phone, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                let incoming = try await client.aiConfiguration()
                try Task.checkCancellation()
                try AICoachKeychain.save(incoming)
                configuration = incoming
                status = "AI配置已更新。电脑端关闭后仍可分析。"
                schedule()
            } catch {
                status = ""
                self.error = "配置更新未完成。请检查服务器连接、手机号与后台密钥；原配置保留。"
            }
        }
    }
    func removeConfiguration() {
        guard !syncing else { return }
        cancel()
        do {
            try AICoachKeychain.remove(); configuration = nil
            status = "本机AI配置已删除，学习报告保留。"; error = nil
            AICoachBackground.schedule(enabled: false)
        } catch { self.error = "本机AI配置未能删除，请解锁后重试。" }
    }
    func cancel() { task?.cancel(); token = UUID() }
    func manualAnalysis() {
        guard !running, !syncing else { return }
        Task { _ = await analyze(automatic: false) }
    }
    func performDueAnalysis(now: Date = Date()) async -> Bool {
        defer { schedule() }
        guard let (state, _) = snapshot?(), state.profile.aiCoach?.automaticEnabled == true,
              configuration != nil else { return false }
        let cutoff = AICoachBackground.cutoff(now: now)
        if let enabledAt = state.profile.aiCoach?.automaticEnabledAt, cutoff < enabledAt { return true }
        if let latest = state.profile.aiCoach?.latest, latest.createdAt >= cutoff { return true }
        guard !running, !syncing, !saving else { return false }
        if lastAutomaticAttempt == cutoff { return false }
        lastAutomaticAttempt = cutoff
        return await analyze(automatic: true)
    }
    func applicationActive() {
        if configuration == nil { configuration = try? AICoachKeychain.load() }
        schedule()
        guard let (state, _) = snapshot?(), state.profile.aiCoach?.automaticEnabled == true else { return }
        Task { _ = await performDueAnalysis() }
        foregroundTimer?.cancel()
        foregroundTimer = Task {
            let seconds = max(1, AICoachBackground.nextDate(now: Date()).timeIntervalSinceNow)
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            _ = await performDueAnalysis()
            applicationActive()
        }
    }
    func applicationBackgrounded() { foregroundTimer?.cancel(); foregroundTimer = nil; schedule() }
    private func schedule() {
        let enabled = snapshot?()?.0.profile.aiCoach?.automaticEnabled == true && configuration != nil
        AICoachBackground.schedule(enabled: enabled)
    }
    func setAutomatic(_ enabled: Bool) {
        guard !saving, let (state, _) = snapshot?() else { return }
        guard !enabled || configuration != nil else { error = "请先更新AI配置。"; return }
        var archive = state.profile.aiCoach ?? AICoachArchive(); archive.automaticEnabled = enabled
        archive.automaticEnabledAt = enabled ? Date() : nil
        if enabled, LocalState.studyDay(AICoachBackground.cutoff(now: Date())) == LocalState.studyDay(Date()) {
            archive.automaticEnabledAt = AICoachBackground.cutoff(now: Date())
        }
        save(archive, kind: "AI_COACH_AUTOMATIC", fields: ["automatic": String(enabled)]) { [weak self] in
            self?.lastAutomaticAttempt = nil; self?.applicationActive()
        }
    }
    private func analyze(automatic: Bool) async -> Bool {
        guard !running, !syncing, let configuration, let (state, events) = snapshot?() else {
            error = "请先更新AI配置，待本地档案就绪后再分析。"; return false
        }
        guard state.progress.values.contains(where: { $0.learned }) else {
            error = "先完成一组学习，再根据实际记录生成分析。"; return false
        }
        let now = Date(), identity = state.profile.id + "|" + state.profile.deviceID
        let requestToken = UUID(); token = requestToken
        running = true; error = nil; status = "正在整理近3天学习证据…"
        task = Task<Bool, Never> {
            await executeAnalysis(state: state, events: events, configuration: configuration,
                                  now: now, identity: identity, requestToken: requestToken, automatic: automatic)
        }
        return await task?.value ?? false
    }
    private func executeAnalysis(state: LocalState, events: [JournalEvent], configuration: AICoachConfiguration,
                                 now: Date, identity: String, requestToken: UUID, automatic: Bool) async -> Bool {
            var backgroundID: UIBackgroundTaskIdentifier = .invalid
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "AI学习分析") { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
            defer {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
                running = false; task = nil
            }
            do {
                var input = AICoachEngine.makeInput(state: state, events: events, now: now)
                if let previous = state.profile.aiCoach?.latest {
                    let answered = previous.attempts.values.filter(\.complete)
                    let adopted = state.profile.aiCoach?.adoptedPlan?.reportID == previous.id
                    let correctCount = answered.filter { $0.firstCorrect == true }.count
                    let outcome = "；上次针对性练习完成\(answered.count)题，首次正确\(correctCount)题。"
                    let history = "上次报告：" + previous.report.analysisSummary + "；上次计划已采用：" + String(adopted)
                    input.previousAnalysis = String((history + outcome).prefix(2000))
                }
                let fingerprint = input.fingerprint
                if state.profile.aiCoach?.reports.contains(where: { $0.fingerprint == fingerprint && $0.configurationVersion == configuration.version }) == true {
                    status = "这份学习数据已经分析过，可查看已有报告。"; return true
                }
                try Task.checkCancellation()
                status = "AI正在分析并安排练习，请留在前台等待…"
                let validated = try await AICoachEngine.requestValidated(configuration: configuration, input: input)
                try Task.checkCancellation()
                guard token == requestToken, let (current, _) = snapshot?(),
                      current.profile.id + "|" + current.profile.deviceID == identity else { throw CancellationError() }
                status = "正在校验报告和练习答案…"
                let ids = Set(input.words.map(\.wordID))
                let frozen = state.availableWords.filter { ids.contains($0.id) }
                let saved = SavedCoachReport(createdAt: Date(), dataThrough: now, fingerprint: fingerprint,
                                             configurationVersion: configuration.version, report: validated.report,
                                             words: frozen, validationNotes: validated.notes)
                var archive = current.profile.aiCoach ?? AICoachArchive()
                archive.reports.insert(saved, at: 0); archive.reports = Array(archive.reports.prefix(14))
                try archive.validate(); try Task.checkCancellation()
                guard token == requestToken,
                      await persist?(archive, "AI_COACH_ANALYZED", ["reportID": saved.id, "automatic": String(automatic), "count": String(saved.report.exercises.count)], identity) == true else {
                    throw ContentFailure(message: "报告尚未保存，请稍后重试。")
                }
                status = "分析已保存，报告和练习可离线使用。"
                return true
            } catch {
                status = ""
                if Task.isCancelled || token != requestToken {
                    self.error = "分析已中断，原报告保留，可手动重试。"
                } else if let failure = error as? AICoachFailure {
                    self.error = failure.localizedDescription + " 原报告保留。"
                } else {
                    self.error = "分析未完成。请检查AI配置和网络后重试；原报告保留。"
                }
                return false
            }
    }
    func adopt(_ saved: SavedCoachReport) {
        guard !saving, let (state, _) = snapshot?() else { return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = LocalState.studyDay(calendar.date(byAdding: .day, value: 1, to: saved.dataThrough)!)
        guard day >= LocalState.studyDay(Date()) else { error = "这份报告的计划日期已过，请生成新报告。"; return }
        let plan = saved.report.tomorrowPlan
        let count = max(0, min(state.profile.preferences.dailyNewWords, plan.morning.newWordCount + plan.afternoon.newWordCount))
        var seen: Set<String> = []
        let ids = (plan.morning.reviewWordIDs + plan.afternoon.reviewWordIDs + plan.evening.reviewWordIDs).filter { seen.insert($0).inserted }
        var archive = state.profile.aiCoach ?? AICoachArchive()
        archive.adoptedPlan = AdoptedCoachPlan(reportID: saved.id, day: day, dailyNewWords: count, reviewWordIDs: Array(ids.prefix(60)),
                                               morningReviewIDs: plan.morning.reviewWordIDs, afternoonReviewIDs: plan.afternoon.reviewWordIDs, eveningReviewIDs: plan.evening.reviewWordIDs)
        save(archive, kind: "AI_COACH_PLAN_ADOPTED", fields: ["reportID": saved.id, "dailyNewWords": String(count)])
    }
    func clearPlan() {
        guard let (state, _) = snapshot?() else { return }
        var archive = state.profile.aiCoach ?? AICoachArchive(); archive.adoptedPlan = nil
        save(archive, kind: "AI_COACH_PLAN_CLEARED")
    }
    func hint(reportID: String, exerciseID: String) {
        editExercise(reportID: reportID, exerciseID: exerciseID, kind: "AI_PRACTICE_HINT") { progress, question in
            guard !progress.complete, !progress.revealed, question.hint?.isEmpty == false else { return }
            progress.hintUsed = true
        }
    }
    func reveal(reportID: String, exerciseID: String) {
        editExercise(reportID: reportID, exerciseID: exerciseID, kind: "AI_PRACTICE_REVEALED") { progress, _ in
            progress.revealed = true
        }
    }
    func answer(reportID: String, exerciseID: String, choiceIndex: Int? = nil, spelling: String? = nil, recalled: Bool? = nil) {
        editExercise(reportID: reportID, exerciseID: exerciseID, kind: "AI_PRACTICE_ANSWER") { progress, question in
            progress.answer(question, choiceIndex: choiceIndex, spelling: spelling, recalled: recalled)
        }
    }
    private func editExercise(reportID: String, exerciseID: String, kind: String,
                              edit: (inout CoachExerciseProgress, AICoachExercise) -> Void) {
        guard !saving, let (state, _) = snapshot?() else { return }
        var archive = state.profile.aiCoach ?? AICoachArchive()
        guard let index = archive.reports.firstIndex(where: { $0.id == reportID }),
              let question = archive.reports[index].report.exercises.first(where: { $0.id == exerciseID }) else { return }
        var progress = archive.reports[index].attempts[exerciseID] ?? CoachExerciseProgress()
        let old = progress; edit(&progress, question)
        guard old != progress else { return }
        archive.reports[index].attempts[exerciseID] = progress
        save(archive, kind: kind, fields: ["reportID": reportID, "questionID": exerciseID, "wordID": question.wordID,
                                          "exerciseKind": question.kind.rawValue, "hinted": String(progress.hintUsed == true), "correct": String(progress.lastCorrect == true),
                                          "firstCorrect": String(progress.firstCorrect == true), "attempt": String(progress.attempts), "completed": String(progress.complete)])
    }
    private func save(_ archive: AICoachArchive, kind: String, fields: [String: String] = [:], after: (() -> Void)? = nil) {
        guard !saving, !running, let (state, _) = snapshot?() else { return }; saving = true; error = nil
        let identity = state.profile.id + "|" + state.profile.deviceID
        Task {
            defer { saving = false }
            do {
                try archive.validate()
                guard await persist?(archive, kind, fields, identity) == true else { throw ContentFailure(message: "保存失败。") }
                after?()
            } catch { self.error = "尚未保存，请稍后重试。" }
        }
    }
}
