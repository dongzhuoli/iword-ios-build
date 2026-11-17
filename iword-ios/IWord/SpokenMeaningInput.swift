import SwiftUI

/// Hold-to-talk remains optional; revealing and self-rating still work without recognition.
struct SpokenMeaningInput: View {
    @EnvironmentObject var model: LearningModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var speech: ChineseSpeechCapture
    var step: StudyStep
    @State private var held = false
    @State private var flash = false

    private var occupied: Bool { speech.recording || speech.processing }
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: speech.recording ? "mic.fill" : "mic")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 50, height: 50)
                .foregroundColor(flash ? Color.red : Palette.blue)
                .background(flash ? Color.red.opacity(0.12) : Palette.pale).clipShape(Circle())
                .overlay(Circle().stroke(flash ? Color.red : Palette.line))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                    guard !held, !occupied, !model.busy else { return }
                    held = true; begin()
                }.onEnded { _ in held = false; speech.finish() })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(speech.recording ? "结束录音并判断释义" : "说出中文释义")
                .accessibilityHint("普通操作按住说话，松开判断；旁白操作双击开始，再双击结束")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if occupied { speech.finish() } else { begin() } }
                .accessibilityIdentifier("study-spoken-meaning")
        }.onChange(of: scenePhase) { phase in if phase != .active { held = false; speech.cancel() } }
            .onDisappear { held = false; speech.cancel() }
            .task(id: step.spokenAttempts) {
                guard (step.spokenAttempts ?? 0) > 0, step.spokenCorrect == false, !step.revealed else { return }
                if reduceMotion { flash = true; try? await Task.sleep(nanoseconds: 450_000_000); flash = false; return }
                for _ in 0..<3 {
                    flash = true; try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { flash = false; return }
                    flash = false; try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
    }
    private func begin() {
        guard !model.busy, model.inStudy, model.state.active?.current?.id == step.id else { return }
        model.audio.stop(); model.medley.yieldAudio()
        let stepID = step.id
        speech.start(onResult: { text in
            guard model.inStudy, model.state.active?.current?.id == stepID else { return }
            model.action("spoken-answer", value: text, expectedStepID: stepID)
        }, onFailure: { reason in
            guard model.inStudy, model.state.active?.current?.id == stepID else { return }
            model.action("spoken-error", value: reason, expectedStepID: stepID)
        })
    }
}
