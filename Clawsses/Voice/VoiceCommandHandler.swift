import Foundation
import Speech
import AVFoundation
import Combine

/// Handles speech recognition using iOS's Speech framework (device-based, no API key needed).
final class VoiceCommandHandler: NSObject {

    enum VoiceResult {
        case text(String)
        case command(String)
        case error(String)
    }

    @Published private(set) var isListening = false

    var onPartialResult: ((String) -> Void)?
    private var onResult: ((VoiceResult) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    private static let wordMappings: [String: String] = [
        "slash": "/", "forward slash": "/", "backslash": "\\", "back slash": "\\",
        "dot": ".", "period": ".", "comma": ",", "colon": ":", "semicolon": ";",
        "dash": "-", "hyphen": "-", "underscore": "_", "at": "@", "at sign": "@",
        "hash": "#", "hashtag": "#", "pound": "#", "dollar": "$", "dollar sign": "$",
        "percent": "%", "caret": "^", "ampersand": "&", "and sign": "&",
        "asterisk": "*", "star": "*", "open paren": "(", "close paren": ")",
        "open bracket": "[", "close bracket": "]", "open brace": "{", "close brace": "}",
        "pipe": "|", "tilde": "~", "backtick": "`", "quote": "\"",
        "single quote": "'", "apostrophe": "'", "equals": "=", "plus": "+",
        "minus": "-", "less than": "<", "greater than": ">", "space": " ",
        "newline": "\n", "enter": "\n", "tab": "\t"
    ]

    private static let specialCommands: Set<String> = [
        "escape", "scroll up", "scroll down", "take screenshot",
        "take photo", "switch mode", "navigate mode", "scroll mode", "command mode"
    ]

    func initialize() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func startListening(languageTag: String? = nil, onResult: @escaping (VoiceResult) -> Void) {
        self.onResult = onResult

        let locale = languageTag.flatMap { Locale(identifier: $0) } ?? Locale.current
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()

        guard recognizer?.isAvailable == true else {
            onResult(.error("Speech recognizer unavailable"))
            return
        }

        do {
            try startRecognitionSession()
            isListening = true
        } catch {
            onResult(.error("Failed to start: \(error.localizedDescription)"))
        }
    }

    func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isListening = false
    }

    func cleanup() {
        stopListening()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func startRecognitionSession() throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { throw NSError(domain: "Voice", code: 1) }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { self.onPartialResult?(text) }

                if result.isFinal {
                    self.finishRecognition(text: text)
                }
            }

            if let error {
                let nsError = error as NSError
                // Code 203 = "No speech detected" — treat as empty result
                if nsError.code == 203 || nsError.code == 1110 {
                    self.finishRecognition(text: "")
                } else if !error.localizedDescription.contains("canceled") {
                    self.finishWithError(error.localizedDescription)
                }
            }
        }
    }

    private func finishRecognition(text: String) {
        stopRecordingSession()
        let result = processSpokenText(text)
        DispatchQueue.main.async { [weak self] in
            self?.isListening = false
            self?.onResult?(result)
        }
    }

    private func finishWithError(_ message: String) {
        stopRecordingSession()
        DispatchQueue.main.async { [weak self] in
            self?.isListening = false
            self?.onResult?(.error(message))
        }
    }

    private func stopRecordingSession() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func processSpokenText(_ text: String) -> VoiceResult {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        for command in Self.specialCommands {
            if lower == command || lower.hasPrefix(command + " ") {
                return .command(command)
            }
        }

        var processed = text
        for (word, symbol) in Self.wordMappings {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(processed.startIndex..., in: processed)
                processed = regex.stringByReplacingMatches(in: processed, range: range, withTemplate: symbol)
            }
        }

        return .text(processed)
    }
}
