import SwiftUI

/// Imported lexical material is kept separate from user-created mnemonic hints.
enum WordFormation {
    static let titles = ["mnemonic": "词条助记", "root": "构词解释", "etymology": "词源补充", "structure": "构词解释"]
    static func parts(_ word: MobileWord) -> [WordPart] {
        let values = word.parts.filter { titles[$0.type] != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let composition = values.filter { $0.type == "root" || $0.type == "structure" }
        var result: [WordPart] = []
        if !composition.isEmpty {
            func unique(_ values: [String]) -> [String] {
                var seen: Set<String> = []
                return values.filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            result.append(WordPart(type: "structure",
                                   text: unique(composition.map(\.text)).joined(separator: "\n"),
                                   translation: unique(composition.compactMap(\.translation)).joined(separator: "\n")))
        }
        result += values.filter { $0.type == "etymology" }
        // Once curated composition is supplied, avoid repeating the original
        // mnemonic split here. Original mnemonic parts remain in the content.
        if composition.isEmpty { result += values.filter { $0.type == "mnemonic" } }
        return result
    }
}

struct WordFormationView: View {
    let word: MobileWord
    var showUnavailable = false
    var body: some View {
        let parts = WordFormation.parts(word)
        if !parts.isEmpty || showUnavailable {
            DisclosureGroup("词根、词源与组成") {
                VStack(alignment: .leading, spacing: 12) {
                    if parts.isEmpty {
                        Text("本词暂无这类资料，补充后可通过更新词库获取。")
                            .font(.system(size: 12)).foregroundColor(Palette.muted)
                    }
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(WordFormation.titles[part.type] ?? "构词资料")
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.blue)
                            Text(part.text).font(.system(size: 14)).lineSpacing(4)
                            if let translation = part.translation, !translation.isEmpty {
                                Text(translation).font(.system(size: 12)).foregroundColor(Palette.muted)
                            }
                        }
                    }
                    Text("词条助记可能含记忆拆分，不等同于真实词源；词源资料需在词库中补充来源。")
                        .font(.system(size: 10)).foregroundColor(Palette.muted)
                }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 13)).padding(14).background(Color.white).cornerRadius(14)
        }
    }
}
