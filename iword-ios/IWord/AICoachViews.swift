import SwiftUI

struct AICoachView: View {
    @EnvironmentObject var model: LearningModel
    @ObservedObject var coach: AICoachController
    @State private var configurationSheet = false
    @State private var selectedReportID: String?
    @State private var practiceSheet = false
    private var archive: AICoachArchive { model.state.profile.aiCoach ?? AICoachArchive() }
    private var selected: SavedCoachReport? { archive.reports.first(where: { $0.id == selectedReportID }) ?? archive.latest }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("把记录变成下一步。").font(.system(size: 23, weight: .semibold))
                Text("分析近3天的回忆表现，找到值得再练的词。报告与练习保存后可离线使用。")
                    .font(.system(size: 13)).foregroundColor(Palette.muted).lineSpacing(4)
            }
            HStack {
                Label(coach.configuration == nil ? "尚未配置AI" : "AI配置已就绪", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
                Spacer()
                Button("更新配置") { configurationSheet = true }.font(.system(size: 12, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("23:30后尝试自动分析", isOn: Binding(get: { archive.automaticEnabled }, set: { coach.setAutomatic($0) }))
                    .font(.system(size: 14)).disabled(coach.configuration == nil || coach.running || coach.saving)
                    .accessibilityIdentifier("ai-coach-automatic")
                Text("iOS决定后台执行时间。若未自动执行，打开这里点击分析即可。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted).lineSpacing(3)
                PrimaryButton(title: coach.running ? "正在分析…" : "分析我的学习") { coach.manualAnalysis() }
                    .disabled(coach.running || coach.syncing || coach.configuration == nil || !model.ready)
                    .accessibilityIdentifier("ai-coach-analyze")
                AICoachStatus(coach: coach)
                if coach.running { Button("取消分析") { coach.cancel() }.frame(minHeight: 40) }
                Text("将必要的词条、学习日志和个人联想提交给配置的AI服务；不提交手机号、姓名或录音。请求最长等待10分钟。")
                    .font(.system(size: 10)).foregroundColor(Palette.muted).lineSpacing(3)
            }.padding(16).background(Color.white).cornerRadius(16)
            if archive.reports.count > 1 {
                Picker("查看报告", selection: Binding(get: { selected?.id ?? "" }, set: { selectedReportID = $0 })) {
                    ForEach(archive.reports) { saved in Text(saved.createdAt.formatted(date: .abbreviated, time: .shortened)).tag(saved.id) }
                }.pickerStyle(.menu)
            }
            if let saved = selected {
                AICoachReportView(saved: saved, coach: coach, practiceAction: { selectedReportID = saved.id; practiceSheet = true })
            } else {
                Text("完成一组学习并更新AI配置后，就可以生成第一份报告。已有几天记录时，分析会更有依据。")
                    .font(.system(size: 13)).foregroundColor(Palette.muted).padding(.vertical, 20)
            }
        }
        .sheet(isPresented: $configurationSheet) {
            SheetContainer(title: "AI调用配置") { AICoachConfigurationView(coach: coach) }.environmentObject(model)
        }
        .sheet(isPresented: $practiceSheet) {
            if let saved = selected {
                SheetContainer(title: "针对性练习") { AICoachPracticeView(reportID: saved.id, coach: coach) }.environmentObject(model)
            }
        }
    }
}

struct AICoachStatus: View {
    @ObservedObject var coach: AICoachController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coach.running || coach.syncing { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            if !coach.status.isEmpty { Text(coach.status).font(.system(size: 12)).foregroundColor(Palette.muted).accessibilityIdentifier("ai-coach-status") }
            if let error = coach.error { Text(error).font(.system(size: 12)).foregroundColor(.red).accessibilityIdentifier("ai-coach-error") }
        }
    }
}

struct AICoachConfigurationView: View {
    @EnvironmentObject var model: LearningModel
    @ObservedObject var coach: AICoachController
    @State private var phone = ""
    @State private var name = ""
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("启动电脑端，保存配置中心的AI设置，再同步到这部手机。同步后可以关闭电脑端。")
                .font(.system(size: 14)).lineSpacing(5)
            Text(model.state.profile.serverBaseURL.isEmpty ? "请先设置词库服务器地址。" : model.state.profile.serverBaseURL)
                .font(.system(size: 11)).foregroundColor(Palette.muted)
            VStack(spacing: 12) {
                TextField("电脑端使用的手机号", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    .accessibilityIdentifier("ai-config-phone")
                Divider()
                TextField("名称（首次连接时填写）", text: $name).textInputAutocapitalization(.never)
            }.padding(16).background(Color.white).cornerRadius(14)
            PrimaryButton(title: "更新AI配置") { coach.updateConfiguration(baseURL: model.state.profile.serverBaseURL, phone: phone, name: name) }
                .disabled(coach.syncing || coach.running || model.state.profile.serverBaseURL.isEmpty)
                .accessibilityIdentifier("ai-config-update")
            AICoachStatus(coach: coach)
            if let config = coach.configuration {
                VStack(alignment: .leading, spacing: 12) {
                    detail("模型", config.model)
                    detail("推理强度", config.reasoningEffort)
                    detail("超时", "\(config.timeoutSeconds) 秒")
                    detail("接口", config.endpoint)
                    detail("配置版本", config.version)
                    detail("服务器更新时间", config.updatedAt)
                    detail("接口密钥", "已保存到本机钥匙串")
                }.padding(16).background(Color.white).cornerRadius(16)
                Button("删除本机AI配置") { confirmDelete = true }.font(.system(size: 13)).foregroundColor(.red)
                    .disabled(coach.running || coach.syncing)
            }
            Text("配置不随学习备份导出。换设备或删除后，需要重新同步；已有学习记录和报告保留。")
                .font(.system(size: 11)).foregroundColor(Palette.muted).lineSpacing(4)
        }.alert("删除本机AI配置？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { coach.removeConfiguration() }
        } message: { Text("之后需要启动电脑端并重新更新AI配置。") }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(Palette.muted)
            Text(value).font(.system(size: 13)).textSelection(.enabled)
        }
    }
}

private struct AICoachReportView: View {
    @EnvironmentObject var model: LearningModel
    let saved: SavedCoachReport
    @ObservedObject var coach: AICoachController
    var practiceAction: () -> Void
    private var adopted: AdoptedCoachPlan? { model.state.profile.aiCoach?.adoptedPlan }
    private func word(_ id: String) -> MobileWord? { saved.words.first { $0.id == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("学习分析").font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(saved.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            Text("数据截至 " + saved.dataThrough.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10)).foregroundColor(Palette.muted)
            Text(saved.report.analysisSummary).font(.system(size: 14)).lineSpacing(6)
            findingsSection
            if !saved.report.priorityWords.isEmpty {
                Text("值得再遇见的词").font(.headline)
                ForEach(Array(saved.report.priorityWords.prefix(5).enumerated()), id: \.offset) { _, focus in
                    focusCard(focus)
                }
                if saved.report.priorityWords.count > 5 {
                    DisclosureGroup("其余\(saved.report.priorityWords.count - 5)个重点词") {
                        ForEach(Array(saved.report.priorityWords.dropFirst(5).enumerated()), id: \.offset) { _, focus in focusCard(focus) }
                    }.font(.system(size: 13))
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("下一天，按这个节奏").font(.headline)
                timePlan("早上", saved.report.tomorrowPlan.morning)
                timePlan("下午", saved.report.tomorrowPlan.afternoon)
                timePlan("晚上", saved.report.tomorrowPlan.evening)
                if adopted?.reportID == saved.id {
                    Text("已采用 · " + (adopted?.day ?? "")).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.blue)
                    Button("取消采用，恢复常规安排") { coach.clearPlan() }.font(.system(size: 12)).disabled(coach.saving || coach.running)
                } else {
                    Button("采用这份计划") { coach.adopt(saved) }.font(.system(size: 14, weight: .semibold)).frame(minHeight: 44)
                        .disabled(coach.saving || coach.running).accessibilityIdentifier("ai-coach-adopt")
                }
                Text("按数据截止日期的下一天生效；新词不超过你的设置，现有学习组保持。")
                    .font(.system(size: 10)).foregroundColor(Palette.muted)
            }.padding(16).background(Palette.pale).cornerRadius(16)
            if !saved.report.exercises.isEmpty {
                PrimaryButton(title: "开始针对性练习 · \(saved.report.exercises.count)题", action: practiceAction)
                    .disabled(coach.running).accessibilityIdentifier("ai-coach-practice")
            }
            if !saved.validationNotes.isEmpty {
                DisclosureGroup("内容校验说明") {
                    ForEach(Array(saved.validationNotes.enumerated()), id: \.offset) { _, note in Text(note).font(.system(size: 11)).foregroundColor(Palette.muted) }
                }.font(.system(size: 12))
            }
        }.onDisappear { model.stopPracticeAudio() }
    }
    @ViewBuilder private var findingsSection: some View {
        if !saved.report.findings.isEmpty {
            DisclosureGroup("分析依据") {
                ForEach(Array(saved.report.findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(finding.text).font(.system(size: 13)).lineSpacing(4)
                        ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, evidence in
                            Text(evidenceText(evidence)).font(.system(size: 11)).foregroundColor(Palette.muted)
                        }
                    }.padding(.vertical, 8)
                }
            }.font(.system(size: 13))
        }
    }
    private func evidenceText(_ evidence: AICoachEvidence) -> String {
        let name = evidence.wordID.flatMap { word($0)?.word } ?? ""
        let prefix = name.isEmpty ? "" : name + " · "
        let note = evidence.note.map { " · " + $0 } ?? ""
        return prefix + metricTitle(evidence.metric) + "：\(evidence.value)" + note
    }
    @ViewBuilder private func focusCard(_ focus: AICoachPriorityWord) -> some View {
        if let word = word(focus.wordID) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(word.word).font(.system(size: 21, weight: .semibold, design: .serif))
                    Button { model.playPracticeWord(word, automatic: false) } label: { Image(systemName: "speaker.wave.2").frame(width: 36, height: 36) }.accessibilityLabel("朗读" + word.word)
                    Spacer()
                }
                Text(MeaningLearning.coreMeaning(word)).font(.system(size: 13))
                Text(focus.reason).font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(4)
                Text(focus.method).font(.system(size: 13)).lineSpacing(5)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(16)
        }
    }
    private func metricTitle(_ metric: String) -> String {
        ["recentMeaningRecallAttempts": "词义回忆次数", "recentIndependentMeaningRecalls": "独立想起次数",
         "recentRecognitionAttempts": "辨认次数", "recentRecognitionCorrect": "辨认正确次数",
         "recentSpellingAttempts": "字母选择次数", "recentSpellingErrors": "字母选择错误次数",
         "recentReviewAttempts": "巩固回忆次数", "meaningRecallAttempts": "词义回忆次数",
         "independentMeaningRecalls": "独立想起次数", "recognitionAttempts": "辨认次数",
         "recognitionCorrect": "辨认正确次数", "spellingAttempts": "字母选择次数", "spellingErrors": "字母选择错误次数",
         "firstCrossDayRecallSamples": "隔天首次回忆样本", "firstCrossDayIndependentSuccesses": "隔天首次独立想起",
         "learnedWords": "累计学过", "observedDays": "有记录的天数"][metric] ?? metric
    }
    private func timePlan(_ title: String, _ plan: AICoachTimePlan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title + " · 新词\(plan.newWordCount)个").font(.system(size: 13, weight: .semibold))
            Text(plan.message).font(.system(size: 12)).lineSpacing(4)
            let names = plan.reviewWordIDs.compactMap { word($0)?.word }
            if !names.isEmpty { Text(names.joined(separator: " · ")).font(.system(size: 11)).foregroundColor(Palette.muted) }
        }
    }
}

struct AICoachPracticeView: View {
    @EnvironmentObject var model: LearningModel
    let reportID: String
    @ObservedObject var coach: AICoachController
    @State private var entry = ""
    @State private var index = 0
    @State private var flash = false
    private var saved: SavedCoachReport? { model.state.profile.aiCoach?.reports.first { $0.id == reportID } }
    var body: some View {
        Group {
            if let saved, saved.report.exercises.indices.contains(index) {
                exercise(saved.report.exercises[index], saved: saved)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("这一轮完成了。").font(.title2.weight(.semibold))
                    Text("答题记录已保存，下次分析会参考这些表现。练习不会直接增加熟练度。")
                        .font(.system(size: 13)).foregroundColor(Palette.muted)
                }
            }
        }.onAppear {
            if let saved { index = saved.report.exercises.firstIndex { saved.attempts[$0.id]?.complete != true } ?? saved.report.exercises.count }
        }.onDisappear { model.stopPracticeAudio() }
    }
    private func exercise(_ question: AICoachExercise, saved: SavedCoachReport) -> some View {
        let progress = saved.attempts[question.id] ?? CoachExerciseProgress()
        let word = saved.words.first { $0.id == question.wordID }
        return VStack(alignment: .leading, spacing: 16) {
            HStack { Text("针对性练习").font(.headline); Spacer(); Text("\(index + 1) / \(saved.report.exercises.count)").font(.system(size: 12)).foregroundColor(Palette.muted) }
            if let word {
                HStack {
                    Text(question.kind == .spelling && !progress.revealed ? MeaningLearning.coreMeaning(word) : word.word)
                        .font(.system(size: 24, weight: .semibold, design: .serif)).minimumScaleFactor(0.6)
                    Button { model.playPracticeWord(word, automatic: false) } label: { Image(systemName: "speaker.wave.2.fill").frame(width: 40, height: 40) }.accessibilityLabel("朗读单词")
                }.frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
                if let prompt = question.prompt, !prompt.isEmpty { Text(prompt).font(.system(size: 13)).lineSpacing(4) }
                if question.kind == .meaningChoice {
                    choiceOptions(question, saved: saved, progress: progress)
                } else if question.kind == .spelling && !progress.complete {
                    Text(entry.isEmpty ? "填写英文单词" : entry).font(.system(size: 24, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 48).background(Color.white).cornerRadius(12)
                    PracticeKeyboard(entry: $entry)
                    PrimaryButton(title: "确认") { coach.answer(reportID: reportID, exerciseID: question.id, spelling: entry) }
                        .disabled(entry.isEmpty || coach.saving || coach.running)
                } else if question.kind == .meaningRecall && !progress.revealed {
                    PrimaryButton(title: "揭晓中文释义") { coach.reveal(reportID: reportID, exerciseID: question.id) }.disabled(coach.saving || coach.running)
                }
                if !progress.revealed, let hint = question.hint, !hint.isEmpty {
                    if progress.hintUsed == true {
                        Text(hint).font(.system(size: 13)).foregroundColor(Palette.blue).padding(12).background(Palette.pale).cornerRadius(12)
                    } else {
                        Button("给点提示") { coach.hint(reportID: reportID, exerciseID: question.id) }
                            .font(.system(size: 13)).frame(minHeight: 40).disabled(coach.saving || coach.running)
                    }
                }
                if progress.revealed {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(word.word).font(.system(size: 19, weight: .semibold))
                        Text(word.meaning).font(.system(size: 15)).lineSpacing(5)
                        if let hint = question.hint, !hint.isEmpty { Text(hint).font(.system(size: 12)).foregroundColor(Palette.muted) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.pale).cornerRadius(14)
                    if question.kind == .meaningRecall && !progress.complete {
                        HStack {
                            Button("没想起") { coach.answer(reportID: reportID, exerciseID: question.id, recalled: false) }.frame(maxWidth: .infinity, minHeight: 44)
                            Button("独立想起") { coach.answer(reportID: reportID, exerciseID: question.id, recalled: true) }.frame(maxWidth: .infinity, minHeight: 44)
                        }.disabled(coach.saving || coach.running)
                    }
                }
                if !progress.complete, progress.attempts > 0 {
                    Text("再试一次 · \(progress.attempts)/3").font(.system(size: 12)).foregroundColor(.red)
                }
                if progress.complete {
                    PrimaryButton(title: index + 1 == saved.report.exercises.count ? "完成" : "下一题") {
                        model.stopPracticeAudio(); entry = ""; index += 1
                    }.accessibilityIdentifier("ai-practice-next")
                }
            } else { Text("此题的词条资料不可用，请重新生成练习。").font(.callout) }
            if let error = coach.error { Text(error).font(.system(size: 12)).foregroundColor(.red) }
        }
        .padding(flash ? 2 : 0)
        .background(flash ? Color.red.opacity(0.1) : Color.clear).cornerRadius(14)
        .onChange(of: progress.attempts) { _ in
            if !progress.complete { flash = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { flash = false } }
        }
        .task(id: question.id) { if let word { model.playPracticeWord(word, automatic: true) } }
    }
    private func choiceOptions(_ question: AICoachExercise, saved: SavedCoachReport, progress: CoachExerciseProgress) -> some View {
        VStack(spacing: 8) {
            ForEach(Array((question.choiceWordIDs ?? []).enumerated()), id: \.offset) { choiceIndex, id in
                if let option = saved.words.first(where: { $0.id == id }) {
                    Button { coach.answer(reportID: reportID, exerciseID: question.id, choiceIndex: choiceIndex) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MeaningLearning.coreMeaning(option)).font(.system(size: 14))
                            if progress.complete { Text(option.word).font(.system(size: 12)).foregroundColor(Palette.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.foregroundColor(Palette.ink).background(progress.complete && id == question.wordID ? Palette.pale : Color.white)
                        .cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(progress.selectedIndex == choiceIndex && id != question.wordID ? Color.red : Palette.line))
                        .disabled(progress.complete || coach.saving || coach.running)
                }
            }
        }
    }
}
