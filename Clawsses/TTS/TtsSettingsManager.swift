import Foundation
import Combine

@MainActor
final class TtsSettingsManager: ObservableObject {

    @Published private(set) var isEnabled: Bool
    @Published private(set) var selectedVoiceId: String?
    @Published private(set) var selectedVoiceName: String?
    @Published private(set) var apiKey: String
    @Published private(set) var speed: Double

    private static let enabledKey    = "tts_enabled"
    private static let voiceIdKey    = "tts_voice_id"
    private static let voiceNameKey  = "tts_voice_name"
    private static let apiKeyKey     = "elevenlabs_api_key"
    private static let speedKey      = "tts_speed"

    init() {
        let prefs = UserDefaults.standard
        isEnabled       = prefs.bool(forKey: Self.enabledKey)
        selectedVoiceId = prefs.string(forKey: Self.voiceIdKey)
        selectedVoiceName = prefs.string(forKey: Self.voiceNameKey)
        apiKey          = prefs.string(forKey: Self.apiKeyKey) ?? ""
        speed           = prefs.object(forKey: Self.speedKey) as? Double ?? 1.0
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    func setVoice(id: String, name: String) {
        selectedVoiceId = id
        selectedVoiceName = name
        UserDefaults.standard.set(id,   forKey: Self.voiceIdKey)
        UserDefaults.standard.set(name, forKey: Self.voiceNameKey)
    }

    func setApiKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: Self.apiKeyKey)
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        UserDefaults.standard.set(speed, forKey: Self.speedKey)
    }
}
