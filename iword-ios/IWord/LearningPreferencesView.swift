import SwiftUI

struct WordStudyHistory: View {
    @EnvironmentObject var model: LearningModel
    var wordID: String
    var roundID: String? = nil
    var body: some View {
        let progress = model.state.progress[wordID]
        let current = roundID ?? model.state.active?.id
        let inThisRound = current != nil && progress?.lastCreditedRoundID == current
        let count = max(0, (progress?.studyCount ?? 0) - (inThisRound ? 1 : 0))
        let previous = inThisRound ? progress?.previousStudiedAt : progress?.lastStudiedAt
        Text("已学 \(count) 次 · " + (previous.map { "上次：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚无上次学习记录"))
            .font(.system(size: 11)).foregroundColor(Palette.muted).accessibilityIdentifier("word-study-history")
    }
}
struct LearningPreferencesView: View {
    @EnvironmentObject var model: LearningModel
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = LearningPreferences()
    @State private var reminderTime = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新词学习顺序").font(.headline)
                Picker("新词学习顺序", selection: $preferences.order) {
                    Text("顺序").tag("sequential"); Text("系统推荐").tag("recommended")
                }.pickerStyle(.segmented).accessibilityIdentifier("learning-order")
                Text(preferences.order == "sequential" ? "按分类、单元和书中顺序学习，跳过已学与已认识的词。" : "优先陌生词，结合已有记录安排；记录较少时沿用书中顺序。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("每天新学 \(preferences.dailyNewWords) 个词").font(.headline)
                    Spacer(minLength: 0)
                    Button { preferences.dailyNewWords = max(0, preferences.dailyNewWords - 1) } label: {
                        Image(systemName: "minus").frame(width: 44, height: 44)
                    }.disabled(preferences.dailyNewWords == 0).accessibilityLabel("减少每日新词").accessibilityIdentifier("daily-new-decrease")
                    Button { preferences.dailyNewWords = min(50, preferences.dailyNewWords + 1) } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }.disabled(preferences.dailyNewWords == 50).accessibilityLabel("增加每日新词").accessibilityIdentifier("daily-new-increase")
                }.background(Palette.pale.opacity(0.3)).cornerRadius(12)
                Text("早上 \((preferences.dailyNewWords + 1) / 2) 个 · 下午 \(preferences.dailyNewWords / 2) 个 · 晚上复习")
                    .font(.system(size: 13)).foregroundColor(Palette.blue).accessibilityIdentifier("daily-new-distribution")
                Text("设为0时只复习。这是每日上限，每组最多5词；减负策略会在薄弱词较多时暂缓新词。复习不占新词额度，今天已学数量继续累计。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("这一轮怎么安排").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.ink)
                    Text("本轮试用建议每天最多6个新词，早上3个、下午3个。首次进入时会降低新词上限，之后仍可用上方0–50控件调整；当天不必学满。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(4)
                }
                .padding(12)
                .background(Palette.pale.opacity(0.55))
                .cornerRadius(12)
            }.padding(18).background(Color.white).cornerRadius(16)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("晚间学习提醒", isOn: $preferences.reminderEnabled).accessibilityIdentifier("evening-reminder-toggle")
                if preferences.reminderEnabled {
                    DatePicker("提醒时间", selection: $reminderTime, displayedComponents: .hourAndMinute)
                }
                Text("开启时会申请通知权限。提醒可离线送达；当天晚间复习完成后取消当天提醒。每次打开App会续排未来四周的提醒。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(4)
            }
            PrimaryButton(title: "保存学习偏好") {
                let time = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
                preferences.reminderHour = time.hour ?? 20; preferences.reminderMinute = time.minute ?? 30
                model.saveLearningPreferences(preferences)
            }
        }.onAppear {
            preferences = model.state.profile.preferences
            reminderTime = Calendar.current.date(bySettingHour: preferences.reminderHour, minute: preferences.reminderMinute, second: 0, of: Date()) ?? Date()
        }.onChange(of: model.preferencesSavedVersion) { _ in dismiss() }
    }
}
