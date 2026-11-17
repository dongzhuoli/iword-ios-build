import Foundation
import AVFoundation
import Combine

/// Render Chinese once, then play files; playback never depends on live speech synthesis in the background.
@MainActor final class MedleySpeechRenderer {
    private var synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<URL, Error>?
    private var output: AVAudioFile?
    private var destination: URL?
    private var temporary: URL?
    private var token = UUID()
    private var watchdog: Task<Void, Never>?
    private var pcmContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var pcmWriter: Task<Void, Never>?
    private var legacyCacheInvalidated = false

    func render(_ meaning: String, voice: AVSpeechSynthesisVoice) async throws -> URL {
        guard continuation == nil else { throw ContentFailure(message: "中文声音仍在准备中。") }
        invalidateLegacyCacheIfNeeded()
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MedleyChinese-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hash = ContentInstaller.hash(Data((voice.identifier + "|0.42|" + meaning).utf8))
        let target = root.appendingPathComponent(hash + ".caf")
        if let file = try? AVAudioFile(forReading: target), file.length > 0 { return target }
        try Task.checkCancellation()
        let id = UUID(); token = id; destination = target
        temporary = root.appendingPathComponent(id.uuidString + ".caf")
        let utterance = AVSpeechUtterance(string: meaning)
        utterance.voice = voice; utterance.rate = 0.42
        // Keep a separate synthesizer per render so callbacks from a cancelled utterance cannot finish the next one.
        synthesizer = AVSpeechSynthesizer()
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            var callbackOutput: AsyncStream<AVAudioPCMBuffer>.Continuation?
            let stream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { output in
                callbackOutput = output
            }
            guard let pcmOutput = callbackOutput else {
                finish(.failure(ContentFailure(message: "无法建立中文语音输出流。")))
                return
            }
            pcmContinuation = pcmOutput
            pcmWriter = Task { @MainActor [weak self] in
                for await buffer in stream {
                    guard let self, self.token == id, self.continuation != nil else { break }
                    self.consumePCM(buffer)
                }
            }
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self, self.token == id else { return }
                self.finish(.failure(ContentFailure(message: "中文语音准备超时。请在手机设置中下载普通话声音后重试。")))
            }
            synthesizer.write(utterance) { buffer in
                // The synthesizer may emit non-PCM marker buffers.  Only a
                // zero-frame PCM buffer is the documented end marker; do not
                // mistake a marker for an unavailable voice.
                guard let pcm = buffer as? AVAudioPCMBuffer,
                      let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: max(1, pcm.frameLength)) else { return }
                copy.frameLength = pcm.frameLength
                let source = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for index in 0..<min(source.count, target.count) {
                    if let from = source[index].mData, let to = target[index].mData {
                        memcpy(to, from, Int(source[index].mDataByteSize))
                    }
                }
                // AsyncStream is a FIFO bridge from the synthesizer callback
                // queue to MainActor. The terminal zero-frame PCM buffer is
                // yielded after all real PCM buffers, never as an unrelated
                // Task that can overtake them.
                pcmOutput.yield(copy)
                if copy.frameLength == 0 { pcmOutput.finish() }
            }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; token = UUID(); watchdog?.cancel(); watchdog = nil
        pcmContinuation?.finish(); pcmContinuation = nil; pcmWriter?.cancel(); pcmWriter = nil
        synthesizer.stopSpeaking(at: .immediate); output = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil; destination = nil
        pending.resume(with: result)
    }

    private func invalidateLegacyCacheIfNeeded() {
        guard !legacyCacheInvalidated else { return }
        legacyCacheInvalidated = true
        guard let root = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("MedleyChinese-v1", isDirectory: true))
    }

    private func consumePCM(_ buffer: AVAudioPCMBuffer) {
        do {
            guard let temporary = temporary else { throw CancellationError() }
            if buffer.frameLength == 0 {
                output = nil
                let file = try AVAudioFile(forReading: temporary)
                guard file.length > 0, let destination else {
                    throw ContentFailure(message: "未能生成中文释义录音，请检查系统普通话声音。")
                }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                finish(.success(destination))
            } else {
                if output == nil {
                    output = try AVAudioFile(
                        forWriting: temporary,
                        settings: buffer.format.settings,
                        commonFormat: buffer.format.commonFormat,
                        interleaved: buffer.format.isInterleaved
                    )
                }
                try output?.write(from: buffer)
            }
        } catch {
            finish(.failure(error))
        }
    }
}

/// Produces one linear-PCM CAF for a whole word. This avoids depending on
/// mixed compressed/speech composition boundaries or empty media ranges when
/// the player crosses a long Chinese rendering. Rendering both sources and
/// both required silent intervals into one PCM stream gives AVQueuePlayer a
/// single, fully serialised item per word.
@MainActor final class MedleyAudioRenderer {
    private static let sampleRate = 44_100.0
    private static let postChineseSilence = 1.5
    private static let finalSilence = 1.5
    private static let cacheVersion = "medley-pcm-v2"
    private let fileManager = FileManager.default

    private struct Manifest: Codable {
        let sampleRate: Double
        let segments: [MedleyAudioSegment]
    }

    /// A rendered CAF is only useful for the active temporary queue.  Starting
    /// a new preparation happens after `player.end()`, so clearing this cache
    /// cannot remove an AVQueuePlayer item and prevents a large vocabulary from
    /// accumulating hundreds of mixed PCM files in Caches.
    func purgeRenderedCache() {
        guard let root = try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? fileManager.removeItem(at: root.appendingPathComponent("MedleyRendered-v2", isDirectory: true))
    }

    func render(englishURL: URL, chineseURL: URL, thinkingGap: Int) throws -> (url: URL, segments: [MedleyAudioSegment]) {
        try validateSource(englishURL)
        try validateSource(chineseURL)
        let root = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MedleyRendered-v2", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // ContentInstaller names downloaded audio by its hash; the generated
        // Chinese name includes the voice/rate/text.  Those names plus the
        // layout version make the cache safe across changed source audio.
        let key = ContentInstaller.hash(Data((Self.cacheVersion + "|" + englishURL.lastPathComponent + "|" + chineseURL.lastPathComponent + "|" + String(max(0, thinkingGap))).utf8))
        let outputURL = root.appendingPathComponent(key + ".caf")
        let manifestURL = root.appendingPathComponent(key + ".json")
        if let cached = loadCache(audioURL: outputURL, manifestURL: manifestURL) {
            return cached
        }

        let temporaryURL = root.appendingPathComponent(UUID().uuidString + ".caf")
        let temporaryManifestURL = root.appendingPathComponent(UUID().uuidString + ".json")
        defer {
            // Do not issue failing Objective-C cleanup calls while another
            // audio error is being bridged back through Swift/XCTest.
            for url in [temporaryURL, temporaryManifestURL] where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        var operation = "创建输出文件"

        do {
            let format = try outputFormat()
            var output: AVAudioFile? = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            var segments: [MedleyAudioSegment] = []
            var frameCursor: Int64 = 0

            do {
                guard let file = output else { throw ContentFailure(message: "无法创建串烧音频文件。") }
                operation = "读取英文录音"
                try appendAudio(englishURL, to: file, format: format, cursor: &frameCursor, stage: "英语", segments: &segments)
                try appendSilence(seconds: Double(max(0, thinkingGap)), to: file, format: format, cursor: &frameCursor, stage: "回想一下", segments: &segments)
                operation = "读取完整中文录音"
                try appendAudio(chineseURL, to: file, format: format, cursor: &frameCursor, stage: "中文释义", segments: &segments)
                try appendSilence(seconds: Self.postChineseSilence, to: file, format: format, cursor: &frameCursor, stage: "稍作停留", segments: &segments)
                try appendAudio(englishURL, to: file, format: format, cursor: &frameCursor, stage: "再听一次", segments: &segments)
                try appendSilence(seconds: Self.finalSilence, to: file, format: format, cursor: &frameCursor, stage: "下一词前停留", segments: &segments)
            }

            guard frameCursor > 0 else {
                throw ContentFailure(message: "未能生成串烧音频。")
            }
            // Release the writer before moving the CAF so the final container
            // metadata is visible to the subsequently queued AVPlayerItem.
            output = nil
            operation = "校验输出音频"
            let renderedFile = try AVAudioFile(forReading: temporaryURL)
            guard renderedFile.length == frameCursor else {
                throw ContentFailure(message: "串烧音频写入不完整，请重新开始。")
            }
            operation = "保存音频时间线"
            let manifest = Manifest(sampleRate: Self.sampleRate, segments: segments)
            try JSONEncoder().encode(manifest).write(to: temporaryManifestURL, options: .atomic)
            if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
            if fileManager.fileExists(atPath: manifestURL.path) { try fileManager.removeItem(at: manifestURL) }
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
            try fileManager.moveItem(at: temporaryManifestURL, to: manifestURL)
            return (outputURL, segments)
        } catch {
            throw ContentFailure(message: "无法合成串烧音频（\(operation)）：\(error.localizedDescription)")
        }
    }

    private func outputFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            throw ContentFailure(message: "设备不支持串烧所需的 PCM 音频格式。")
        }
        return format
    }

    private func loadCache(audioURL: URL, manifestURL: URL) -> (url: URL, segments: [MedleyAudioSegment])? {
        guard fileManager.fileExists(atPath: audioURL.path), fileManager.fileExists(atPath: manifestURL.path),
              let audio = try? AVAudioFile(forReading: audioURL), audio.length > 0,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.sampleRate == Self.sampleRate,
              !manifest.segments.isEmpty else { return nil }
        let totalFrames = manifest.segments.reduce(Int64(0)) { max($0, $1.startFrame + $1.frameCount) }
        guard totalFrames == audio.length else { return nil }
        return (audioURL, manifest.segments)
    }

    private func validateSource(_ url: URL) throws {
        guard url.isFileURL, fileManager.fileExists(atPath: url.path) else {
            throw ContentFailure(message: "离线音频文件不存在，请重新下载词库后再试。")
        }
    }

    private func appendAudio(
        _ sourceURL: URL,
        to output: AVAudioFile,
        format: AVAudioFormat,
        cursor: inout Int64,
        stage: String,
        segments: inout [MedleyAudioSegment]
    ) throws {
        let input = try AVAudioFile(forReading: sourceURL)
        guard input.length > 0, let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw ContentFailure(message: "离线音频格式无效，请重新下载词库后再试。")
        }
        let start = cursor
        let inputCapacity: AVAudioFrameCount = 4_096
        let outputCapacity: AVAudioFrameCount = 16_384
        var sourceEnded = false
        var sourceReadError: Error?
        var attemptsWithoutFrames = 0

        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
                throw ContentFailure(message: "无法分配串烧音频缓冲区。")
            }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { requestedFrames, status in
                // AVAudioFile may throw a generic Objective-C error when read
                // at EOF. Signal EOS before asking it to read another buffer.
                let remaining = max(Int64(0), input.length - input.framePosition)
                if sourceEnded || remaining == 0 {
                    status.pointee = .endOfStream
                    return nil
                }
                let requested = min(inputCapacity, max(1, requestedFrames), AVAudioFrameCount(min(remaining, Int64(inputCapacity))))
                guard let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: requested) else {
                    status.pointee = .noDataNow
                    return nil
                }
                do {
                    try input.read(into: source, frameCount: requested)
                    if source.frameLength == 0 {
                        sourceEnded = true
                        status.pointee = .endOfStream
                        return nil
                    }
                    status.pointee = .haveData
                    return source
                } catch {
                    sourceReadError = error
                    status.pointee = .noDataNow
                    return nil
                }
            }
            if let sourceReadError { throw sourceReadError }
            if status == .error {
                throw conversionError ?? ContentFailure(message: "串烧音频格式转换失败。") as NSError
            }
            if converted.frameLength > 0 {
                try output.write(from: converted)
                cursor += Int64(converted.frameLength)
                attemptsWithoutFrames = 0
            } else {
                attemptsWithoutFrames += 1
            }
            if status == .endOfStream { break }
            if attemptsWithoutFrames > 2 {
                throw ContentFailure(message: "离线音频无法转换为串烧格式。")
            }
        }
        guard cursor > start else {
            throw ContentFailure(message: "离线音频没有可播放的内容。")
        }
        segments.append(MedleyAudioSegment(startFrame: start, frameCount: cursor - start, stage: stage))
    }

    private func appendSilence(
        seconds: Double,
        to output: AVAudioFile,
        format: AVAudioFormat,
        cursor: inout Int64,
        stage: String,
        segments: inout [MedleyAudioSegment]
    ) throws {
        let frameCount = Int64((seconds * Self.sampleRate).rounded())
        guard frameCount > 0 else { return }
        let start = cursor
        var remaining = frameCount
        while remaining > 0 {
            let next = AVAudioFrameCount(min(remaining, 16_384))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: next) else {
                throw ContentFailure(message: "无法分配静音音频缓冲区。")
            }
            silence.frameLength = next
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for buffer in buffers {
                if let data = buffer.mData, buffer.mDataByteSize > 0 {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            try output.write(from: silence)
            remaining -= Int64(next)
            cursor += Int64(next)
        }
        segments.append(MedleyAudioSegment(startFrame: start, frameCount: frameCount, stage: stage))
    }
}

@MainActor final class MedleyController: ObservableObject {
    let player = MedleyPlayer()
    @Published private(set) var preparing = false
    @Published private(set) var prepared = 0
    @Published private(set) var total = 0
    @Published var error: String?
    private let renderer = MedleySpeechRenderer()
    private let audioRenderer = MedleyAudioRenderer()
    private var preparation: Task<Void, Never>?
    private var generation = UUID()

    func prepare(words: [MobileWord], title: String, gap: Int) {
        cancelPreparation(); error = nil
        guard !words.isEmpty else { error = "没有符合规则且已下载录音的已学词。可以更换规则，或先更新词库录音。"; return }
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            error = "手机上没有可用普通话声音，请先在系统设置中下载中文声音。"; return
        }
        player.end()
        audioRenderer.purgeRenderedCache()
        preparing = true; prepared = 0; total = words.count
        let id = UUID(); generation = id
        preparation = Task {
            do {
                var tracks: [MedleyTrack] = []
                for word in words {
                    try Task.checkCancellation()
                    guard let hash = word.audioHash else { throw ContentFailure(message: "单词缺少原书录音。") }
                    let english = try ContentInstaller.audioURL(hash)
                    let chinese = try await renderer.render(word.meaning, voice: voice)
                    try Task.checkCancellation()
                    guard generation == id else { return }
                    let rendered = try audioRenderer.render(englishURL: english, chineseURL: chinese, thinkingGap: gap)
                    try Task.checkCancellation()
                    guard generation == id else { return }
                    tracks.append(MedleyTrack(
                        word: word,
                        englishURL: english,
                        chineseURL: chinese,
                        playbackURL: rendered.url,
                        segments: rendered.segments
                    ))
                    prepared += 1
                }
                guard generation == id else { return }
                preparing = false; preparation = nil
                player.start(tracks: tracks, title: title, gap: gap)
            } catch {
                guard generation == id else { return }
                preparing = false; preparation = nil
                if !(error is CancellationError) { self.error = "串烧未启动：" + error.localizedDescription }
            }
        }
    }
    func cancelPreparation() {
        generation = UUID(); preparation?.cancel(); preparation = nil; renderer.cancel(); preparing = false
    }
    func backgrounded() {
        // Preparation needs foreground execution; a completed player is independent and keeps playing.
        if preparing {
            cancelPreparation()
            error = "中文声音准备已暂停，请回到串烧设置重新开始。已生成的声音会保留，不需要重复准备。"
        }
    }
    func yieldAudio() { cancelPreparation(); player.yieldAudio() }
    func end() { cancelPreparation(); player.end() }
}
