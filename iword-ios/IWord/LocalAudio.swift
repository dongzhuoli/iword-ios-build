import Foundation
import AVFoundation

@MainActor final class LocalAudio: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published var notice: String?
    var onWillPlay: (() -> Void)?
    var onEvent: ((String, [String: String]) -> Void)?
    private var player: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()
    private var second = false
    private var generation = 0
    private var wordID = ""
    private var currentRate: Float = 1
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init(); speech.delegate = self
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let interruption = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let unplugged = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if (notification.name == AVAudioSession.interruptionNotification && interruption) || (notification.name == AVAudioSession.routeChangeNotification && unplugged) {
                    Task { @MainActor in self?.stop() }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func stop(deactivateSession: Bool = true) {
        generation += 1; second = false; player?.stop(); player = nil
        speech.stopSpeaking(at: .immediate)
        if deactivateSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func play(_ word: MobileWord, twice: Bool) {
        onWillPlay?()
        stop(); notice = nil; wordID = word.id
        do {
            guard let hash = word.audioHash else { notice = "本词暂无原书录音，可在词库更新后再试。"; onEvent?("AUDIO_MISSING", ["wordID": word.id]); return }
            let url = try ContentInstaller.audioURL(hash)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = self; audio.enableRate = true; audio.rate = twice ? 0.7 : 1.0
            audio.prepareToPlay(); player = audio; second = twice; currentRate = audio.rate
            onEvent?("AUDIO_REQUEST", ["wordID": word.id, "hash": hash, "rate": String(audio.rate)])
            guard audio.play() else { throw ContentFailure(message: "录音未能开始播放，请重试。") }
            onEvent?("AUDIO_STARTED", ["wordID": word.id, "rate": String(audio.rate)])
        } catch { stop(); notice = "播放失败：\(error.localizedDescription)"; onEvent?("AUDIO_FAILED", ["wordID": word.id, "reason": error.localizedDescription]) }
    }
    func sentence(_ word: MobileWord, example selectedExample: WordExample? = nil) {
        onWillPlay?()
        stop(); notice = nil
        guard let example = selectedExample ?? word.example else { return }
        guard let voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US") else { notice = "系统英语声音不可用，请在手机设置中下载英语声音。"; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: example.text)
        utterance.voice = voice; utterance.rate = 0.38; utterance.preUtteranceDelay = 0.1
        wordID = word.id; onEvent?("SENTENCE_REQUEST", ["wordID": word.id, "voice": voice.identifier])
        speech.speak(utterance)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, player === self.player else { return }
            self.onEvent?(flag ? "AUDIO_COMPLETED" : "AUDIO_FAILED", ["wordID": self.wordID, "rate": String(self.currentRate)])
            guard flag else { self.stop(); self.notice = "录音未完整播放，请重试。"; return }
            if self.second {
                self.second = false; let token = self.generation
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard token == self.generation, player === self.player else { return }
                player.currentTime = 0; player.rate = 1.0; self.currentRate = 1.0
                if player.play() { self.onEvent?("AUDIO_STARTED", ["wordID": self.wordID, "rate": "1.0"]) }
                else { self.notice = "第二遍未启动，请点小喇叭重听。" }
            } else { self.player = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.onEvent?("SENTENCE_COMPLETED", ["wordID": self?.wordID ?? ""]) }
    }
}
