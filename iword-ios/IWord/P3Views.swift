import SwiftUI
import UniformTypeIdentifiers

struct ReportView: View {
    @EnvironmentObject var model: LearningModel
    private var report: StudyReportSummary { StudyReport.summary(state: model.state, events: model.events) }
    var body: some View {
        let value = report
        VStack(alignment: .leading, spacing: 20) {
            Text("\(LocalState.studyDay(value.start)) — \(LocalState.studyDay(value.end))").font(.system(size: 12)).foregroundColor(Palette.muted)
            HStack { Stat(value: value.learnedUnknown, label: "新学陌生词"); Stat(value: value.standardRecalls, label: "常规回忆"); Stat(value: value.reviewRecalls, label: "巩固回忆") }
            VStack(alignment: .leading, spacing: 10) {
                Text(value.delayedRate).font(.system(size: 36, weight: .semibold, design: .serif)).foregroundColor(Palette.blue)
                Text("延迟独立回忆率").font(.system(size: 14))
                Text("至少间隔12小时，共 \(value.delayedSamples) 次；独立想起 \(value.delayedIndependent) 次，辅助想起 \(value.delayedAssisted) 次。").font(.system(size: 12)).foregroundColor(Palette.muted)
                if value.delayedSamples < 10 { Text("样本较少，暂不据此判断记忆效果。").font(.system(size: 11)).foregroundColor(Palette.muted) }
                Text("首次延迟样本 \(value.firstDelayedSamples) 次，独立成功 \(value.firstDelayedSuccess) 次。").font(.system(size: 11)).foregroundColor(Palette.muted)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(16)
            VStack(alignment: .leading, spacing: 7) {
                Text("隔天首次回忆").font(.system(size: 14, weight: .semibold))
                Text("样本 \(value.associationReport.samples) 次 · 直接想起 \(value.associationReport.directRecall) 次（\(value.associationReport.directRate)）")
                    .font(.system(size: 13))
                Text("联想辅助 \(value.associationReport.associationAssisted) · 其他辅助 \(value.associationReport.otherAssisted) · 没想起 \(value.associationReport.notRecalled)")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                Text("联想版本样本：有 \(value.associationReport.withAssociationVersion) · 无 \(value.associationReport.withoutAssociationVersion)")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
                if value.associationReport.needsCaution {
                    Text("样本较少，暂不据此判断记忆效果。").font(.system(size: 11)).foregroundColor(Palette.muted)
                }
            }.padding(.vertical, 3)
            Text("词义辨认完成 \(value.recognitionCompleted) 次，其中选对 \(value.recognitionCorrect) 次；与独立回忆分开统计。").font(.system(size: 12)).foregroundColor(Palette.muted)
            Text("每天的学习").font(.headline)
            ForEach(value.days, id: \.day) { day in
                HStack {
                    Text(String(day.day.suffix(5))).font(.system(size: 13))
                    Spacer()
                    Text("新学 \(day.newWords) · 回忆 \(day.recalls) · 巩固 \(day.reviews)").font(.system(size: 12)).foregroundColor(Palette.muted)
                }.padding(.vertical, 7)
            }
            Text("前台活动约 \(value.activeMs / 60000) 分钟 · 提示 \(value.hints) 次 · 旧口径音频辅助 \(value.audioAssisted) 次").font(.system(size: 12)).foregroundColor(Palette.muted)
            if !value.weakWords.isEmpty {
                Text("容易忘的词").font(.headline)
                ForEach(value.weakWords, id: \.self) { Text($0).font(.system(size: 14, design: .serif)) }
            }
            BackupOperationStatus()
            PrimaryButton(title: "导出七天报告") { model.exportStudyReport() }.disabled(model.backupBusy)
            Text("报告包含HTML、CSV和原始日志。辨认与独立回忆分开统计；新版英文朗读不算词义提示。隔天首次回忆的旧记录按实际间隔反推日期，仅作兼容估计。旧记录保留原口径，活动时长为近似值。").font(.system(size: 11)).foregroundColor(Palette.muted).lineSpacing(4)
        }
    }
}

struct BackupOperationStatus: View {
    @EnvironmentObject var model: LearningModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.backupStatus.isEmpty { Text(model.backupStatus).font(.system(size: 12)).foregroundColor(Palette.muted).accessibilityIdentifier("backup-status") }
            if model.backupBusy {
                ProgressView(value: model.backupProgress)
                Button("取消操作") { model.cancelBackupTransfer() }.frame(minHeight: 44)
            }
            if let error = model.backupError { Text(error).font(.system(size: 12)).foregroundColor(.red).accessibilityIdentifier("backup-error") }
        }
    }
}
struct BackupRestorePreview: View {
    @EnvironmentObject var model: LearningModel
    @State private var confirm = false
    var body: some View {
        if let preview = model.restorePreview {
            VStack(alignment: .leading, spacing: 14) {
                Text("恢复预览").font(.headline)
                Text(preview.manifest.createdAt).font(.system(size: 12)).foregroundColor(Palette.muted)
                Text("\(preview.manifest.wordCount) 词 · \(preview.manifest.eventCount) 条日志 · 学过 \(preview.state.progress.values.filter(\.learned).count) 词").font(.system(size: 13))
                if let task = preview.state.active {
                    Text("未完成任务：第 \(task.position + 1) / \(task.steps.count) 步").font(.system(size: 12))
                }
                Text("恢复会替换本机学习档案、进度与设置。确认前将自动完整备份当前档案。请只在一部手机上继续学习。").font(.system(size: 12)).foregroundColor(Palette.muted)
                HStack {
                    Button("取消恢复") { model.discardRestorePreview() }.frame(maxWidth: .infinity, minHeight: 44)
                    Button("确认恢复") { confirm = true }.frame(maxWidth: .infinity, minHeight: 44).foregroundColor(.white).background(Palette.blue).cornerRadius(12)
                }.disabled(model.backupBusy)
            }.padding(18).background(Color.white).cornerRadius(16)
                .alert("替换本机学习档案？", isPresented: $confirm) {
                    Button("取消", role: .cancel) {}
                    Button("恢复", role: .destructive) { model.confirmRestore() }
                } message: { Text("当前档案会先保存为完整备份，恢复后不会与原进度合并。") }
        }
    }
}
struct LocalBackupView: View {
    @EnvironmentObject var model: LearningModel
    @State private var importer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("把词库、录音、学习记录和未完成任务一起保存。").font(.system(size: 14))
            PrimaryButton(title: "创建完整备份") { model.createLocalBackup() }.disabled(model.backupBusy || model.updateBusy)
            Button("从文件恢复") { importer = true }.frame(maxWidth: .infinity, minHeight: 48).background(Color.white).cornerRadius(13).disabled(model.backupBusy || model.updateBusy)
            BackupOperationStatus()
            BackupRestorePreview()
            if !model.localBackups.isEmpty {
                Text("本机保留的备份").font(.headline)
                ForEach(model.localBackups, id: \.path) { url in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(backupDate(url)).font(.system(size: 13))
                        HStack {
                            Button("分享保存") { model.shareBackup(url) }.frame(maxWidth: .infinity, minHeight: 44)
                            Button("预览恢复") { model.previewRestore(url) }.frame(maxWidth: .infinity, minHeight: 44)
                        }.font(.system(size: 13)).disabled(model.backupBusy)
                    }.padding(16).background(Color.white).cornerRadius(14)
                }
            }
            Text("本机备份仍在App内，卸载可能一并删除。请分享保存到“文件”或同步到服务器。重签名前建议先备份。").font(.system(size: 11)).foregroundColor(Palette.muted).lineSpacing(4)
        }.onAppear { model.refreshLocalBackups() }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): model.previewRestore(url)
                case .failure(let error): model.message = "未选择备份：\(error.localizedDescription)"
                }
            }
    }
    private func backupDate(_ url: URL) -> String {
        if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate { return date.formatted(date: .abbreviated, time: .shortened) }
        return url.lastPathComponent
    }
}
struct ServerSyncView: View {
    @EnvironmentObject var model: LearningModel
    @State private var phone = ""
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("将手机学习档案完整保存到你的电脑服务器。").font(.system(size: 14))
            Text(model.state.profile.serverBaseURL.isEmpty ? "请先设置词库服务器地址。" : model.state.profile.serverBaseURL).font(.system(size: 11)).foregroundColor(Palette.muted)
            VStack(spacing: 12) {
                TextField("电脑端使用的手机号", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber).accessibilityIdentifier("backup-phone")
                Divider()
                TextField("名称（首次连接时填写）", text: $name).textInputAutocapitalization(.never)
            }.padding(16).background(Color.white).cornerRadius(14).disabled(model.backupBusy)
            PrimaryButton(title: "同步到服务器") { model.syncToServer(phone: phone, name: name) }.disabled(model.backupBusy || model.updateBusy || model.state.profile.serverBaseURL.isEmpty)
            Button("查看服务器备份") { model.refreshServerBackups(phone: phone, name: name) }.frame(maxWidth: .infinity, minHeight: 44).disabled(model.backupBusy || model.state.profile.serverBaseURL.isEmpty)
            BackupOperationStatus()
            BackupRestorePreview()
            ForEach(model.serverBackups) { backup in
                VStack(alignment: .leading, spacing: 9) {
                    Text(backup.createdAt).font(.system(size: 13))
                    Text("\(backup.wordCount) 词 · \(backup.eventCount) 条日志 · " + ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)).font(.system(size: 11)).foregroundColor(Palette.muted)
                    Button("下载并预览恢复") { model.downloadServerBackup(backup) }.font(.system(size: 13)).frame(minHeight: 44).disabled(model.backupBusy)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(14)
            }
            Text("仅在点击时上传。电脑端可查看手机报告并下载备份；手机与Web学习进度分别保留。失败时本机保留同一份备份，重试不会重复创建服务器副本。").font(.system(size: 11)).foregroundColor(Palette.muted).lineSpacing(4)
        }
    }
}
