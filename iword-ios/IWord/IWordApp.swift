import SwiftUI
import UniformTypeIdentifiers
import IWordDomain
import IWordStorage
import UIKit

@main struct IWordApp: App {
    @StateObject private var model = LearningModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(model.medley).environmentObject(model.medley.player)
                .onChange(of: scenePhase) { phase in if phase != .active { model.suspend() } else { model.applicationActive() } }
        }
    }
}

enum Palette {
    static let ink = Color(red: 0.09, green: 0.17, blue: 0.27)
    static let muted = Color(red: 0.46, green: 0.51, blue: 0.60)
    static let blue = Color(red: 0.16, green: 0.33, blue: 0.85)
    static let pale = Color(red: 0.92, green: 0.94, blue: 1)
    static let paper = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let line = Color(red: 0.88, green: 0.91, blue: 0.95)
}
struct PrimaryButton: View {
    var title: String
    var white = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { HStack { Text(title); Image(systemName: "arrow.right") }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 50) }
            .foregroundColor(white ? Palette.blue : .white).background(white ? Color.white : Palette.blue).cornerRadius(15).accessibilityLabel(title)
    }
}
struct RootView: View {
    @EnvironmentObject var model: LearningModel
    @EnvironmentObject var medleyPlayer: MedleyPlayer
    @State private var medleyPresented = false
    @State private var tab = "home"
    @State private var sheet: AppSheet?
    @State private var word: MobileWord?
    @State private var importer = false
    @State private var share = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("iWord").font(.system(size: 24, weight: .bold, design: .serif)) + Text(".").foregroundColor(Palette.blue).font(.title.bold())
                Spacer()
                HStack(spacing: 4) { Circle().fill(Color(red: 0.2, green: 0.5, blue: 0.4)).frame(width: 5, height: 5); Text("离线可用").font(.system(size: 10)).foregroundColor(Palette.muted) }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 14)
            if !model.ready {
                Spacer(); if model.busy { ProgressView("正在读取本地档案") } else { Text("档案暂时无法读取，请重新打开应用。").font(.callout).padding() }; Spacer()
            } else if model.inStudy, let session = model.state.active, let step = session.current {
                StudyFlow(session: session, step: step).id(session.id)
            } else if let completed = model.completed {
                FinishView(session: completed)
            } else {
                Group {
                    switch tab {
                    case "words": WordsView { word = $0 }
                    case "records": RecordsView()
                    case "practice": PracticeHomeView()
                    case "settings": SettingsView(show: { sheet = $0 }, importAction: { importer = true })
                    default: HomeView(openRecords: { tab = "records" }, openCoach: { sheet = .coach }, importAction: { sheet = .updates }, openMedley: { medleyPresented = true })
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if medleyPlayer.isActive { MedleyMiniPlayer(open: { medleyPresented = true }) }
                HStack(spacing: 0) {
                    tabButton("home", "house", "今天"); tabButton("words", "book", "词库")
                    tabButton("practice", "square.grid.2x2", "练习"); tabButton("records", "chart.bar", "记录"); tabButton("settings", "slider.horizontal.3", "设置")
                }.padding(.top, 12).padding(.bottom, 6).background(Color.white)
                    .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .top)
            }
        }.foregroundColor(Palette.ink).background(Palette.paper.ignoresSafeArea())
            .tint(Palette.blue).disabled(model.busy && !model.backupBusy)
            .overlay(alignment: .top) { if model.busy && model.ready && !model.backupBusy { ProgressView().padding(10).background(Color.white).clipShape(Capsule()).padding(.top, 4) } }
            .fullScreenCover(isPresented: $medleyPresented) { MedleyScreen() }
            .sheet(item: $sheet) { kind in
                SheetContainer(title: kind.title) {
                    switch kind {
                    case .coach: AICoachView(coach: model.coach)
                    case .coachConfig: AICoachConfigurationView(coach: model.coach)
                    case .preferences: LearningPreferencesView()
                    case .report: ReportView()
                    case .backups: LocalBackupView()
                    case .sync: ServerSyncView()
                    case .server: ServerAddressView()
                    case .updates: UpdatesView(importAction: { sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { importer = true } }, sampleAction: { sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.importSample() } })
                    case .audio: Text("单词使用本地原书录音。学习进入时慢速一遍、适中一遍；小喇叭可重播。例句使用系统英语声音，默认慢速。").font(.callout).lineSpacing(7)
                    case .schedule: Text("早上、下午、晚上各留40分钟。先完成到期复习，按学习偏好把每日新词分配到早上和下午，晚上复习当天所学。当天学完后，可继续巩固或进行练习。").font(.callout).lineSpacing(7)
                    }
                }.environmentObject(model)
            }
            .sheet(item: $word) { value in SheetContainer(title: "查看词条") { WordDetail(word: value) }.environmentObject(model) }
            .sheet(isPresented: $share) { if let url = model.exportURL { ShareView(url: url) } }
            .onChange(of: model.notificationOpened) { opened in if opened { tab = "home"; sheet = nil; word = nil; model.notificationOpened = false } }
            .onChange(of: model.exportURL) { url in if url != nil { sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { share = true } } }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result { case .success(let urls): if let first = urls.first { model.importPackage(first) }; case .failure(let error): model.message = "未导入：\(error.localizedDescription)" }
            }
            .alert("提示", isPresented: Binding(get: { model.message != nil || model.audio.notice != nil }, set: { if !$0 { model.message = nil; model.audio.notice = nil } })) {
                Button("知道了", role: .cancel) { model.message = nil; model.audio.notice = nil }
            } message: { Text(model.message ?? model.audio.notice ?? "") }
    }
    private func tabButton(_ key: String, _ symbol: String, _ text: String) -> some View {
        Button { tab = key } label: { VStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 20)); Text(text).font(.system(size: 10)) }.frame(maxWidth: .infinity).frame(minHeight: 42) }.foregroundColor(tab == key ? Palette.blue : Palette.muted).accessibilityIdentifier("tab-" + key)
    }
}
enum AppSheet: String, Identifiable {
    case server, updates, audio, schedule, report, backups, sync, preferences, coach, coachConfig
    var id: String { rawValue }
    var title: String { switch self { case .coach: return "AI学习教练"; case .coachConfig: return "AI调用配置"; case .preferences: return "学习偏好"; case .report: return "七天报告"; case .backups: return "备份与恢复"; case .sync: return "同步到服务器"; case .server: return "词库服务器地址"; case .updates: return "词库更新"; case .audio: return "单词朗读"; case .schedule: return "每日学习安排" } }
}
struct SheetContainer<Content: View>: View {
    @EnvironmentObject var model: LearningModel
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭").accessibilityIdentifier("sheet-close-" + title) }.padding(.horizontal, 24).padding(.top, 10)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 20, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
        }.background(Palette.paper.ignoresSafeArea()).foregroundColor(Palette.ink).tint(Palette.blue).onDisappear { model.audio.stop(deactivateSession: !model.medley.player.isActive) }
    }
}
struct HomeView: View {
    @EnvironmentObject var model: LearningModel
    var openRecords: () -> Void
    var openCoach: () -> Void
    var importAction: () -> Void
    var openMedley: () -> Void
    private var checked: Int { model.state.progress.values.filter { $0.familiarity != nil }.count }
    private var learned: Int { model.state.progress.values.filter(\.learned).count }
    private var due: Int { model.state.progress.values.filter { $0.learned && ($0.schedule.dueAt ?? .distantFuture) <= Date() }.count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text(greeting + "，给记忆一点时间。").font(.system(size: 22, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    slot("morning", "早上", "sun.max"); slot("afternoon", "下午", "cloud"); slot("evening", "晚上", "moon")
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(model.state.active == nil ? "红宝书 · 本地词库" : "接着刚才的位置"); Spacer(); Text("\(model.state.availableWords.count) 词") }.font(.system(size: 11)).foregroundColor(.white.opacity(0.8))
                    Text(model.state.availableWords.isEmpty ? "先把词库留在手机里。" : model.state.active != nil ? "不必从头再来。" : due > 0 ? "再遇见，\n让记忆慢慢扎实。" : "先认一遍，\n把时间留给陌生词。").font(.system(size: 21, weight: .semibold)).lineSpacing(4)
                    Text(model.state.availableWords.isEmpty ? "从文件导入词条与原书录音。" : MeaningLearning.pauseNewWords(state: model.state, now: Date()) ? "先巩固旧词，暂不加新词" : "每组最多5个词，先复习再学新词").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                    PrimaryButton(title: model.state.availableWords.isEmpty ? "导入词库" : model.state.active?.reviewKind == "distant" ? "继续遥远的记忆" : model.state.active?.mode == "review" ? "继续复习" : model.state.active != nil ? "继续学习" : "开始这一组", white: true) { if model.state.availableWords.isEmpty { importAction() } else { model.start() } }
                }.padding(21).background(Palette.blue).foregroundColor(.white).cornerRadius(23)
                HStack { Text("今天的脚步"); Spacer(); Button("查看记录", action: openRecords).foregroundColor(Palette.blue) }.font(.system(size: 13))
                HStack(spacing: 0) { Stat(value: checked, label: "已经认过"); Stat(value: learned, label: "累计学过"); Stat(value: due, label: "到期复习") }
                Button { model.start(review: true) } label: {
                    HStack { Text("巩固复习").font(.system(size: 14, weight: .semibold)); Text(model.state.progress.values.contains(where: { $0.learned }) ? model.state.weakWords.isEmpty ? "抽取已学词再巩固 · 不加新词" : "\(model.state.weakWords.count) 个薄弱词优先 · 不加新词" : "先完成一组新词学习").font(.system(size: 11)).foregroundColor(Palette.muted); Spacer(minLength: 4); Image(systemName: "arrow.right").font(.system(size: 14)) }.frame(minHeight: 44)
                }.disabled(!model.state.availableWords.contains(where: { model.state.progress[$0.id]?.learned == true }) && model.state.active == nil).foregroundColor(Palette.blue)
                    .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .top).accessibilityIdentifier("start-review")
                Button { model.start(distantMemory: true) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("遥远的记忆").font(.system(size: 14, weight: .semibold))
                            Text("最久未学的10个词 · 不加新词").font(.system(size: 11)).foregroundColor(Palette.muted)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right").font(.system(size: 14))
                    }.frame(minHeight: 52).contentShape(Rectangle())
                }.disabled(!model.state.availableWords.contains(where: { model.state.progress[$0.id]?.learned == true }) && model.state.active == nil)
                    .foregroundColor(Palette.blue).accessibilityIdentifier("start-distant-memory")
                Button(action: openCoach) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI学习教练").font(.system(size: 14, weight: .semibold))
                            Text(model.coach.running ? "正在分析学习记录…" : model.state.profile.aiCoach?.latest == nil ? "找出重点词，安排针对性练习" : "查看学习分析与下一步安排")
                                .font(.system(size: 11)).foregroundColor(Palette.muted)
                        }
                        Spacer(); Image(systemName: "arrow.right").font(.system(size: 14))
                    }.padding(.vertical, 8)
                }.foregroundColor(Palette.blue).accessibilityIdentifier("open-ai-coach")
                Button(action: openMedley) {
                    HStack(spacing: 12) {
                        Image(systemName: "headphones").font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("听音串烧").font(.system(size: 14, weight: .semibold))
                            Text("躺下来，听英文与中文释义").font(.system(size: 11)).foregroundColor(Palette.muted)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "play.fill").font(.system(size: 14))
                    }.padding(16).frame(maxWidth: .infinity).background(Palette.pale).cornerRadius(16)
                }.buttonStyle(.plain).foregroundColor(Palette.blue).accessibilityIdentifier("open-medley")
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
        }
    }
    private var greeting: String { model.state.profile.slot == "morning" ? "早上好" : model.state.profile.slot == "afternoon" ? "下午好" : "晚上好" }
    private func slot(_ key: String, _ text: String, _ symbol: String) -> some View {
        let selected = model.state.profile.slot == key
        return Button { model.setSlot(key) } label: { HStack(spacing: 6) { Image(systemName: symbol); VStack(spacing: 4) { Text(text); Text("40 分钟").font(.system(size: 10)).foregroundColor(Palette.muted) } }.font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 52) }.background(selected ? Palette.pale : Color.white.opacity(0.6)).cornerRadius(14).overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Palette.blue.opacity(0.25) : Palette.line)).foregroundColor(selected ? Palette.blue : Palette.ink)
    }
}
struct Stat: View {
    var value: Int
    var label: String
    var body: some View { VStack(alignment: .center, spacing: 7) { Text(String(value)).font(.system(size: 28, weight: .medium, design: .serif)); Text(label).font(.system(size: 11)).foregroundColor(Palette.muted) }.multilineTextAlignment(.center).frame(maxWidth: .infinity, alignment: .center) }
}
struct StudyFlow: View {
    @EnvironmentObject var model: LearningModel
    @StateObject private var speech = ChineseSpeechCapture()
    @State private var editingAssociation = false
    var session: StudySession
    var step: StudyStep
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { speech.cancel(); model.pause() } label: { Image(systemName: "chevron.left").frame(width: 38, height: 38).background(Color.white).clipShape(Circle()) }.accessibilityLabel("返回今天")
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13)); Text(subtitle).font(.system(size: 10)).foregroundColor(Palette.muted) }
                Spacer(minLength: 3); Text("已完成 \(session.completedWordCount) / \(session.totalWordCount) 词").accessibilityIdentifier("study-word-progress").font(.system(size: 10)).foregroundColor(Palette.muted)
            }.padding(.horizontal, 20).padding(.bottom, 12)
            ProgressView(value: Double(session.completedWordCount), total: Double(max(1, session.totalWordCount))).padding(.horizontal, 24).tint(Palette.blue)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    HStack { Text(step.kind == "learn" || step.relearning == true ? "学一学" : step.kind == "recognition" ? "认一认" : step.kind == "assessment" ? "先看单词" : session.mode == "review" ? "再想一次" : "回忆一下"); Spacer(); Text(step.kind == "recognition" ? "辨认" : step.kind == "learn" || step.relearning == true ? "理解" : "不着急").padding(6).background(Palette.pale).cornerRadius(6) }.font(.system(size: 11)).foregroundColor(Palette.muted)
                    if step.spellingVisible, let spelling = step.spelling {
                        SpellingView(round: spelling, mistakes: step.spellingMistakes, word: step.word, stepID: step.id).id(step.id)
                    } else {
                        HStack(spacing: 12) {
                            if canSpell { Button { model.action("spell-start", expectedStepID: step.id) } label: { wordTitle }.buttonStyle(.plain).accessibilityLabel("开始拼写练习").accessibilityValue(step.word.word).accessibilityIdentifier("study-word") }
                            else { wordTitle }
                            speaker
                        }
                    }
                    Text("/\(step.word.phonetic)/").font(.system(size: 15)).foregroundColor(Palette.muted)
                    Text("\(step.word.pos) · \(step.word.unit) · 书内第\(step.word.printedPage)页").font(.system(size: 11)).foregroundColor(Palette.muted)
                    WordStudyHistory(wordID: step.word.id, roundID: session.id).id(step.id)
                    if let note = step.word.audioNote { Text(note).font(.system(size: 11)).foregroundColor(Palette.muted) }
                    if step.kind == "recognition" {
                        recognitionFeedback
                    } else if isMeaningVisible {
                        meaningSummary
                    } else if step.hinted {
                        VStack(alignment: .leading, spacing: 8) {
                            let level = max(1, step.associationHintLevel ?? step.hintLevel ?? 1)
                            Text(step.association?.source == "personal" ? (level > 1 ? "我的提示 2" : "我的提示 1") : "提示 \(level)")
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.blue)
                            Text(hintText(level: level)).font(.callout).lineSpacing(5)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.pale).cornerRadius(15)
                    }
                    else { VStack(spacing: 15) { Text("?").font(.system(size: 36, design: .serif)).foregroundColor(Palette.blue.opacity(0.5)); Text("它是什么意思？\n想一想，再揭晓。").font(.system(size: 14)).multilineTextAlignment(.center).foregroundColor(Palette.muted) }.frame(maxWidth: .infinity).padding(.vertical, 35) }
                }.padding(24)
            }.id(step.id).disabled(speech.recording || speech.processing)
            VStack(spacing: 12) {
                if step.revealed, let transcript = step.spokenTranscript {
                    Text("识别到：\(transcript) · \(step.spokenCorrect == true ? "已匹配，请核对词义" : "未匹配，请核对词义后自评")")
                        .font(.system(size: 11)).foregroundColor(step.spokenCorrect == true ? .green : Palette.muted).lineLimit(2)
                }
                Text(isLearningStep ? "单词自动朗读两遍 · 先慢后适中" : step.kind == "recognition" ? "按意思辨认，不需要背诵" : step.hinted ? "这次用过提示，按真实情况选择" : step.revealed ? "揭晓前，你想起来了吗？" : "想不起来，就看提示或直接揭晓").font(.system(size: 10)).foregroundColor(Palette.muted)
                actions
                if !speech.status.isEmpty {
                    Text(speech.status).font(.system(size: 10)).foregroundColor(Palette.muted).multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 12).background(Color.white)
                .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .top)
        }.onChange(of: step.id) { _ in speech.cancel() }
            .onChange(of: step.revealed) { revealed in if revealed { speech.cancel() } }
            .onDisappear { speech.cancel() }
            .sheet(isPresented: $editingAssociation) {
                AssociationEditorSheet(word: step.word, existing: model.association(for: step.word)).environmentObject(model)
            }
    }
    private var wordTitle: some View { Text(step.word.word).font(.system(size: 46, weight: .semibold, design: .serif)).lineLimit(1).minimumScaleFactor(0.45).foregroundColor(Palette.ink).accessibilityIdentifier("study-word") }
    private var canSpell: Bool { step.kind == "recall" && step.revealed }
    private var speaker: some View { Button { model.playWord(step.word, twice: false) } label: { Image(systemName: "speaker.wave.2").frame(width: 42, height: 42).background(Palette.pale).clipShape(Circle()) }.accessibilityLabel("朗读单词") }
    private var isLearningStep: Bool { step.kind == "learn" || step.relearning == true }
    private var isMeaningVisible: Bool { isLearningStep || step.revealed || (step.kind == "recognition" && recognitionFinished) }
    private var recognitionFinished: Bool { step.recognitionCorrect == true || (step.recognitionMistakes ?? 0) >= 2 }
    private var title: String { step.kind == "assessment" ? "先凭印象认一遍" : step.kind == "recognition" ? "按意思认一认" : isLearningStep ? (step.relearning == true ? "再看懂一次" : "认识这个词") : session.reviewKind == "distant" ? "遥远的记忆" : session.mode == "review" ? "巩固复习" : "试着自己想起来" }
    private var subtitle: String { step.kind == "assessment" ? "不必猜，按你原本的印象来选" : step.kind == "recognition" ? "选最贴近这个词的意思" : isLearningStep ? "先理解，再尝试独立想起" : session.mode == "review" ? "只练学过的词 · 不加新词" : "先想中文意思" }
    @ViewBuilder private var meaningSummary: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let association = displayedAssociation {
                AssociationCard(association: association)
                    .task(id: step.id) {
                        // A newly displayed step can arrive before its prior commit releases busy.
                        while model.busy {
                            try? await Task.sleep(nanoseconds: 40_000_000)
                            guard !Task.isCancelled else { return }
                        }
                        guard !Task.isCancelled else { return }
                        model.action("association-view", expectedStepID: step.id)
                    }
            }
            Button { editingAssociation = true } label: {
                Label("我的提示词", systemImage: "square.and.pencil").font(.system(size: 12))
            }
            WordFormationView(word: step.word)
            VStack(alignment: .leading, spacing: 8) {
                Text("核心词义").font(.system(size: 11)).foregroundColor(Palette.muted)
                let meaning = MeaningLearning.coreMeaning(step.word)
                Text(meaning.isEmpty ? step.word.meaning : meaning).font(.system(size: 23, weight: .medium)).lineSpacing(5)
            }
            if let example = MeaningLearning.context(step.word) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("放进原书语境").font(.system(size: 11)).foregroundColor(Palette.muted)
                        Spacer()
                        Button { model.audio.sentence(step.word, example: example) } label: { Image(systemName: "speaker.wave.2").frame(width: 36, height: 36) }.accessibilityLabel("朗读例句")
                    }
                    Text(example.text).font(.system(size: 18, design: .serif)).lineSpacing(5)
                    if let translation = example.translation, !translation.isEmpty { Text(translation).font(.system(size: 13)).foregroundColor(Palette.muted) }
                }.padding(15).background(Color.white).cornerRadius(15)
            }
            DisclosureGroup("展开完整词义") {
                MeaningContent(word: step.word, includeFormation: false).padding(.top, 8)
            }.font(.system(size: 13)).id(step.id)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var recognitionFeedback: some View {
        if step.selectedMeaningID != nil {
            if step.recognitionCorrect == true {
                Label("这个意思对上了", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium)).foregroundColor(.green)
                meaningSummary
            } else if recognitionFinished {
                Label("先看一下正确意思", systemImage: "lightbulb.fill").font(.system(size: 14, weight: .medium)).foregroundColor(.orange)
                meaningSummary
            } else {
                Label("这个意思不太像，再辨一次", systemImage: "exclamationmark.triangle.fill").font(.system(size: 14, weight: .medium)).foregroundColor(.orange)
            }
        } else {
            Text("选一个最贴近的中文意思").font(.system(size: 14)).foregroundColor(Palette.muted)
        }
        if !recognitionFinished, let choices = step.meaningChoices, !choices.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(choices.prefix(3))) { item in
                    Button { model.action("recognize", value: item.id, expectedStepID: step.id) } label: {
                        Text(item.meaning).font(.system(size: 13, weight: .medium)).lineLimit(2).minimumScaleFactor(0.75).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 42, alignment: .leading).padding(.horizontal, 14)
                    }.foregroundColor(Palette.ink).background(Palette.paper).cornerRadius(11).overlay(RoundedRectangle(cornerRadius: 11).stroke(step.selectedMeaningID == item.id && step.recognitionCorrect == false ? Color.orange : Palette.line)).accessibilityIdentifier("study-meaning-choice")
                }
            }.padding(12).background(Color.white).cornerRadius(15)
        }
    }
    @ViewBuilder private var actions: some View {
        if isLearningStep { PrimaryButton(title: learningActionTitle) { model.action("learn", expectedStepID: step.id) } }
        else if step.kind == "assessment" {
            if step.revealed { HStack(spacing: 7) { choice("认识", "assess", "known"); choice("眼熟", "assess", "familiar"); choice("陌生", "assess", "unknown", primary: true) } }
            else { PrimaryButton(title: "看看词义") { model.action("reveal", expectedStepID: step.id) } }
        } else if step.kind == "recognition" {
            if recognitionFinished { PrimaryButton(title: "继续下一个") { model.action("recognize-next", expectedStepID: step.id) } }
        } else if step.revealed {
            HStack(spacing: 7) { choice("没想起", "rate", "forgot"); choice("看提示", "rate", "hint"); choice("想得慢", "rate", "slow").disabled(step.hinted); choice("很快想起", "rate", "easy", primary: true).disabled(step.hinted) }
        } else {
            let hasAssociation = step.association?.source == "personal" && step.association?.isEmpty == false
            let level = step.associationHintLevel ?? step.hintLevel ?? 0
            HStack(spacing: 7) {
                SpokenMeaningInput(speech: speech, step: step).id(step.id)
                choice(hasAssociation ? (level > 0 ? "展开提示" : "我的提示") : "给点提示", "hint", "")
                choice("揭晓答案", "reveal", "", primary: true)
            }
        }
    }
    private var learningActionTitle: String {
        let nextKind = session.position + 1 < session.steps.count ? session.steps[session.position + 1].kind : nil
        let followsRecognition = nextKind == "recognition"
        if step.relearning == true { return followsRecognition ? "再看懂一次，认一认" : "再看懂一次，继续" }
        return followsRecognition ? "理解了，认一认" : "理解了，继续"
    }
    private var displayedAssociation: PersonalAssociation? {
        guard isLearningStep || step.revealed else { return nil }
        if let association = step.association, association.source == "personal", !association.isEmpty { return association }
        return nil
    }
    private func hintText(level: Int) -> String {
        if let association = step.association, association.source == "personal", !association.isEmpty {
            if level <= 1 {
                let cue = association.cue.trimmingCharacters(in: .whitespacesAndNewlines)
                return cue.isEmpty ? "想想你写下的联想画面" : cue
            }
            let story = association.story.trimmingCharacters(in: .whitespacesAndNewlines)
            if !story.isEmpty { return story }
            return association.cue
        }
        return MeaningLearning.cue(step.word, level: level)
    }
    private func choice(_ title: String, _ action: String, _ value: String, primary: Bool = false) -> some View {
        Button { model.action(action, value: value, expectedStepID: step.id) } label: { Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth: .infinity).frame(minHeight: 50) }.foregroundColor(primary ? .white : Palette.ink).background(primary ? Palette.blue : Palette.paper).cornerRadius(13).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line)).opacity(step.hinted && ["slow", "easy"].contains(value) ? 0.4 : 1).disabled(speech.recording || speech.processing)
    }
}
struct SpellingView: View {
    @EnvironmentObject var model: LearningModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var round: SpellingRound
    var mistakes: Int
    var word: MobileWord
    var stepID: String
    @State private var flash = false
    @State private var errorPosition = -1
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("选字母，拼出这个词").font(.system(size: 12)).foregroundColor(Palette.muted); Spacer(minLength: 4); Button { model.playWord(word, twice: false) } label: { Image(systemName: "speaker.wave.2").frame(width: 40, height: 40).background(Palette.pale).clipShape(Circle()) }.accessibilityLabel("朗读当前单词"); Button("返回单词") { model.action("spell-close", expectedStepID: stepID) }.font(.system(size: 12)).frame(minHeight: 40) }
            VStack(spacing: 7) {
                ForEach(0..<((round.letters.count + 9) / 10), id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach((row * 10)..<min(round.letters.count, (row + 1) * 10), id: \.self) { index in
                            let active = index == round.position
                            Text(index < round.position ? String(round.letters[index]) : " ").font(.system(size: 24, design: .serif)).frame(width: 24, height: 42)
                                .foregroundColor(Palette.blue).background(flash && errorPosition == index ? Color.red.opacity(0.17) : index < round.position ? Palette.pale : Color.white).cornerRadius(7)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? (errorPosition == index ? Color.red : Palette.blue) : Palette.line, lineWidth: active ? 2 : 1))
                                .accessibilityLabel("第\(index + 1)格，\(index < round.position ? String(round.letters[index]) : active ? "待填写" : "空白")")
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            if round.isComplete {
                HStack { Label("拼对了！", systemImage: "checkmark").foregroundColor(.green); Spacer(); Button("再拼一次") { errorPosition = -1; model.action("spell-start", expectedStepID: stepID) }.font(.system(size: 12)) }.frame(minHeight: 44)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(round.choices, id: \.self) { letter in
                        Button { model.action("spell-letter", value: letter, expectedStepID: stepID, expectedPosition: round.position) } label: { Text(letter).font(.system(size: 26, design: .serif)).frame(maxWidth: .infinity).frame(height: 44).background(Color.white).cornerRadius(9) }.accessibilityLabel("字母 \(letter)")
                    }
                }.padding(12).background(Palette.pale).cornerRadius(15)
            }
        }.onChange(of: round.position) { _ in errorPosition = -1; flash = false }
            .task(id: mistakes) {
                guard mistakes > 0 else { return }; errorPosition = round.position
                if reduceMotion { flash = true; return }
                for _ in 0..<3 { flash = true; try? await Task.sleep(nanoseconds: 120_000_000); guard !Task.isCancelled else { return }; flash = false; try? await Task.sleep(nanoseconds: 120_000_000); guard !Task.isCancelled else { return } }
            }
    }
}
struct MeaningContent: View {
    @EnvironmentObject var model: LearningModel
    var word: MobileWord
    var includeFormation = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) { Text("核心词义").font(.system(size: 11)).foregroundColor(Palette.muted); Text(word.meaning).font(.system(size: 23, weight: .medium)).lineSpacing(5) }
            if let example = word.example {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("放进短语和句子里").font(.system(size: 11)).foregroundColor(Palette.muted); Spacer(); Button { model.audio.sentence(word) } label: { Image(systemName: "speaker.wave.2").frame(width: 40, height: 40) }.accessibilityLabel("朗读例句") }
                    Text(example.text).font(.system(size: 19, design: .serif)).lineSpacing(5)
                    Text(example.translation.orEmpty).font(.system(size: 13)).foregroundColor(Palette.muted)
                }.padding(17).background(Color.white).cornerRadius(15)
            }
            if includeFormation { WordFormationView(word: word, showUnavailable: true) }
            DisclosureGroup("完整词义、派生与相关用法") {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(word.usages, id: \.key) { usage in
                        Text("\(usage.pos)  /\(usage.phonetic.orEmpty)/").font(.system(size: 13, weight: .medium))
                        ForEach(usage.senses, id: \.key) { sense in
                            Text(sense.meaning).font(.system(size: 14))
                            ForEach(Array((sense.examples ?? []).enumerated()), id: \.offset) { _, example in Text(example.text + "\n" + example.translation.orEmpty).font(.system(size: 13)).foregroundColor(Palette.muted) }
                        }
                    }
                    ForEach(Array(word.parts.filter { WordFormation.titles[$0.type] == nil }.enumerated()), id: \.offset) { _, part in Text("\(partTitle(part.type)) · \(part.text)\n\(part.translation.orEmpty)").font(.system(size: 13)).lineSpacing(4) }
                }.padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 13))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func partTitle(_ value: String) -> String { ["derived": "派生", "synonym": "同义", "antonym": "反义", "comparison": "辨析", "phrase": "词组", "note": "补充"] [value] ?? "相关用法" }
}
struct WordDetail: View {
    @EnvironmentObject var model: LearningModel
    var word: MobileWord
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(word.word).font(.system(size: 40, weight: .semibold, design: .serif))
                Spacer()
                Button { model.playWord(word, twice: false) } label: { Image(systemName: "speaker.wave.2").frame(width: 44, height: 44) }
            }
            Text("/\(word.phonetic)/ · \(word.pos)").foregroundColor(Palette.muted)
            WordAssociationSection(word: word)
            MeaningContent(word: word)
        }
        .onAppear { model.viewedWord(word) }
    }
}
struct FinishView: View {
    @EnvironmentObject var model: LearningModel
    var session: StudySession
    private var isAssessment: Bool { session.mode == "assessment" }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark").font(.system(size: 30)).foregroundColor(Palette.blue).frame(width: 84, height: 84).background(Palette.pale).clipShape(Circle()).padding(.top, 30)
                    Text(isAssessment ? "先认一遍，完成了。" : session.reviewKind == "distant" ? "遥远的记忆，又近了一点。" : session.mode == "review" ? "这轮复习，完成了。" : "这一组，完成了。").font(.system(size: 26, weight: .semibold))
                    Text(isAssessment ? "认识的词，就不重复学了。" : session.mode == "review" ? "只练学过的词，没有加入新词。" : "忘记的词，我们会再见一面。").font(.system(size: 13)).foregroundColor(Palette.muted)
                    HStack {
                        Stat(value: Set(session.steps.map { $0.word.id }).count, label: isAssessment ? "本组认过" : session.mode == "review" ? "本轮复习" : "本组词条")
                        Stat(value: model.events.filter { $0.kind == "RATE" && $0.fields["sessionID"] == session.id && ["slow", "easy"].contains($0.fields["rating"] ?? "") && $0.fields["hinted"] != "true" }.count, label: "独立想起")
                    }.padding(24).background(Color.white).cornerRadius(20)
                    Text(isAssessment ? "接下来，只学习陌生和眼熟的词。" : "先休息一会儿。\n真正记牢，要看之后还能否想起来。").font(.system(size: 15)).lineSpacing(8).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24).background(Palette.pale).cornerRadius(18)
                    if !isAssessment { Text("刚才这一组，学起来感觉怎么样？").font(.system(size: 12)).foregroundColor(Palette.muted) }
                }.padding(24)
            }
            if isAssessment { PrimaryButton(title: "开始学习") { model.completed = nil; model.start() }.padding(20) }
            else {
                HStack(spacing: 7) { feedback("轻松", "easy"); feedback("合适", "ok"); feedback("有点累", "tired"); feedback("结束", "skip") }.padding(20).background(Color.white)
            }
        }
    }
    private func feedback(_ title: String, _ value: String) -> some View { Button { model.feedback(value) } label: { Text(title).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth: .infinity).frame(height: 50).background(value == "skip" ? Palette.blue : Palette.pale).foregroundColor(value == "skip" ? .white : Palette.ink).cornerRadius(13) } }
}
struct WordsView: View {
    @EnvironmentObject var model: LearningModel
    var open: (MobileWord) -> Void
    @State private var search = ""
    @State private var filter = "all"
    @State private var selectedUnitID: String?
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var units: [VocabularyUnit] { VocabularyUnit.grouped(model.state.availableWords) }
    private func matchesFilter(_ word: MobileWord) -> Bool {
        let state = model.state.progress[word.id]
        return filter == "all" || (filter == "learned" ? state?.learned == true : filter == "known" ? state?.familiarity == "known" : state?.learned != true && state?.familiarity != "known")
    }
    private func matchingWords(in source: [MobileWord]) -> [MobileWord] {
        source.filter { matchesFilter($0) && (query.isEmpty || $0.word.localizedCaseInsensitiveContains(query) || $0.meaning.contains(query)) }
    }
    var body: some View {
        let groups = units
        let selectedUnit = groups.first { $0.id == selectedUnitID }
        let words = matchingWords(in: query.isEmpty ? selectedUnit?.words ?? [] : model.state.availableWords)
        return         VStack(alignment: .leading, spacing: 16) {
            HStack {
                if selectedUnit != nil {
                    Button { selectedUnitID = nil } label: { Image(systemName: "chevron.left").frame(width: 32, height: 40) }
                        .accessibilityLabel("返回单元").buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedUnit.map { VocabularyUnit.categoryTitle($0.category) } ?? "随时翻一翻").font(.system(size: 11)).foregroundColor(Palette.muted)
                    Text(selectedUnit?.title ?? "我的词库").font(.system(size: 28, weight: .semibold))
                }
                Spacer()
            }
            TextField("搜索整个词库的单词或释义", text: $search).padding(14).background(Color.white).cornerRadius(13)
                .disableAutocorrection(true).textInputAutocapitalization(.never).accessibilityIdentifier("vocabulary-search")
            Picker("熟悉程度", selection: $filter) { Text("全部").tag("all"); Text("待学习").tag("new"); Text("学过").tag("learned"); Text("认识").tag("known") }.pickerStyle(.segmented)
            if !query.isEmpty || selectedUnit != nil {
                Text("\(query.isEmpty ? "本单元" : "全词库搜索") · \(words.count) 词").font(.system(size: 11)).foregroundColor(Palette.muted)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(words) { word in
                            Button { open(word) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(word.word).font(.system(size: 24, weight: .semibold, design: .serif))
                                        Text("\(word.pos) \(word.meaning)").font(.system(size: 12)).foregroundColor(Palette.muted).lineLimit(2)
                                        if !query.isEmpty { Text("\(VocabularyUnit.categoryTitle(word.category)) · \(word.unit)").font(.system(size: 10)).foregroundColor(Palette.muted) }
                                    }
                                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 12))
                                }.padding(.vertical, 18).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("vocabulary-word-" + word.id)
                            Divider()
                        }
                        if words.isEmpty { Text("没有符合条件的词条").font(.callout).foregroundColor(Palette.muted).padding(.top, 24) }
                    }
                }.id(selectedUnitID.orEmpty + "-" + query + "-" + filter)
            } else {
                Text("\(groups.count) 个单元 · \(model.state.availableWords.count) 词").font(.system(size: 11)).foregroundColor(Palette.muted)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, unit in
                            if index == 0 || groups[index - 1].category != unit.category {
                                Text(VocabularyUnit.categoryTitle(unit.category)).font(.system(size: 14, weight: .semibold)).padding(.top, index == 0 ? 0 : 12)
                            }
                            Button { selectedUnitID = unit.id } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "book.closed").font(.system(size: 20)).foregroundColor(Palette.blue).frame(width: 42, height: 48).background(Palette.pale).cornerRadius(12)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(unit.title).font(.system(size: 21, weight: .semibold, design: .serif))
                                        Text("\(unit.words.count) 词 · 学过 \(unit.words.filter { model.state.progress[$0.id]?.learned == true }.count) 词").font(.system(size: 11)).foregroundColor(Palette.muted)
                                    }
                                    Spacer()
                                    if filter != "all" { Text("\(unit.words.filter(matchesFilter).count) 词").font(.system(size: 12)).foregroundColor(Palette.blue) }
                                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(Palette.muted)
                                }.padding(16).background(Color.white).cornerRadius(16).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("vocabulary-unit-" + unit.category + "-" + unit.title)
                        }
                        if groups.isEmpty { Text("可在设置中更新或导入词库。").font(.callout).foregroundColor(Palette.muted).padding(.top, 24) }
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.top, 24)
    }
}
struct RecordsView: View {
    @EnvironmentObject var model: LearningModel
    @State private var selectedRecall: RecallMeaningSelection?
    private var ratings: [JournalEvent] { model.events.filter { $0.kind == "RATE" } }
    private var delayed: [JournalEvent] { ratings.filter { $0.fields["source"] != "review" && $0.fields["clockAnomaly"] != "true" && (Double($0.fields["actualIntervalMs"] ?? "0") ?? 0) >= 43_200_000 } }
    private var standardCount: Int { ratings.filter { $0.fields["source"] != "review" }.count }
    private var reviewCount: Int { ratings.count - standardCount }
    private var delayedTitle: String {
        guard !delayed.isEmpty else { return "延迟回忆率 · 暂无样本" }
        let successful = delayed.filter { $0.fields["delayedSuccess"] == "true" }.count
        let percent = Int(Double(successful) / Double(delayed.count) * 100)
        return "延迟回忆率 · \(percent)%"
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("每一步都留着").font(.system(size: 11)).foregroundColor(Palette.muted)
            Text("看见自己的进步").font(.system(size: 27, weight: .semibold))
            Text("先看过程，再看记住了多少。").font(.system(size: 12)).foregroundColor(Palette.muted)
            HStack(spacing: 0) { Stat(value: model.state.progress.values.filter(\.learned).count, label: "累计学过"); Stat(value: standardCount, label: "常规回忆"); Stat(value: reviewCount, label: "巩固复习") }
            VStack(alignment: .leading, spacing: 8) {
                Text(delayedTitle)
                Text("间隔至少12小时的常规回忆，共 \(delayed.count) 次；巩固练习单独记录。").font(.system(size: 11)).foregroundColor(Palette.muted)
            }.font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Color.white).cornerRadius(15)
            HStack { Text("最近的回忆"); Spacer(); Text("\(ratings.count) 次").foregroundColor(Palette.muted) }.font(.system(size: 13))
            ForEach(Array(ratings.suffix(50).reversed())) { event in
                RecallRecordRow(event: event, word: wordName(event), showMeaning: {
                    guard let word = recalledWord(event) else { return }
                    selectedRecall = RecallMeaningSelection(id: event.id, word: word)
                    model.viewedWord(word, source: "records", twice: false)
                }, hasMeaning: recalledWord(event) != nil)
                    .anchorPreference(key: RecallAnchorKey.self, value: .bounds) { [event.id: $0] }
            }
            if ratings.isEmpty { Text("完成学习后，这里会留下你的真实选择。").font(.callout).foregroundColor(Palette.muted) }
            PrimaryButton(title: "导出学习日志") { model.exportLogs() }
            Text("导出包含七天报告、CSV和原始JSONL事件；完整备份请到设置中创建。").font(.system(size: 11)).foregroundColor(Palette.muted)
        }.padding(24) }
            .overlayPreferenceValue(RecallAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    if let selected = selectedRecall, let anchor = anchors[selected.id] {
                        RecallMeaningOverlay(word: selected.word, row: geometry[anchor], size: geometry.size, dismiss: closeMeaning).id(selected.id)
                    }
                }
            }
            .onDisappear { closeMeaning() }
    }
    private func closeMeaning() { selectedRecall = nil; model.stopViewedWord() }
    private func recalledWord(_ event: JournalEvent) -> MobileWord? {
        guard let id = event.fields["wordID"] else { return nil }
        // A frozen task snapshot retains the meaning seen during that recall, even after content updates.
        if let sessionID = event.fields["sessionID"], let session = model.state.sessions[sessionID] {
            if let stepID = event.fields["stepID"], let step = session.steps.first(where: { $0.id == stepID }) { return step.word }
            if let step = session.steps.first(where: { $0.word.id == id }) { return step.word }
        }
        return model.state.words.first { $0.id == id }
    }
    private func wordName(_ event: JournalEvent) -> String { recalledWord(event)?.word ?? "词条" }
}
struct RecallRecordRow: View {
    var event: JournalEvent
    var word: String
    var showMeaning: () -> Void
    var hasMeaning: Bool
    private var caption: String {
        let source = event.fields["reviewKind"] == "distant" ? "遥远的记忆 · " : event.fields["source"] == "review" ? "巩固复习 · " : "常规回忆 · "
        return source + event.occurredAt.formatted(date: .abbreviated, time: .shortened)
    }
    private var rating: String {
        let labels = ["forgot": "没想起来", "hint": "看了提示", "slow": "想了一会儿", "easy": "很快想起"]
        return labels[event.fields["rating"] ?? ""] ?? "已记录"
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Button(action: showMeaning) {
                    Text(word).font(.system(size: 21, weight: .semibold, design: .serif))
                        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!hasMeaning)
                    .accessibilityLabel("查看 " + word + " 的释义").accessibilityIdentifier("recall-word-" + event.id)
                Text(caption).font(.system(size: 10)).foregroundColor(Palette.muted)
            }
            Spacer()
            Text(rating).font(.system(size: 12)).foregroundColor(Palette.muted)
        }
    }
}

private struct RecallMeaningSelection: Identifiable {
    var id: String
    var word: MobileWord
}
private struct RecallAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
private struct RecallBubbleTip: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
private struct RecallContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
/// An anchored overlay stays a bubble on iPhone/iOS15 instead of adapting a popover to a sheet.
private struct RecallMeaningOverlay: View {
    @EnvironmentObject var model: LearningModel
    var word: MobileWord
    var row: CGRect
    var size: CGSize
    var dismiss: () -> Void
    private var width: CGFloat { max(1, min(360, size.width - 32)) }
    @State private var contentHeight: CGFloat = 0
    // Header44 + spacing12 + padding36. Short definitions keep their natural height;
    // only definitions taller than the available cap need an inner scroll view.
    private var height: CGFloat { min(max(1, size.height - 40), min(340, max(132, contentHeight + 92))) }
    private var above: Bool { size.height - row.maxY < height + 20 && row.minY > height + 20 }
    private var top: CGFloat { max(20, min(above ? row.minY - height - 12 : row.maxY + 12, size.height - height - 20)) }
    private var left: CGFloat { max(16, min(row.minX, size.width - width - 16)) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.08).contentShape(Rectangle()).onTapGesture(perform: dismiss)
                .accessibilityLabel("关闭释义气泡").accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(word.word).font(.system(size: 25, weight: .semibold, design: .serif)).lineLimit(1).minimumScaleFactor(0.65)
                    Spacer(minLength: 0)
                    Button { model.viewedWord(word, source: "records", twice: false) } label: {
                        Image(systemName: "speaker.wave.2").frame(width: 44, height: 44)
                    }.accessibilityLabel("朗读记录中的单词")
                    Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("关闭释义").accessibilityIdentifier("recall-meaning-close")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(word.meaning).font(.system(size: 18, weight: .medium)).lineSpacing(5)
                        ForEach(word.usages, id: \.key) { usage in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(usage.pos + (usage.phonetic.map { "  /" + $0 + "/" } ?? ""))
                                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.blue)
                                ForEach(usage.senses, id: \.key) { sense in
                                    Text(sense.meaning).font(.system(size: 15)).lineSpacing(4)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: RecallContentHeightKey.self, value: geometry.size.height)
                        })
                }
                .onPreferenceChange(RecallContentHeightKey.self) { value in
                    if value.isFinite && abs(contentHeight - value) > 0.5 { contentHeight = value }
                }
            }.padding(18).frame(width: width, height: height, alignment: .topLeading)
                .background(Color.white).cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line))
                .shadow(color: Palette.ink.opacity(0.13), radius: 16, x: 0, y: 5)
                .offset(x: left, y: top)
            RecallBubbleTip().fill(Color.white).frame(width: 20, height: 10)
                .rotationEffect(.degrees(above ? 180 : 0))
                .offset(x: max(left + 22, min(row.minX + 30, left + width - 42)), y: above ? top + height - 1 : top - 9)
                .allowsHitTesting(false).accessibilityHidden(true)
        }.foregroundColor(Palette.ink)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: LearningModel
    var show: (AppSheet) -> Void
    var importAction: () -> Void
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 0) {
            Text("按你的节奏来").font(.system(size: 11)).foregroundColor(Palette.muted).padding(.bottom, 14)
            Text("设置").font(.system(size: 28, weight: .semibold)).padding(.bottom, 24)
            row("book", "词库更新", "手动更新词条与原书录音") { show(.updates) }
            row("slider.horizontal.3", "词库服务器地址", model.state.profile.serverBaseURL.isEmpty ? "尚未设置" : model.state.profile.serverBaseURL) { show(.server) }
            row("square.and.arrow.down", "从文件导入词库", "支持手机版词条包 ZIP") { importAction() }
            row("slider.horizontal.3", "学习偏好", "学习顺序、新词数量与晚间提醒") { show(.preferences) }
            row("sparkles", "AI学习教练", "近3天分析、重点词与针对性练习") { show(.coach) }
            row("slider.horizontal.3", "AI调用配置", "从电脑端更新，手机直接调用AI") { show(.coachConfig) }
            row("clock", "每日学习安排", "早、下午、晚上，各40分钟") { show(.schedule) }
            row("speaker.wave.2", "单词朗读", "原书录音 · 先慢后适中") { show(.audio) }
            row("chart.bar.doc.horizontal", "七天报告", "延迟回忆、容易忘的词与每日记录") { show(.report) }
            row("externaldrive", "备份与恢复", "完整保存进度、任务、词库和录音") { show(.backups) }
            row("arrow.up.doc", "同步到服务器", "手动上传备份，复用词库服务器地址") { show(.sync) }
            Text("离线学习 · iOS15+\n词库更新和服务器备份都由你手动操作。手机与Web学习记录分别保留，备份恢复真机验收后开始正式试用。").font(.system(size: 11)).foregroundColor(Palette.muted).lineSpacing(5).padding(.top, 24)
        }.padding(24) }
    }
    private func row(_ icon: String, _ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 13) { Image(systemName: icon).frame(width: 38, height: 38).background(Palette.pale).cornerRadius(12); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 14)); Text(subtitle).font(.system(size: 11)).foregroundColor(Palette.muted).lineLimit(2) }; Spacer(minLength: 4); Image(systemName: "chevron.right").font(.system(size: 11)) }.padding(.vertical, 18).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("settings-" + title).overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
    }
}
struct ServerAddressView: View {
    @EnvironmentObject var model: LearningModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Base URL").font(.system(size: 13))
            TextField("https://example.com/iword/", text: $value).accessibilityIdentifier("server-base-url").font(.system(size: 16)).keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true).padding(14).background(Color.white).cornerRadius(12)
            Text("只填写系统访问地址，如有 /iword/ 路径也要保留。").font(.system(size: 12)).foregroundColor(Palette.muted)
            PrimaryButton(title: "保存地址") { if model.saveBaseURL(value) { dismiss() } }
        }.onAppear { value = model.state.profile.serverBaseURL }
    }
}
struct UpdatesView: View {
    @EnvironmentObject var model: LearningModel
    var importAction: () -> Void
    var sampleAction: () -> Void
    @State private var phone = ""
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("下载后，词条和原书录音都留在手机里。").font(.system(size: 14))
            Text(model.state.profile.serverBaseURL.isEmpty ? "请先在设置中填写词库服务器地址。" : model.state.profile.serverBaseURL).font(.system(size: 11)).foregroundColor(Palette.muted)
            VStack(spacing: 10) {
                TextField("电脑端使用的手机号", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber).accessibilityIdentifier("update-phone")
                Divider()
                TextField("名称（首次连接时填写）", text: $name).textInputAutocapitalization(.never).accessibilityIdentifier("update-name")
            }.font(.system(size: 15)).padding(15).background(Color.white).cornerRadius(14).disabled(model.updateBusy)
            Text("只在你点击时连接，不上传手机的学习记录。").font(.system(size: 11)).foregroundColor(Palette.muted)
            if model.updateBusy {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.updateStatus).font(.system(size: 13))
                    ProgressView(value: model.updateProgress)
                    Button("取消") { model.cancelUpdate() }.frame(minHeight: 44)
                }.accessibilityIdentifier("update-progress")
            } else {
                PrimaryButton(title: "检查更新") { model.checkUpdates(phone: phone, name: name) }.disabled(model.state.profile.serverBaseURL.isEmpty)
                if !model.updateStatus.isEmpty { Text(model.updateStatus).font(.system(size: 12)).foregroundColor(Palette.muted) }
            }
            if let error = model.updateError { Text(error).font(.system(size: 12)).foregroundColor(.red).accessibilityIdentifier("update-error") }
            if let index = model.updateIndex {
                ForEach(index.packages) { item in
                    UpdatePackageRow(item: item).environmentObject(model)
                }
                if !model.withdrawnPackageIDs.isEmpty {
                    Button("同步已下架单元（保留学习记录）") { model.applyWithdrawals() }.font(.system(size: 13)).frame(minHeight: 44).disabled(model.updateBusy)
                }
                Text("未变化的单元不用重新下载。更新失败仍可使用原有词库。").font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            Divider()
            Button("从文件导入词库", action: importAction).frame(minHeight: 44).disabled(model.updateBusy)
            if model.state.words.isEmpty {
                Button("先体验内置5词样本", action: sampleAction).font(.system(size: 13)).frame(minHeight: 44).disabled(model.updateBusy)
            }
        }.onDisappear { model.cancelUpdate() }
    }
}
struct UpdatePackageRow: View {
    @EnvironmentObject var model: LearningModel
    let item: RemotePackage
    private var installed: Bool { model.state.profile.installedPackages?[item.packageId] == item.revision }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 15, weight: .semibold))
                Text("\(item.wordCount) 词 · \(item.audioCount) 段录音 · " + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.system(size: 11)).foregroundColor(Palette.muted)
                Text("版本 " + String(item.revision.prefix(8))).font(.system(size: 10)).foregroundColor(Palette.muted)
            }
            Spacer(minLength: 4)
            Button(installed ? "已更新" : "下载") { model.downloadPackage(item) }
                .font(.system(size: 13, weight: .medium)).frame(minWidth: 52, minHeight: 44)
                .disabled(installed || model.updateBusy).accessibilityIdentifier("download-" + item.packageId)
        }.padding(15).background(Color.white).cornerRadius(14)
    }
}
struct ShareView: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
