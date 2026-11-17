import Foundation

struct MedleyTrack {
    var word: MobileWord
    var englishURL: URL
    var chineseURL: URL
    /// The fully rendered, single-format CAF used by the player.  Keeping the
    /// source URLs is useful for preparation diagnostics, while playback only
    /// accepts this serialised asset and therefore never has to mix MP3 and
    /// speech CAF tracks at runtime.
    var playbackURL: URL?
    var segments: [MedleyAudioSegment]

    init(
        word: MobileWord,
        englishURL: URL,
        chineseURL: URL,
        playbackURL: URL? = nil,
        segments: [MedleyAudioSegment] = []
    ) {
        self.word = word
        self.englishURL = englishURL
        self.chineseURL = chineseURL
        self.playbackURL = playbackURL
        self.segments = segments
    }
}

/// Frame boundaries are retained rather than guessed from compressed-source
/// durations.  This makes the stage display agree with the PCM asset that is
/// actually sent to AVQueuePlayer.
struct MedleyAudioSegment: Codable, Equatable {
    var startFrame: Int64
    var frameCount: Int64
    var stage: String
}

enum MedleyRule: String, CaseIterable, Identifiable {
    case weak, distant, unit
    var id: String { rawValue }
    var title: String {
        switch self { case .weak: return "薄弱词串烧"; case .distant: return "遥远记忆串烧"; case .unit: return "按单元串烧" }
    }
}

/// Listening reads learning state but never credits a word or updates any timestamp.
enum MedleyPlan {
    static func words(state: LocalState, rule: MedleyRule, unitID: String?, limit: Int) -> [MobileWord] {
        guard (1...100).contains(limit) else { return [] }
        let ordered = candidates(state: state, rule: rule, unitID: unitID)
        // Skip absent/empty audio before taking the requested count, so a missing file does not consume a place.
        return Array(ordered.filter(playable).prefix(limit))
    }

    /// Explain an empty queue instead of leaving a silent, disabled Start button.
    static func unavailableReason(state: LocalState, rule: MedleyRule, unitID: String?) -> String? {
        let learned = state.availableWords.filter { state.progress[$0.id]?.learned == true }
        guard !learned.isEmpty else { return "还没有已学词。先完成一组学习，再来听串烧。" }
        if rule == .unit && (unitID ?? "").isEmpty { return "请先选择要听的单元。" }
        let ordered = candidates(state: state, rule: rule, unitID: unitID)
        if ordered.isEmpty {
            return rule == .weak ? "当前没有需要巩固的薄弱词，可以改听遥远记忆或按单元串烧。" : "这个单元还没有已学词，请换一个单元。"
        }
        if ordered.allSatisfy({ $0.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "这些词暂缺中文释义，请更新词库后再试。"
        }
        guard !ordered.contains(where: playable) else { return nil }
        return "这些已学词还没有可用的本地原书录音，请到词库更新中下载录音，或换一种选词规则。"
    }

    private static func playable(_ word: MobileWord) -> Bool {
        guard let hash = word.audioHash, let url = try? ContentInstaller.audioURL(hash),
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return bytes > 0 && !word.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func candidates(state: LocalState, rule: MedleyRule, unitID: String?) -> [MobileWord] {
        let learned = state.availableWords.filter { state.progress[$0.id]?.learned == true }
        let ordered: [MobileWord]
        switch rule {
        case .weak:
            // Learning may precede the first self-rating. An unrated learned word
            // still needs reinforcement and must not disappear from weak listening.
            let ids = Set(learned.filter {
                guard let progress = state.progress[$0.id] else { return false }
                return progress.latestRating == nil || progress.latestHinted || progress.latestRating != .easy
            }.map(\.id))
            ordered = LearningSelection.distantMemories(state: state, limit: learned.count).filter { ids.contains($0.id) }
        case .distant:
            ordered = LearningSelection.distantMemories(state: state, limit: learned.count)
        case .unit:
            ordered = VocabularyUnit.grouped(learned).first { $0.id == unitID }?.words ?? []
        }
        return ordered
    }
}

/// The only remembered answers are temporary, single-round replay requests.
struct MedleyQueue {
    var tracks: [MedleyTrack]
    var index = 0
    var markedIDs: Set<String> = []
    var isReplay = false
    var isComplete: Bool { index >= tracks.count }
    mutating func mark() {
        guard !isComplete, !isReplay else { return }
        markedIDs.insert(tracks[index].word.id)
    }
    mutating func advance() {
        guard !isComplete else { return }
        index += 1
        if isComplete && !isReplay && !markedIDs.isEmpty {
            tracks = tracks.filter { markedIDs.contains($0.word.id) }
            index = 0; isReplay = true
        }
    }
}
