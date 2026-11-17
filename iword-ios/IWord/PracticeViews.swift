import SwiftUI

struct PracticeHomeView: View {
    @EnvironmentObject var model: LearningModel
    @State private var coachPresented = false
    @State private var kind: PracticeKind = .mixed
    @State private var unitID = "all"
    @AppStorage(PracticeEngine.mixedKindsDefaultsKey) private var mixedKindsStorage = PracticeEngine.defaultMixedKindsValue
    @State private var selectedMixedKinds = PracticeEngine.defaultMixedKinds
    private var learned: [MobileWord] { model.state.availableWords.filter { model.state.progress[$0.id]?.learned == true } }
    var body: some View {
        Group {
            if let round = model.state.profile.practiceRound, !round.paused {
                PracticeFlowView(round: round)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("换一种方式，再记一遍。").font(.system(size: 24, weight: .semibold))
                        Text("只练已学词，题目和录音均在本机。练习与正式回忆分别记录。").font(.system(size: 13)).foregroundColor(Palette.muted).lineSpacing(5)
                        Button { coachPresented = true } label: {
                            HStack { Label("AI针对性练习", systemImage: "sparkles"); Spacer(); Image(systemName: "arrow.right") }
                                .font(.system(size: 14)).frame(minHeight: 44)
                        }.accessibilityIdentifier("practice-ai-coach")
                        if let round = model.state.profile.practiceRound {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("接着上次的练习").font(.headline)
                                Text("\(round.kind.title) · 第 \(min(round.position + 1, round.questions.count)) / \(round.questions.count) 题").font(.callout)
                                PrimaryButton(title: "继续练习") { model.resumePractice() }.accessibilityIdentifier("practice-resume")
                                Button("结束这轮练习") { model.endPractice() }.font(.callout)
                            }.padding(18).background(Color.white).cornerRadius(18)
                        } else {
                            VStack(spacing: 18) {
                                Picker("题型", selection: $kind) { ForEach(PracticeKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("practice-kind")
                                Picker("练习范围", selection: $unitID) {
                                    Text("全部已学词").tag("all")
                                    ForEach(VocabularyUnit.grouped(learned)) { unit in Text(unit.title).tag(unit.id) }
                                }.pickerStyle(.menu)
                            }.frame(maxWidth: .infinity).padding(18).background(Color.white).cornerRadius(18)
                            if kind == .mixed {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("混合题型").font(.headline)
                                    Text("至少选择一种；没有足够材料的已选题型会自动跳过。").font(.system(size: 12)).foregroundColor(Palette.muted)
                                    ForEach(PracticeKind.mixedCases) { candidate in
                                        Toggle(candidate.title, isOn: Binding(
                                            get: { selectedMixedKinds.contains(candidate) },
                                            set: { enabled in setMixedKind(candidate, enabled: enabled) }
                                        ))
                                        .toggleStyle(.switch)
                                        .accessibilityIdentifier("practice-mixed-kind-" + candidate.id)
                                        .disabled(selectedMixedKinds.count == 1 && selectedMixedKinds.contains(candidate))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .background(Color.white)
                                .cornerRadius(18)
                            }
                            Text(learned.isEmpty ? "先学完一组词，再来这里练习。" : "每轮最多10题；配对题一次最多6组。材料不足时会减少题数。").font(.system(size: 12)).foregroundColor(Palette.muted)
                            PrimaryButton(title: "开始\(kind.title)") {
                                mixedKindsStorage = PracticeEngine.encodeMixedKinds(selectedMixedKinds)
                                model.startPractice(
                                    kind,
                                    unitID: unitID == "all" ? nil : unitID,
                                    mixedKinds: selectedMixedKinds
                                )
                            }
                                .disabled(learned.isEmpty).accessibilityIdentifier("practice-start")
                        }
                    }.padding(24)
                }
            }
        }
        .sheet(isPresented: $coachPresented) { SheetContainer(title: "AI学习教练") { AICoachView(coach: model.coach) }.environmentObject(model) }
        .onAppear { selectedMixedKinds = PracticeEngine.decodeMixedKinds(mixedKindsStorage) }
        .onDisappear { model.stopPracticeAudio() }
    }

    private func setMixedKind(_ candidate: PracticeKind, enabled: Bool) {
        var next = selectedMixedKinds
        if enabled {
            next.insert(candidate)
        } else if next.count > 1 {
            next.remove(candidate)
        }
        selectedMixedKinds = next
        mixedKindsStorage = PracticeEngine.encodeMixedKinds(next)
    }
}

struct PracticeFlowView: View {
    @EnvironmentObject var model: LearningModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var round: PracticeRound
    @State private var entry = ""
    @State private var selectedEnglishID: String?
    @State private var wrongFlash = false
    var body: some View {
        Group {
            if let question = round.current {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(question.kind.title) · \(round.position + 1) / \(round.questions.count)").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("暂停") { model.pausePractice() }.font(.system(size: 13)).accessibilityIdentifier("practice-pause")
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                    ProgressView(value: Double(round.position), total: Double(max(1, round.questions.count))).padding(.horizontal, 24)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            prompt(question)
                            if question.kind != .matching { WordStudyHistory(wordID: question.word.id, roundID: round.id) }
                            if question.completed {
                                completed(question)
                            } else {
                                answers(question)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                            .background(wrongFlash ? Color.red.opacity(0.1) : Color.clear)
                    }
                    if question.completed {
                        HStack {
                            PrimaryButton(title: round.position + 1 == round.questions.count ? "查看结果" : "下一题") { model.advancePractice() }.accessibilityIdentifier("practice-next")
                        }.padding(.horizontal, 20).padding(.vertical, 6)
                    }
                }.task(id: question.id) {
                    entry = ""; selectedEnglishID = nil; model.stopPracticeAudio()
                    if canRead(question), question.kind != .matching { model.playPracticeWord(question.word, automatic: true) }
                }.task(id: question.errors) {
                    guard question.errors > 0 else { return }
                    let animation = reduceMotion ? nil : Animation.easeInOut(duration: 0.12).repeatCount(4, autoreverses: true)
                    withAnimation(animation) { wrongFlash = true }
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    wrongFlash = false
                }
            } else {
                VStack(spacing: 22) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundColor(Palette.blue)
                    Text("这轮练习完成了。").font(.system(size: 24, weight: .semibold))
                    Text("完成 \(round.questions.count) 题 · 首次答对 \(round.questions.filter { $0.firstAnswerCorrect == true && $0.errors == 0 }.count) 题")
                        .font(.callout).foregroundColor(Palette.muted)
                    Text("练习已保存，正式复习时间保持不变。").font(.system(size: 12)).foregroundColor(Palette.muted)
                    PrimaryButton(title: "回到练习") { model.endPractice() }.accessibilityIdentifier("practice-finish")
                    Spacer()
                }.padding(24)
            }
        }.onDisappear { model.stopPracticeAudio() }
    }
    private func canRead(_ q: PracticeQuestion) -> Bool {
        q.kind != .matching || q.completed
    }
    @ViewBuilder private func prompt(_ q: PracticeQuestion) -> some View {
        switch q.kind {
        case .meaning:
            HStack(spacing: 8) {
                Text(q.word.word).font(.system(size: 34, weight: .bold, design: .serif))
                speakerButton(for: q.word)
            }
            Text("选择正确词义").font(.callout).foregroundColor(Palette.muted)
        case .matching:
            Text("让单词与词义相遇。").font(.system(size: 24, weight: .semibold))
        case .completion:
            HStack(spacing: 8) {
                Text(q.completed ? q.word.word : (q.blankedText ?? ""))
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                speakerButton(for: q.word)
            }
            Text(q.word.meaning).font(.title3)
        case .sentence:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(q.blankedText ?? "").font(.system(size: 22, design: .serif)).lineSpacing(8)
                speakerButton(for: q.word)
            }
            Text("用 \(q.word.word) 的正确形式补全原句").font(.system(size: 13)).foregroundColor(Palette.blue)
        case .listening:
            HStack(spacing: 8) {
                Text("听一听，选择词义。").font(.system(size: 25, weight: .semibold))
                speakerButton(for: q.word)
            }
        case .spelling:
            HStack(spacing: 8) {
                Text(q.word.meaning).font(.system(size: 25, weight: .semibold))
                speakerButton(for: q.word)
            }
            Text([q.word.pos, q.answerHint].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundColor(Palette.muted)
        case .mixed: EmptyView()
        }
    }
    @ViewBuilder private func answers(_ q: PracticeQuestion) -> some View {
        switch q.kind {
        case .meaning, .listening:
            VStack(spacing: 8) {
                ForEach(q.choices) { choice in
                    option(choice.word.meaning, selected: q.selectedChoiceID == choice.id && q.errors > 0) { model.choosePractice(choice.id) }
                        .accessibilityIdentifier("practice-choice-" + choice.id)
                }
            }
        case .matching: matching(q)
        case .completion:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(q.letterChoices, id: \.self) { letters in option(letters) { model.submitPractice(letters) } }
            }
        case .sentence, .spelling:
            Text(entry.isEmpty ? "点击字母输入" : entry)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
                .background(Color.white).cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
                .accessibilityIdentifier("practice-entry")
            PracticeKeyboard(entry: $entry)
            PrimaryButton(title: "确认") { model.submitPractice(entry) }.disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("practice-submit")
        case .mixed: EmptyView()
        }
    }
    @ViewBuilder private func completed(_ q: PracticeQuestion) -> some View {
        if q.answerRevealed == true {
            Label("答案已揭晓", systemImage: "lightbulb.fill").foregroundColor(.orange)
            Text("这题不计入正确，继续下一题即可。")
                .font(.system(size: 13)).foregroundColor(Palette.muted)
        } else {
            Label("答对了", systemImage: "checkmark.circle.fill").foregroundColor(.green).accessibilityIdentifier("practice-correct")
        }
        if q.kind == .matching { matching(q) }
        else if q.kind == .meaning || q.kind == .listening {
            ForEach(q.choices) { choice in
                HStack(alignment: .top) {
                    Text(choice.word.meaning).frame(maxWidth: .infinity, alignment: .leading)
                    Text(choice.word.word).font(.system(size: 18, weight: .semibold, design: .serif))
                }.font(.system(size: 15)).padding(15).background(choice.word.id == q.word.id ? Palette.pale : Color.white).cornerRadius(14)
            }
        } else {
            Text(q.kind == .completion ? q.word.word : (q.answer ?? q.word.word))
                .font(.system(size: 30, weight: .bold, design: .serif))
            if q.kind == .sentence { Text("原句使用：\(q.answer ?? q.word.word)").font(.callout).foregroundColor(Palette.muted) }
        }
    }
    private func matching(_ q: PracticeQuestion) -> some View {
        let meanings = q.orderedPairs
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 10) { ForEach(q.pairs) { pair in
                matchCell(pair.word.word, done: q.matchedWordIDs.contains(pair.id), selected: selectedEnglishID == pair.id) {
                    selectedEnglishID = pair.id; model.playPracticeWord(pair.word, automatic: false)
                }
            } }.frame(width: 116)
            VStack(spacing: 10) { ForEach(meanings) { pair in
                matchCell(meaningPreview(pair.word.meaning), done: q.matchedWordIDs.contains(pair.id), selected: false) {
                    if let english = selectedEnglishID { model.matchPractice(englishID: english, meaningID: pair.id); selectedEnglishID = nil }
                }
            } }.frame(maxWidth: .infinity)
        }
    }
    private func matchCell(_ title: String, done: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14))
                .lineLimit(2).minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).frame(minHeight: 68).padding(.horizontal, 8)
        }
            .foregroundColor(done ? .green : Palette.ink).background(done ? Color.green.opacity(0.1) : selected ? Palette.pale : Color.white)
            .cornerRadius(14).overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Palette.blue : Palette.line)).disabled(done)
    }
    private func option(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 16)).frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 20).padding(.vertical, 12) }
            .foregroundColor(Palette.ink).background(Color.white).cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.red : Palette.line, lineWidth: selected ? 2 : 1))
    }
    private func speakerButton(for word: MobileWord) -> some View {
        Button { model.playPracticeWord(word, automatic: false) } label: {
            Image(systemName: "speaker.wave.2.fill").frame(width: 36, height: 36)
        }.accessibilityLabel("朗读单词")
    }
    private func meaningPreview(_ value: String) -> String {
        let separators = CharacterSet(charactersIn: "；;，,、/\n")
        let parts = value.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.prefix(2).joined(separator: "；")
    }
}

struct PracticeKeyboard: View {
    @Binding var entry: String
    private let rows = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 6) {
                    ForEach(rows[rowIndex], id: \.self) { letter in
                        Button(String(letter).uppercased()) {
                            guard entry.count < 32 else { return }
                            entry.append(letter)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                        .accessibilityIdentifier("practice-key-\(letter)")
                    }
                    if rowIndex == rows.count - 1 {
                        Button {
                            guard !entry.isEmpty else { return }
                            entry.removeLast()
                        } label: {
                            Image(systemName: "delete.left")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .background(Color.white).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                        .accessibilityIdentifier("practice-key-backspace")
                    }
                }
            }
        }
    }
}
