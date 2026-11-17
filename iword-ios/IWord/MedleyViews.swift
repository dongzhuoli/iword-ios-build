import SwiftUI

struct MedleyScreen: View {
    @EnvironmentObject var model: LearningModel
    @EnvironmentObject var medley: MedleyController
    @EnvironmentObject var player: MedleyPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MedleyRule = .weak
    @State private var count = 20
    @State private var gap = 5
    @State private var unitID = ""
    private var units: [VocabularyUnit] {
        VocabularyUnit.grouped(model.state.availableWords.filter { model.state.progress[$0.id]?.learned == true })
    }
    private var selected: [MobileWord] { MedleyPlan.words(state: model.state, rule: rule, unitID: unitID, limit: count) }
    private var unavailableReason: String? { MedleyPlan.unavailableReason(state: model.state, rule: rule, unitID: unitID) }
    private var canUseDistant: Bool { !MedleyPlan.words(state: model.state, rule: .distant, unitID: nil, limit: 1).isEmpty }
    var body: some View {
        Group {
            if player.isActive || player.isFinished {
                MedleyPlayerView(close: { dismiss() })
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("听音串烧").font(.headline)
                        Spacer()
                        Button { medley.cancelPreparation(); dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭串烧设置")
                    }.padding(.horizontal, 24).padding(.top, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Image(systemName: "headphones").font(.system(size: 36)).foregroundColor(Palette.blue)
                            Text("闭上眼，也能再听一遍。").font(.system(size: 25, weight: .semibold))
                            Text("英文 → 停顿回想 → 中文释义 → 再听英文\n只听，不改变学习次数、时间或熟练程度。")
                                .font(.system(size: 13)).foregroundColor(Palette.muted).lineSpacing(6)
                            VStack(alignment: .leading, spacing: 18) {
                                Picker("选词规则", selection: $rule) { ForEach(MedleyRule.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                                if rule == .unit {
                                    Picker("选择单元", selection: $unitID) {
                                        Text("请选择单元").tag("")
                                        ForEach(units) { unit in Text(VocabularyUnit.categoryTitle(unit.category) + " · " + unit.title).tag(unit.id) }
                                    }.pickerStyle(.menu)
                                }
                                Stepper("串烧 \(count) 个词", value: $count, in: 1...100).accessibilityIdentifier("medley-count")
                                Picker("回想停顿", selection: $gap) {
                                    Text("3秒").tag(3); Text("5秒").tag(5); Text("8秒").tag(8)
                                }.pickerStyle(.segmented)
                            }.padding(18).background(Color.white).cornerRadius(18).disabled(medley.preparing)
                            Text("本轮可播放 \(selected.count) 个词；仅使用已学且有本地原书录音的词条。")
                                .font(.system(size: 12)).foregroundColor(Palette.muted)
                            if selected.isEmpty, !medley.preparing, let reason = unavailableReason {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(reason).font(.system(size: 13)).foregroundColor(Palette.muted).accessibilityIdentifier("medley-empty-reason")
                                    if rule != .distant && canUseDistant {
                                        Button("改听遥远记忆串烧") { rule = .distant; medley.error = nil }
                                            .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                                            .accessibilityIdentifier("medley-use-distant")
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(14)
                            }
                            if !medley.preparing && (model.busy || model.backupBusy || model.updateBusy) {
                                Text("正在保存或更新数据，完成后即可开始串烧。").font(.system(size: 12)).foregroundColor(Palette.muted)
                            }
                            if medley.preparing {
                                ProgressView(value: Double(medley.prepared), total: Double(max(1, medley.total)))
                                Text("正在准备串烧音频 · \(medley.prepared) / \(medley.total)").font(.callout)
                                Text("首次准备请保持在此页面，准备完成后可以锁屏播放。").font(.system(size: 12)).foregroundColor(Palette.muted)
                                Button("取消准备") { medley.cancelPreparation() }.frame(minHeight: 44)
                            } else {
                                PrimaryButton(title: selected.isEmpty ? "暂无可播放词" : "开始串烧") {
                                    model.stopViewedWord(); model.stopPracticeAudio()
                                    medley.prepare(words: selected, title: rule == .unit ? "按单元串烧 · " + (units.first { $0.id == unitID }?.title ?? "") : rule.title, gap: gap)
                                }.disabled(selected.isEmpty || model.busy || model.backupBusy || model.updateBusy).opacity(selected.isEmpty ? 0.45 : 1).accessibilityIdentifier("medley-start")
                            }
                            if let error = medley.error { Text(error).font(.callout).foregroundColor(.red).accessibilityIdentifier("medley-preparation-error") }
                            Text("中文使用手机系统普通话声音。播完自动停止；“没想起”仅在本轮末尾再听一次。")
                                .font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(5)
                        }.padding(24)
                    }
                }.background(Palette.paper.ignoresSafeArea()).foregroundColor(Palette.ink).tint(Palette.blue)
            }
        }.onAppear { if unitID.isEmpty { unitID = units.first?.id ?? "" } }
            .onDisappear { medley.cancelPreparation() }
    }
}

struct MedleyPlayerView: View {
    @EnvironmentObject var player: MedleyPlayer
    var close: () -> Void
    private let night = Color(red: 0.035, green: 0.065, blue: 0.12)
    private let muted = Color(red: 0.57, green: 0.65, blue: 0.76)
    private var revealsMeaning: Bool { ["中文释义", "再听一次", "稍作停留", "下一词前停留"].contains(player.stage) || player.isFinished }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 620
            let reservedHeight: CGFloat = (compact ? 260 : 300) + (player.error == nil ? 0 : 40)
            let cardHeight = max(140, min(compact ? 260 : 320, geometry.size.height - reservedHeight))
            VStack(spacing: compact ? 8 : 12) {
                HStack {
                    Button(action: close) { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("收起播放器")
                    Spacer(); Text("听音串烧").font(.system(size: 13, weight: .semibold)); Spacer()
                    Image(systemName: "moon.stars").frame(width: 44, height: 44).foregroundColor(muted)
                }
                Text(player.title).font(.system(size: 12)).foregroundColor(muted).lineLimit(1).minimumScaleFactor(0.75)
                // Bound the card rather than stretching the gap above progress.
                // Only a long meaning scrolls; playback controls stay on screen.
                VStack(spacing: compact ? 10 : 14) {
                    if !compact {
                        Image(systemName: "waveform").font(.system(size: 24)).foregroundColor(Color(red: 0.48, green: 0.62, blue: 0.94))
                    }
                    VStack(spacing: 8) {
                        Text(player.current?.word ?? "这一轮，听完了。")
                            .font(.system(size: compact ? 34 : 40, weight: .semibold, design: .serif))
                            .lineLimit(1).minimumScaleFactor(0.4)
                        if let word = player.current {
                            Text("/" + word.phonetic + "/").font(.system(size: 14)).foregroundColor(muted).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        HStack(spacing: 8) {
                            Text(player.isFinished ? "今晚就到这里，好好休息。" : player.isPlaying ? player.stage : "已暂停")
                            if player.stage == "回想一下" && !player.isFinished {
                                Text("\(player.remaining)").monospacedDigit()
                            }
                        }.font(.system(size: 13)).foregroundColor(muted).lineLimit(1).minimumScaleFactor(0.8)
                    }.layoutPriority(1)
                    ScrollView {
                        Text(revealsMeaning ? player.current?.meaning ?? "" : " ")
                            .font(.system(size: compact ? 18 : 20)).multilineTextAlignment(.center).lineSpacing(5)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxHeight: .infinity)
                }.padding(compact ? 16 : 20)
                    .frame(maxWidth: .infinity).frame(height: cardHeight)
                    .background(Color.white.opacity(0.045)).cornerRadius(26)
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.white.opacity(0.06)))
                VStack(spacing: 8) {
                    ProgressView(value: Double(player.isFinished ? player.tracks.count : player.index), total: Double(max(1, player.tracks.count)))
                        .tint(Color(red: 0.48, green: 0.62, blue: 0.94))
                    HStack {
                        Text(player.isReplay ? "再听一次" : "本轮进度")
                        Spacer()
                        Text("\(player.isFinished ? player.tracks.count : min(player.index + 1, player.tracks.count)) / \(player.tracks.count)").monospacedDigit()
                    }.font(.system(size: 12)).foregroundColor(muted)
                }.fixedSize(horizontal: false, vertical: true)
                if let error = player.error {
                    Text(error).font(.system(size: 12)).foregroundColor(.orange).multilineTextAlignment(.center).lineLimit(2)
                }
                HStack(spacing: 24) {
                    Button { player.markForgotten() } label: {
                        VStack(spacing: 6) { Image(systemName: "arrow.uturn.backward").font(.system(size: 23)); Text("没想起").font(.system(size: 12)) }
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }.disabled(player.isReplay || !player.isActive).accessibilityIdentifier("medley-forgot")
                    Button { if player.isPlaying { player.pause() } else { player.resume() } } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 27))
                            .frame(width: compact ? 64 : 72, height: compact ? 64 : 72)
                            .foregroundColor(night).background(Color(red: 0.64, green: 0.74, blue: 0.94)).clipShape(Circle())
                    }.disabled(!player.isActive).accessibilityLabel(player.isPlaying ? "暂停串烧" : "继续串烧").accessibilityIdentifier("medley-play-pause")
                    Button { player.next() } label: {
                        VStack(spacing: 6) { Image(systemName: "forward.end.fill").font(.system(size: 23)); Text("下一个").font(.system(size: 12)) }
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }.disabled(!player.isActive).accessibilityIdentifier("medley-next")
                }.foregroundColor(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(player.markedCount > 0 ? "本轮标记 \(player.markedCount) 个 · 结束前再听一次" : "只听一听，不改变学习进度")
                        .font(.system(size: 11)).foregroundColor(muted).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("结束") { player.end(); close() }.font(.system(size: 14)).foregroundColor(muted)
                        .frame(minWidth: 56, minHeight: 44).accessibilityIdentifier("medley-end")
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, compact ? 20 : 24).padding(.vertical, 8)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.background(night.ignoresSafeArea()).foregroundColor(Color(red: 0.87, green: 0.9, blue: 0.96)).preferredColorScheme(.dark)
    }
}

struct MedleyMiniPlayer: View {
    @EnvironmentObject var player: MedleyPlayer
    var open: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "headphones")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.current?.word ?? "听音串烧").font(.system(size: 16, weight: .semibold, design: .serif))
                        Text(player.isPlaying ? "正在串烧 · 点击返回播放器" : "串烧已暂停").font(.system(size: 10)).foregroundColor(Palette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("medley-mini-open")
            Button { if player.isPlaying { player.pause() } else { player.resume() } } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
            }.accessibilityLabel(player.isPlaying ? "暂停串烧" : "继续串烧")
            Button { player.end() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("结束串烧")
        }.padding(.horizontal, 20).padding(.vertical, 6).background(Palette.pale).foregroundColor(Palette.ink)
    }
}
