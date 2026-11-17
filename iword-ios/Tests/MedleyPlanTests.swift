import XCTest
import AVFoundation
import IWordDomain
@testable import IWord

final class MedleyPlanTests: XCTestCase {
    func testRulesReadLearningStateWithoutMutatingItAndOnlyUseDownloadedAudio() throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "sample", withExtension: "zip"))
        let (_, words) = try ContentInstaller.install(fixture)
        var state = LocalState(); state.words = words
        let now = Date()
        for (index, word) in words.enumerated() {
            state.progress[word.id] = WordProgress(id: word.id, learned: true, latestRating: index == 0 ? .forgot : .easy,
                lastStudiedAt: now.addingTimeInterval(-Double(index) * 3600))
        }
        let before = try JSONEncoder().encode(state.progress)
        let profile = state.profile
        let distant = MedleyPlan.words(state: state, rule: .distant, unitID: nil, limit: 20)
        XCTAssertEqual(distant.map(\.id), words.reversed().map(\.id))
        XCTAssertEqual(MedleyPlan.words(state: state, rule: .weak, unitID: nil, limit: 20).map(\.id), [words[0].id])
        let unit = try XCTUnwrap(VocabularyUnit.grouped(words).first)
        XCTAssertEqual(MedleyPlan.words(state: state, rule: .unit, unitID: unit.id, limit: 2).map(\.id), unit.words.prefix(2).map(\.id))
        XCTAssertTrue(MedleyPlan.words(state: state, rule: .unit, unitID: "missing", limit: 20).isEmpty)
        XCTAssertTrue(MedleyPlan.words(state: state, rule: .distant, unitID: nil, limit: 0).isEmpty)
        XCTAssertEqual(state.profile, profile)
        XCTAssertEqual(try JSONDecoder().decode([String: WordProgress].self, from: before), state.progress)
        state.words[4].audioHash = nil
        state.words[3].inactive = true
        state.progress[words[2].id]?.learned = false
        XCTAssertEqual(Set(MedleyPlan.words(state: state, rule: .distant, unitID: nil, limit: 20).map(\.id)), Set(words.prefix(2).map(\.id)))
    }

    func testWeakListeningIncludesUnratedLearnedWordsAndKeepsStableWordsOut() throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "sample", withExtension: "zip"))
        let (_, words) = try ContentInstaller.install(fixture)
        var state = LocalState(); state.words = Array(words.prefix(3))
        state.progress[words[0].id] = WordProgress(id: words[0].id, learned: true, lastStudiedAt: Date(timeIntervalSince1970: 1))
        state.progress[words[1].id] = WordProgress(id: words[1].id, learned: true, latestRating: .easy)
        state.progress[words[2].id] = WordProgress(id: words[2].id, learned: false)
        XCTAssertEqual(MedleyPlan.words(state: state, rule: .weak, unitID: nil, limit: 20).map(\.id), [words[0].id])
        XCTAssertNil(MedleyPlan.unavailableReason(state: state, rule: .weak, unitID: nil))
        state.progress[words[0].id]?.latestRating = .easy
        XCTAssertTrue(MedleyPlan.words(state: state, rule: .weak, unitID: nil, limit: 20).isEmpty)
        XCTAssertTrue(MedleyPlan.unavailableReason(state: state, rule: .weak, unitID: nil)?.contains("没有需要巩固的薄弱词") == true)
        XCTAssertFalse(MedleyPlan.words(state: state, rule: .distant, unitID: nil, limit: 20).isEmpty)
    }

    func testEmptyListeningReasonsDistinguishNoLearningMissingUnitAndMissingAudio() throws {
        var state = LocalState()
        XCTAssertTrue(MedleyPlan.unavailableReason(state: state, rule: .weak, unitID: nil)?.contains("还没有已学词") == true)
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "sample", withExtension: "zip"))
        let (_, words) = try ContentInstaller.install(fixture)
        var target = try XCTUnwrap(words.first)
        target.audioHash = nil
        state.words = [target]
        state.progress[target.id] = WordProgress(id: target.id, learned: true, latestRating: .forgot)
        XCTAssertTrue(MedleyPlan.unavailableReason(state: state, rule: .unit, unitID: "")?.contains("请先选择") == true)
        XCTAssertTrue(MedleyPlan.unavailableReason(state: state, rule: .weak, unitID: nil)?.contains("本地原书录音") == true)
        XCTAssertTrue(MedleyPlan.words(state: state, rule: .weak, unitID: nil, limit: 20).isEmpty)
        target.meaning = ""
        state.words = [target]
        XCTAssertTrue(MedleyPlan.unavailableReason(state: state, rule: .weak, unitID: nil)?.contains("暂缺中文释义") == true)
    }

    func testTemporaryMarksReplayOnlyOnceAndFollowOriginalOrder() throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "sample", withExtension: "zip"))
        let (_, words) = try ContentInstaller.install(fixture)
        let tracks = words.prefix(3).map { MedleyTrack(word: $0, englishURL: URL(fileURLWithPath: "/english.mp3"), chineseURL: URL(fileURLWithPath: "/chinese.caf")) }
        var queue = MedleyQueue(tracks: tracks)
        queue.mark(); queue.mark()
        queue.advance(); queue.advance(); queue.mark(); queue.advance()
        XCTAssertTrue(queue.isReplay); XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.tracks.map { $0.word.id }, [tracks[0].word.id, tracks[2].word.id])
        queue.mark(); queue.advance(); queue.mark(); queue.advance()
        XCTAssertTrue(queue.isComplete)
        queue.advance(); XCTAssertTrue(queue.isComplete)
        XCTAssertEqual(queue.markedIDs.count, 2)
    }

    func testUnmarkedRoundEndsWithoutLooping() throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "sample", withExtension: "zip"))
        let (_, words) = try ContentInstaller.install(fixture)
        let word = try XCTUnwrap(words.first)
        var queue = MedleyQueue(tracks: [MedleyTrack(word: word, englishURL: URL(fileURLWithPath: "/english.mp3"), chineseURL: URL(fileURLWithPath: "/chinese.caf"))])
        XCTAssertFalse(queue.isComplete)
        queue.advance()
        XCTAssertTrue(queue.isComplete)
        queue.mark(); queue.advance()
        XCTAssertFalse(queue.isReplay)
        XCTAssertTrue(queue.markedIDs.isEmpty)
        XCTAssertTrue(MedleyQueue(tracks: []).isComplete)
    }

    @MainActor
    func testRenderedPCMContainsLongChineseAndBothFixedOnePointFiveSecondGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let english = root.appendingPathComponent("english.wav")
        let chinese = root.appendingPathComponent("long-chinese.wav")
        try writeTestWAV(to: english, frameCount: 1_600)
        try writeTestWAV(to: chinese, frameCount: 64_000)

        let renderer = MedleyAudioRenderer()
        renderer.purgeRenderedCache()
        defer { renderer.purgeRenderedCache() }
        let rendered = try renderer.render(englishURL: english, chineseURL: chinese, thinkingGap: 0)
        let file = try AVAudioFile(forReading: rendered.url)
        XCTAssertEqual(rendered.segments.map(\.stage), ["英语", "中文释义", "稍作停留", "再听一次", "下一词前停留"])
        XCTAssertGreaterThan(rendered.segments[1].frameCount, rendered.segments[0].frameCount * 20)
        XCTAssertEqual(rendered.segments[2].frameCount, 66_150)
        XCTAssertEqual(rendered.segments[4].frameCount, 66_150)
        XCTAssertEqual(rendered.segments.last!.startFrame + rendered.segments.last!.frameCount, file.length)
        for pair in zip(rendered.segments, rendered.segments.dropFirst()) {
            XCTAssertEqual(pair.0.startFrame + pair.0.frameCount, pair.1.startFrame)
        }
    }

    private func writeTestWAV(to url: URL, frameCount: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        try file.write(from: buffer)
    }
}
