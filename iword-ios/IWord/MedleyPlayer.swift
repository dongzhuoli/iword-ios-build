import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Plays a temporary, offline listening queue without changing learning state.
/// Each item is a pre-rendered PCM CAF, so background playback never depends
/// on a timer or an in-memory composition to start the next segment.
@MainActor
final class MedleyPlayer: NSObject, ObservableObject {
    @Published private(set) var tracks: [MedleyTrack] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isActive = false
    @Published private(set) var isFinished = false
    @Published private(set) var error: String?
    @Published private(set) var showPlayer = false
    @Published private(set) var stage = "准备播放"
    @Published private(set) var remaining = 0
    @Published private(set) var isReplay = false
    @Published private(set) var markedCount = 0

    private(set) var title = ""
    var onWillPlay: (() -> Void)?

    var current: MobileWord? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index].word
    }

    /// Explicit name for views that should not depend on a computed-property
    /// convention when their body is refreshed by the published queue state.
    var currentComputed: MobileWord? { current }

    private struct Segment {
        let range: CMTimeRange
        let stage: String
    }

    private struct ItemTimeline {
        let queueIndex: Int
        let duration: CMTime
        let segments: [Segment]
    }

    private var queue = MedleyQueue(tracks: [])
    private var player: AVQueuePlayer?
    private var periodicObserver: Any?
    private var currentItemObserver: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var timelines: [ObjectIdentifier: ItemTimeline] = [:]
    private var itemRunTokens: [ObjectIdentifier: Int] = [:]
    private var runToken = 0
    private var ownsAudioSession = false
    private var ownsNowPlaying = false

    deinit {
        if let player, let periodicObserver { player.removeTimeObserver(periodicObserver) }
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        if let itemFailedObserver { NotificationCenter.default.removeObserver(itemFailedObserver) }
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func start(tracks: [MedleyTrack], title: String, gap _: Int) {
        stopInfrastructure(deactivateSession: ownsAudioSession)
        self.title = title
        queue = MedleyQueue(tracks: tracks)
        synchronizeQueueState()
        isFinished = false
        error = nil
        showPlayer = !tracks.isEmpty
        isActive = !tracks.isEmpty
        stage = "准备播放"
        remaining = 0

        guard !tracks.isEmpty else {
            fail(ContentFailure(message: "没有可播放的词条。"))
            return
        }
        installSessionObservers()
        installRemoteCommands()
        do {
            try configureAudioSession()
            try makePlayer(startingAt: queue.index)
            playCurrentQueue()
        } catch {
            fail(error)
        }
    }

    func pause() {
        guard isActive, let player else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying(elapsed: player.currentTime().seconds)
        deactivateOwnedSession()
    }

    /// Gives regular word audio sole ownership of lock-screen controls and
    /// metadata.  Unlike an ordinary pause, this removes the medley's remote
    /// command targets so its periodic observer cannot compete with another
    /// active audio feature.
    func yieldAudio() {
        guard isActive else { return }
        if let player {
            player.pause()
            isPlaying = false
        }
        isPlaying = false
        deactivateOwnedSession()
        relinquishNowPlaying()
        removeRemoteCommands()
    }

    func resume() {
        guard isActive, !queue.isComplete else { return }
        error = nil
        do {
            try configureAudioSession()
            if player == nil { try makePlayer(startingAt: queue.index) }
            playCurrentQueue()
        } catch {
            fail(error)
        }
    }

    func next() {
        guard isActive, !queue.isComplete else { return }
        let wasPlaying = isPlaying
        queue.advance()
        synchronizeQueueState()
        guard !queue.isComplete else { finish(); return }
        do {
            try makePlayer(startingAt: queue.index)
            if wasPlaying { playCurrentQueue() }
            else { updateNowPlaying(elapsed: 0) }
        } catch {
            fail(error)
        }
    }

    func markForgotten() {
        guard isActive, !queue.isComplete, !queue.isReplay else { return }
        queue.mark()
        synchronizeQueueState()
        updateNowPlaying(elapsed: player?.currentTime().seconds ?? 0)
    }

    /// Ends only this temporary player.  No learning data or journal is ever written.
    func end() {
        let ownedSession = ownsAudioSession
        stopInfrastructure(deactivateSession: ownedSession)
        isActive = false
        isPlaying = false
        isFinished = false
        showPlayer = false
        error = nil
        stage = "已结束"
        remaining = 0
        queue = MedleyQueue(tracks: [])
        synchronizeQueueState()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        ownsAudioSession = true
    }

    /// Replaces items from the current planning position.  A new run token
    /// makes delayed notifications or KVO callbacks from an old player harmless.
    private func makePlayer(startingAt startIndex: Int) throws {
        tearDownPlayer()
        guard queue.tracks.indices.contains(startIndex) else {
            throw ContentFailure(message: "播放队列已结束。")
        }
        runToken += 1
        let token = runToken
        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .advance
        var newTimelines: [ObjectIdentifier: ItemTimeline] = [:]
        var newTokens: [ObjectIdentifier: Int] = [:]

        for queueIndex in startIndex..<queue.tracks.count {
            let (item, timeline) = try makeItem(for: queue.tracks[queueIndex], queueIndex: queueIndex)
            let identifier = ObjectIdentifier(item)
            newTimelines[identifier] = timeline
            newTokens[identifier] = token
            queuePlayer.insert(item, after: nil)
        }
        guard !queuePlayer.items().isEmpty else {
            throw ContentFailure(message: "没有可播放的音频项目。")
        }
        player = queuePlayer
        timelines = newTimelines
        itemRunTokens = newTokens
        installItemEndObserver()
        installCurrentItemObserver(on: queuePlayer)
        installPeriodicObserver(on: queuePlayer)
        stage = "英语"
        remaining = 0
        updateNowPlaying(elapsed: 0)
    }

    /// Playback accepts only the pre-rendered file. This removes dependence on
    /// mixed compressed/speech composition boundaries and empty media ranges,
    /// which are plausible contributors to the reported device overlap.
    private func makeItem(for track: MedleyTrack, queueIndex: Int) throws -> (AVPlayerItem, ItemTimeline) {
        guard let url = track.playbackURL, url.isFileURL,
              FileManager.default.fileExists(atPath: url.path), !track.segments.isEmpty else {
            throw ContentFailure(message: "串烧音频尚未准备完成，请重新开始。")
        }
        let audio = try AVAudioFile(forReading: url)
        let rate = Int32(audio.processingFormat.sampleRate.rounded())
        guard rate > 0, audio.length > 0 else {
            throw ContentFailure(message: "串烧音频时长无效，请重新开始。")
        }
        let segments = track.segments.compactMap { segment -> Segment? in
            guard segment.startFrame >= 0, segment.frameCount > 0,
                  segment.startFrame + segment.frameCount <= audio.length else { return nil }
            return Segment(
                range: CMTimeRange(
                    start: CMTime(value: CMTimeValue(segment.startFrame), timescale: rate),
                    duration: CMTime(value: CMTimeValue(segment.frameCount), timescale: rate)
                ),
                stage: segment.stage
            )
        }
        guard segments.count == track.segments.count else {
            throw ContentFailure(message: "串烧音频时间线无效，请重新开始。")
        }
        return (
            AVPlayerItem(url: url),
            ItemTimeline(
                queueIndex: queueIndex,
                duration: CMTime(value: CMTimeValue(audio.length), timescale: rate),
                segments: segments
            )
        )
    }

    private func playCurrentQueue() {
        guard let player else { return }
        onWillPlay?()
        installRemoteCommands()
        ownsNowPlaying = true
        player.play()
        isPlaying = true
        updateNowPlaying(elapsed: player.currentTime().seconds)
    }

    private func installPeriodicObserver(on player: AVQueuePlayer) {
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, player === self.player else { return }
                self.updateProgress(at: time)
            }
        }
    }

    /// Queue advancement is driven by AVQueuePlayer itself. KVO identifies the
    /// selected prequeued item immediately; the end notification is only
    /// needed for the terminal/replay boundary. Either callback may arrive
    /// first, and both reduce to the same monotonic queue state.
    private func installCurrentItemObserver(on player: AVQueuePlayer) {
        currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self, weak player] _, change in
            guard let item = change.newValue ?? player?.currentItem else { return }
            Task { @MainActor [weak self] in self?.didSelect(item: item) }
        }
    }

    private func installItemEndObserver() {
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in self?.didFinish(item: item) }
        }
        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in self?.didFail(item: item, notification: notification) }
        }
    }

    private func didFinish(item: AVPlayerItem) {
        let identifier = ObjectIdentifier(item)
        guard itemRunTokens[identifier] == runToken,
              let timeline = timelines[identifier],
              timeline.queueIndex == queue.index,
              isActive else { return }

        let wasFinalQueuedItem = timeline.queueIndex + 1 == queue.tracks.count
        queue.advance()
        synchronizeQueueState()
        if queue.isComplete {
            finish()
            return
        }

        // Original items were preloaded.  The forgotten-only replay list does
        // not exist until the original list completes, so queue it at exactly
        // this boundary; no timer is involved in the transition.
        if wasFinalQueuedItem {
            do {
                // A pause/yield may arrive after the media finished but before its notification.
                // Keep that explicit pause when entering the temporary replay round.
                let shouldContinue = isPlaying
                try makePlayer(startingAt: queue.index)
                if shouldContinue { playCurrentQueue() }
            } catch {
                fail(error)
            }
        } else {
            stage = "英语"
            remaining = 0
            updateNowPlaying(elapsed: 0)
        }
    }

    private func didSelect(item: AVPlayerItem) {
        let identifier = ObjectIdentifier(item)
        guard itemRunTokens[identifier] == runToken,
              let timeline = timelines[identifier],
              isActive,
              timeline.queueIndex >= queue.index else { return }
        while queue.index < timeline.queueIndex {
            queue.advance()
        }
        synchronizeQueueState()
        stage = "英语"
        remaining = 0
        updateNowPlaying(elapsed: 0, duration: timeline.duration.seconds)
    }

    private func didFail(item: AVPlayerItem, notification: Notification) {
        let identifier = ObjectIdentifier(item)
        guard itemRunTokens[identifier] == runToken,
              let timeline = timelines[identifier],
              isActive else { return }
        let underlying = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            ?? item.error
            ?? ContentFailure(message: "音频未能完整播放。")
        let word = queue.tracks.indices.contains(timeline.queueIndex) ? queue.tracks[timeline.queueIndex].word.word : "未知词条"
        fail(ContentFailure(message: "第 \(timeline.queueIndex + 1) 词“\(word)”未能完整播放：\(underlying.localizedDescription)"))
    }

    private func updateProgress(at time: CMTime) {
        guard let item = player?.currentItem,
              let timeline = timelines[ObjectIdentifier(item)],
              timeline.queueIndex == queue.index else { return }
        let elapsed = max(0, time.seconds)
        let segment = timeline.segments.first(where: { CMTimeRangeContainsTime($0.range, time: time) }) ?? timeline.segments.last
        stage = segment?.stage ?? "播放中"
        let until = (segment?.range.end.seconds ?? timeline.duration.seconds) - elapsed
        remaining = max(0, Int(ceil(until)))
        updateNowPlaying(elapsed: elapsed, duration: timeline.duration.seconds)
    }

    private func synchronizeQueueState() {
        tracks = queue.tracks
        index = queue.index
        isReplay = queue.isReplay
        markedCount = queue.markedIDs.count
    }

    private func updateNowPlaying(elapsed: Double, duration: Double? = nil) {
        guard ownsNowPlaying, isActive, let word = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: word.word,
            MPMediaItemPropertyArtist: "\(title) · 第 \(index + 1)/\(tracks.count) 词",
            MPMediaItemPropertyAlbumTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0
        ]
        if let duration, duration.isFinite { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installSessionObservers() {
        guard sessionObservers.isEmpty else { return }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            sessionObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let interrupted = notification.name == AVAudioSession.interruptionNotification
                    && (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let unplugged = notification.name == AVAudioSession.routeChangeNotification
                    && (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if interrupted || unplugged {
                    Task { @MainActor [weak self] in self?.pause() }
                }
            })
        }
    }

    private func installRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        addRemoteTarget(center.playCommand) { $0.resume() }
        addRemoteTarget(center.pauseCommand) { $0.pause() }
        addRemoteTarget(center.togglePlayPauseCommand) { player in
            player.isPlaying ? player.pause() : player.resume()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.next() }
        addRemoteTarget(center.stopCommand) { $0.end() }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (MedleyPlayer) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func removeRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
    }

    private func removeSessionObservers() {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers.removeAll()
    }

    private func tearDownPlayer() {
        runToken += 1
        if let player, let periodicObserver { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        itemEndObserver = nil
        if let itemFailedObserver { NotificationCenter.default.removeObserver(itemFailedObserver) }
        itemFailedObserver = nil
        timelines.removeAll()
        itemRunTokens.removeAll()
    }

    private func stopInfrastructure(deactivateSession: Bool) {
        tearDownPlayer()
        removeSessionObservers()
        removeRemoteCommands()
        relinquishNowPlaying()
        if deactivateSession { deactivateOwnedSession() }
    }

    private func finish() {
        stopInfrastructure(deactivateSession: ownsAudioSession)
        isPlaying = false
        isActive = false
        isFinished = true
        showPlayer = false
        stage = "已完成"
        remaining = 0
    }

    private func fail(_ underlyingError: Error) {
        tearDownPlayer()
        error = "播放失败：\(underlyingError.localizedDescription)"
        isPlaying = false
        stage = "播放失败"
        remaining = 0
        relinquishNowPlaying()
        deactivateOwnedSession()
    }

    private func relinquishNowPlaying() {
        guard ownsNowPlaying else { return }
        ownsNowPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func deactivateOwnedSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
