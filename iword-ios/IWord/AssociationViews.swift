import SwiftUI

/// A compact, deliberately non-etymological memory card for one word.
struct AssociationCard: View {
    let association: PersonalAssociation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text("我的提示词")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("个人记忆")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.muted)
            }
            if !association.chunks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("字形分段")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.muted)
                    Text(association.chunks)
                        .font(.system(size: 16, weight: .medium, design: .serif))
                        .lineSpacing(3)
                }
            }
            if !association.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("提示词")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.muted)
                    Text(association.cue)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                }
            }
            if !association.story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("联想内容")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.muted)
                    Text(association.story)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                }
            }
            Text("非词源，仅作个人记忆线索")
                .font(.system(size: 10))
                .foregroundColor(Palette.muted)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.pale)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.blue.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("我的提示词：\(association.accessibilityText)")
    }
}

struct AssociationEditorSheet: View {
    @EnvironmentObject var model: LearningModel
    @Environment(\.dismiss) private var dismiss
    let word: MobileWord
    let existing: PersonalAssociation?
    var onSaved: (PersonalAssociation) -> Void = { _ in }
    @State private var chunks: String
    @State private var cue: String
    @State private var story: String
    @State private var waitingForSave = false
    @State private var pendingSaveVersion = 0

    init(word: MobileWord, existing: PersonalAssociation?, onSaved: @escaping (PersonalAssociation) -> Void = { _ in }) {
        self.word = word
        self.existing = existing
        self.onSaved = onSaved
        _chunks = State(initialValue: existing?.chunks ?? "")
        _cue = State(initialValue: existing?.cue ?? "")
        _story = State(initialValue: existing?.story ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(word.word)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                    Text("写下容易让你想起词义的线索。")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.muted)
                }
                Section {
                    associationEditor("提示词", placeholder: "例如：板子、旧电脑；按你自己的记法填写。", text: $cue, limit: 200)
                } footer: {
                    Text("第一次提示只显示这段。")
                }
                Section {
                    associationEditor("联想内容（可选）", placeholder: "用一小段话把它和你的经历连起来。", text: $story, limit: 500)
                } footer: {
                    Text("第二次提示和揭晓后显示这段。保存后用于后续新学习组。")
                }
                Section {
                    Text("非词源，仅作个人记忆线索")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                }
            }
            .navigationTitle(existing == nil || existing?.isEmpty == true ? "添加提示" : "编辑提示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(model.busy || waitingForSave)
                }
            }
        }
        .tint(Palette.blue)
        .onChange(of: model.busy) { busy in
            if !busy && model.associationSavedVersion == pendingSaveVersion { waitingForSave = false }
        }
        .onChange(of: model.associationSavedVersion) { _ in
            guard waitingForSave else { return }
            waitingForSave = false
            onSaved(model.association(for: word) ?? PersonalAssociation(chunks: chunks, cue: cue, story: story, source: "personal"))
            dismiss()
        }
    }

    private func associationEditor(_ title: String, placeholder: String, text: Binding<String>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                Text("\(text.wrappedValue.count)/\(limit)")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.muted)
            }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundColor(Palette.muted.opacity(0.8))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: text)
                    .font(.system(size: 14))
                    .frame(minHeight: 68)
                    .padding(.horizontal, -4)
                    .onChange(of: text.wrappedValue) { value in
                        if value.count > limit { text.wrappedValue = String(value.prefix(limit)) }
                    }
            }
        }
    }

    private func save() {
        let value = PersonalAssociation(
            chunks: chunks.trimmingCharacters(in: .whitespacesAndNewlines),
            cue: cue.trimmingCharacters(in: .whitespacesAndNewlines),
            story: story.trimmingCharacters(in: .whitespacesAndNewlines),
            source: "personal",
            updatedAt: Date()
        )
        pendingSaveVersion = model.associationSavedVersion
        waitingForSave = true
        model.saveAssociation(value, for: word)
    }
}

struct WordAssociationSection: View {
    @EnvironmentObject var model: LearningModel
    let word: MobileWord
    @State private var association: PersonalAssociation?
    @State private var editing = false

    init(word: MobileWord) {
        self.word = word
        _association = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("个人提示").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 4)
                Button(association?.isEmpty == false ? "编辑" : "添加提示") { editing = true }
                    .font(.system(size: 12, weight: .medium))
            }
            if let association, !association.isEmpty {
                AssociationCard(association: association)
            } else {
                Text("还没有个人提示。写下一点容易记住的线索，之后会在揭晓后出现。")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.muted)
                    .lineSpacing(4)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.pale.opacity(0.55))
                    .cornerRadius(15)
            }
        }
        .onAppear { association = model.association(for: word) }
        .sheet(isPresented: $editing) {
            AssociationEditorSheet(word: word, existing: association) { saved in association = saved }
                .environmentObject(model)
        }
    }
}

private extension PersonalAssociation {
    var accessibilityText: String {
        [chunks, cue, story].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "；")
    }
}
