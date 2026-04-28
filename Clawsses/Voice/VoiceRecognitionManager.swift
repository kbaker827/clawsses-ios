import Foundation
import Combine

/// Manages voice recognition with OpenAI Realtime as primary and SFSpeechRecognizer as fallback.
@MainActor
final class VoiceRecognitionManager: ObservableObject {

    enum RecognitionMode { case none, openAI, fallback }
    enum FallbackReason { case none, noApiKey, disabled, connectionFailed, apiError }

    @Published private(set) var activeMode: RecognitionMode = .none
    @Published private(set) var fallbackReason: FallbackReason = .none
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    var onPartialResult: ((String) -> Void)?
    var onSpeechStopped: (() -> Void)?

    private let openAIClient = OpenAIRealtimeClient()
    private let fallbackHandler = VoiceCommandHandler()

    private static let prefsKey = "clawsses"
    private static let openAIKeyKey = "openai_api_key"
    private static let openAIEnabledKey = "openai_voice_enabled"

    init() {
        fallbackHandler.initialize()
    }

    func isOpenAIAvailable() -> Bool {
        !getOpenAIApiKey().isEmpty && isOpenAIVoiceEnabled()
    }

    func getOpenAIApiKey() -> String {
        UserDefaults.standard.string(forKey: Self.openAIKeyKey) ?? ""
    }

    func setOpenAIApiKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: Self.openAIKeyKey)
    }

    func isOpenAIVoiceEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Self.openAIEnabledKey) as? Bool ?? true
    }

    func setOpenAIVoiceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.openAIEnabledKey)
    }

    func getModeDescription() -> String {
        switch activeMode {
        case .openAI: return "OpenAI"
        case .fallback:
            switch fallbackReason {
            case .noApiKey: return "Device (no API key)"
            case .disabled: return "Device (OpenAI disabled)"
            case .connectionFailed: return "Device (connection failed)"
            case .apiError: return "Device (API error)"
            default: return "Device"
            }
        case .none: return "Idle"
        }
    }

    func startListening(languageTag: String? = nil, onResult: @escaping (VoiceCommandHandler.VoiceResult) -> Void) {
        if isListening { stopListening() }
        isListening = true
        lastError = nil

        let apiKey = getOpenAIApiKey()

        guard !apiKey.isEmpty else {
            fallbackReason = .noApiKey
            startFallback(languageTag: languageTag, onResult: onResult)
            return
        }
        guard isOpenAIVoiceEnabled() else {
            fallbackReason = .disabled
            startFallback(languageTag: languageTag, onResult: onResult)
            return
        }

        activeMode = .openAI
        fallbackReason = .none

        openAIClient.startListening(
            apiKey: apiKey,
            languageTag: languageTag,
            onPartial: { [weak self] text in self?.onPartialResult?(text) },
            onSpeechStopped: { [weak self] in self?.onSpeechStopped?() },
            onFinal: { [weak self] text in
                self?.isListening = false
                self?.activeMode = .none
                onResult(self?.processText(text) ?? .text(text))
            },
            onError: { [weak self] error in
                self?.lastError = error
                self?.fallbackReason = .apiError
                self?.startFallback(languageTag: languageTag, onResult: onResult)
            }
        )
    }

    func stopListening() {
        switch activeMode {
        case .openAI: openAIClient.stopListening()
        case .fallback: fallbackHandler.stopListening()
        case .none: break
        }
        isListening = false
        activeMode = .none
    }

    func cleanup() {
        stopListening()
        openAIClient.destroy()
        fallbackHandler.cleanup()
    }

    private func startFallback(languageTag: String?, onResult: @escaping (VoiceCommandHandler.VoiceResult) -> Void) {
        activeMode = .fallback
        fallbackHandler.onPartialResult = { [weak self] text in self?.onPartialResult?(text) }
        fallbackHandler.startListening(languageTag: languageTag) { [weak self] result in
            self?.isListening = false
            self?.activeMode = .none
            onResult(result)
        }
    }

    private func processText(_ text: String) -> VoiceCommandHandler.VoiceResult {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let commands: Set<String> = ["escape", "scroll up", "scroll down", "take screenshot",
                                     "take photo", "switch mode", "navigate mode", "scroll mode", "command mode"]
        for cmd in commands {
            if lower == cmd || lower.hasPrefix(cmd + " ") { return .command(cmd) }
        }
        return .text(text)
    }
}

// MARK: - OpenAI Realtime client stub

/// Thin wrapper around the OpenAI Realtime WebSocket API for voice transcription.
final class OpenAIRealtimeClient {

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var onFinal: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var transcriptAccumulator = ""

    func startListening(
        apiKey: String,
        languageTag: String?,
        onPartial: @escaping (String) -> Void,
        onSpeechStopped: @escaping () -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.onFinal = onFinal
        self.onError = onError
        transcriptAccumulator = ""

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-10-01") else {
            onError("Invalid OpenAI Realtime URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        sendSessionConfig(languageTag: languageTag)
        startAudioStream(onPartial: onPartial, onSpeechStopped: onSpeechStopped)
        receive()
    }

    func stopListening() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func destroy() {
        stopListening()
        urlSession = nil
    }

    private func sendSessionConfig(languageTag: String?) {
        var config: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": ["type": "server_vad", "silence_duration_ms": 800]
            ]
        ]
        if let tag = languageTag {
            var session = (config["session"] as? [String: Any]) ?? [:]
            session["language"] = tag
            config["session"] = session
        }
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let json = String(data: data, encoding: .utf8) {
            webSocketTask?.send(.string(json)) { _ in }
        }
    }

    private func startAudioStream(onPartial: @escaping (String) -> Void, onSpeechStopped: @escaping () -> Void) {
        AudioCaptureHelper.shared.start { [weak self] pcm16Data in
            guard let self, let task = self.webSocketTask else { return }
            let base64 = pcm16Data.base64EncodedString()
            let msg = """
            {"type":"input_audio_buffer.append","audio":"\(base64)"}
            """
            task.send(.string(msg)) { _ in }
        }
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handleServerEvent(text) }
                self.receive()
            case .failure(let error):
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            }
        }
    }

    private func handleServerEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            let transcript = obj["transcript"] as? String ?? ""
            transcriptAccumulator = transcript
            DispatchQueue.main.async { [weak self] in
                AudioCaptureHelper.shared.stop()
                self?.onFinal?(transcript)
            }
        case "input_audio_buffer.speech_stopped":
            DispatchQueue.main.async { [weak self] in _ = self }
        case "error":
            let errMsg = (obj["error"] as? [String: Any])?["message"] as? String ?? "OpenAI error"
            DispatchQueue.main.async { [weak self] in
                AudioCaptureHelper.shared.stop()
                self?.onError?(errMsg)
            }
        default:
            break
        }
    }
}

// MARK: - Audio capture helper

import AVFoundation

final class AudioCaptureHelper {
    static let shared = AudioCaptureHelper()
    private let engine = AVAudioEngine()
    private var onAudio: ((Data) -> Void)?

    func start(onAudio: @escaping (Data) -> Void) {
        self.onAudio = onAudio
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true)

        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
        inputNode.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, _ in
            if let data = buffer.toPCM16Data() { onAudio(data) }
        }
        engine.prepare()
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

extension AVAudioPCMBuffer {
    func toPCM16Data() -> Data? {
        guard let int16Channel = int16ChannelData?.pointee else { return nil }
        let frameCount = Int(frameLength)
        return Data(bytes: int16Channel, count: frameCount * 2)
    }
}
