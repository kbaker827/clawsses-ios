import Foundation
import AVFoundation

/// Plays TTS audio from ElevenLabs when a message is complete.
@MainActor
final class TtsPlaybackManager {

    private let elevenLabsClient: ElevenLabsClient
    private let settingsManager: TtsSettingsManager
    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?

    init(elevenLabsClient: ElevenLabsClient, settingsManager: TtsSettingsManager) {
        self.elevenLabsClient = elevenLabsClient
        self.settingsManager = settingsManager
    }

    func onMessageComplete(_ text: String) {
        guard settingsManager.isEnabled,
              !settingsManager.apiKey.isEmpty,
              let voiceId = settingsManager.selectedVoiceId,
              !text.isEmpty else { return }

        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let result = await self.elevenLabsClient.synthesize(
                apiKey: self.settingsManager.apiKey,
                voiceId: voiceId,
                text: text,
                speed: self.settingsManager.speed
            )
            guard !Task.isCancelled else { return }
            if case .success(let data) = result {
                self.play(data: data)
            }
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func play(data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            print("[TTS] Playback failed: \(error)")
        }
    }
}
