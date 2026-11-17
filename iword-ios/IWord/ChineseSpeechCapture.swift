import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

@MainActor
final class ChineseSpeechCapture: NSObject, ObservableObject {
    @Published var status = ""
    @Published var recording = false
    @Published var processing = false
    @Published var transcript = ""

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdogTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var sessionActivated = false

    private var nextAttempt = 0
    private var activeAttempt: Int?
    private var inputStarted = false
    private var microphonePermission: Bool?
    private var speechPermission: Bool?
    private var finalTextWhileRecording: String?
    private var onResult: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        super.init()
        addAudioObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(onResult: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        cancelCurrentAttempt(clearStatus: false)

        nextAttempt += 1
        let attempt = nextAttempt
        activeAttempt = attempt
        self.onResult = onResult
        self.onFailure = onFailure
        status = ""
        transcript = ""
        recording = false
        processing = true
        inputStarted = false
        finalTextWhileRecording = nil

        microphonePermission = nil
        speechPermission = nil
        requestPermissions(for: attempt)
    }

    func finish() {
        guard let attempt = activeAttempt else { return }

        // Releasing the hold while permissions are pending invalidates the attempt;
        // permission callbacks must not start a later recording.
        guard recording else {
            guard inputStarted else {
                cancelCurrentAttempt(clearStatus: false)
                status = "请再次按住以开始录音。"
                return
            }
            return
        }

        recording = false
        processing = true
        watchdogTask?.cancel()
        watchdogTask = nil

        recognitionRequest?.endAudio()
        stopAudioInput()

        if let finalTextWhileRecording {
            if finalTextWhileRecording.isEmpty {
                failCurrent(attempt: attempt, status: "未识别到语音，请重试。")
            } else {
                succeedCurrent(attempt: attempt, text: finalTextWhileRecording)
            }
            return
        }

        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recognitionTimedOut(attempt: attempt)
        }
    }

    func cancel() {
        cancelCurrentAttempt(clearStatus: true)
    }

    private func requestPermissions(for attempt: Int) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            microphonePermission = true
        case .denied:
            microphonePermission = false
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.permissionResolved(attempt: attempt, microphone: granted)
                }
            }
        @unknown default:
            microphonePermission = false
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechPermission = true
        case .denied, .restricted:
            speechPermission = false
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                Task { @MainActor [weak self] in
                    self?.permissionResolved(
                        attempt: attempt,
                        speech: authorization == .authorized
                    )
                }
            }
        @unknown default:
            speechPermission = false
        }

        continueAfterPermissions(for: attempt)
    }

    private func permissionResolved(attempt: Int, microphone granted: Bool) {
        guard activeAttempt == attempt else { return }
        microphonePermission = granted
        continueAfterPermissions(for: attempt)
    }

    private func permissionResolved(attempt: Int, speech granted: Bool) {
        guard activeAttempt == attempt else { return }
        speechPermission = granted
        continueAfterPermissions(for: attempt)
    }

    private func continueAfterPermissions(for attempt: Int) {
        guard activeAttempt == attempt,
              let microphonePermission,
              let speechPermission else { return }

        guard microphonePermission && speechPermission else {
            failCurrent(
                attempt: attempt,
                status: "请在系统设置中允许麦克风和语音识别权限后重试。"
            )
            return
        }

        startRecognition(for: attempt)
    }

    private func startRecognition(for attempt: Int) {
        guard activeAttempt == attempt, !recording, !inputStarted else { return }
        guard let recognizer else {
            failCurrent(attempt: attempt, status: offlineUnavailableMessage)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            failCurrent(attempt: attempt, status: offlineUnavailableMessage)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            if let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(microphone)
            }
            try session.setActive(true)
            sessionActivated = true

            // Creating the input node while the session is still in playback mode
            // can freeze a zero-channel format on older iPhones.
            let engine = AVAudioEngine()
            audioEngine = engine
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite,
                  format.sampleRate > 0,
                  format.channelCount > 0 else {
                failCurrent(attempt: attempt, status: "未取得有效麦克风输入，请断开蓝牙耳机后重试。")
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                // The buffer is handed directly to Speech and is not retained.
                request.append(buffer)
            }
            tapInstalled = true

            recognitionRequest = request
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString ?? ""
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil
                Task { @MainActor [weak self] in
                    self?.recognitionUpdated(
                        attempt: attempt,
                        text: text,
                        isFinal: isFinal,
                        hasError: hasError
                    )
                }
            }

            engine.prepare()
            try engine.start()
            inputStarted = true
            recording = true
            processing = false
            status = ""
            watchdogTask?.cancel()
            watchdogTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self, self.activeAttempt == attempt, self.recording else { return }
                self.finish()
            }
        } catch {
            failCurrent(attempt: attempt, status: "录音未能开始，请重试。")
        }
    }

    private func recognitionUpdated(
        attempt: Int,
        text: String,
        isFinal: Bool,
        hasError: Bool
    ) {
        guard activeAttempt == attempt else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            transcript = trimmed
        }

        if hasError {
            failCurrent(attempt: attempt, status: "离线中文语音识别失败，请重试。")
        } else if isFinal {
            if recording {
                finalTextWhileRecording = trimmed
            } else {
                guard !trimmed.isEmpty else {
                    failCurrent(attempt: attempt, status: "未识别到语音，请重试。")
                    return
                }
                succeedCurrent(attempt: attempt, text: trimmed)
            }
        }
    }

    private func recognitionTimedOut(attempt: Int) {
        guard activeAttempt == attempt, processing else { return }
        failCurrent(attempt: attempt, status: "语音识别超时，请重试。")
    }

    private func succeedCurrent(attempt: Int, text: String) {
        guard activeAttempt == attempt else { return }
        let callback = onResult
        invalidateResolvedAttempt()
        transcript = text
        status = ""
        callback?(text)
    }

    private func failCurrent(attempt: Int, status: String) {
        guard activeAttempt == attempt else { return }
        let callback = onFailure
        invalidateResolvedAttempt()
        transcript = ""
        self.status = status
        callback?(status)
    }

    private func invalidateResolvedAttempt() {
        activeAttempt = nil
        onResult = nil
        onFailure = nil
        recording = false
        processing = false
        inputStarted = false
        finalTextWhileRecording = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        stopAndReleaseAudio()
    }

    private func cancelCurrentAttempt(clearStatus: Bool) {
        guard activeAttempt != nil || recording || processing else {
            if clearStatus {
                transcript = ""
                status = ""
            }
            return
        }

        nextAttempt += 1
        activeAttempt = nil
        onResult = nil
        onFailure = nil
        recording = false
        processing = false
        inputStarted = false
        finalTextWhileRecording = nil
        transcript = ""
        if clearStatus {
            status = ""
        }
        watchdogTask?.cancel()
        watchdogTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        stopAndReleaseAudio()
    }

    private func stopAudioInput() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
        }
        audioEngine = nil
        if sessionActivated {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            sessionActivated = false
        }
    }

    private func stopAndReleaseAudio() {
        stopAudioInput()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func addAudioObservers() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, Bool)] = [
            (AVAudioSession.interruptionNotification, true),
            (AVAudioSession.routeChangeNotification, true),
            (UIApplication.didEnterBackgroundNotification, false)
        ]
        for (name, interruptionMayBeRelevant) in names {
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                let shouldStop: Bool
                if name == UIApplication.didEnterBackgroundNotification {
                    shouldStop = true
                } else if name == AVAudioSession.interruptionNotification {
                    shouldStop = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        == AVAudioSession.InterruptionType.began.rawValue
                } else if name == AVAudioSession.routeChangeNotification {
                    shouldStop = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                        == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                } else {
                    shouldStop = interruptionMayBeRelevant
                }
                guard shouldStop else { return }
                Task { @MainActor [weak self] in
                    self?.audioEnvironmentStopped()
                }
            }
            observers.append(observer)
        }
    }

    private func audioEnvironmentStopped() {
        guard let attempt = activeAttempt else {
            stopAndReleaseAudio()
            return
        }
        failCurrent(attempt: attempt, status: "录音已中断，请重试。")
    }

    private var offlineUnavailableMessage: String {
        "此设备当前无法使用离线中文识别，请使用提示或手动揭晓；不会自动联网识别。"
    }

}
