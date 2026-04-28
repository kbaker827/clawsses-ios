import Foundation

struct ElevenLabsVoice: Codable, Identifiable {
    let voiceId: String
    let name: String
    let previewUrl: String?
    let category: String?

    var id: String { voiceId }

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
        case previewUrl = "preview_url"
        case category
    }
}

private struct VoicesResponse: Codable {
    let voices: [ElevenLabsVoice]
}

private struct VoiceSettings: Encodable {
    let speed: Double
}

private struct SynthesisRequest: Encodable {
    let text: String
    let modelId: String
    let voiceSettings: VoiceSettings?

    enum CodingKeys: String, CodingKey {
        case text
        case modelId = "model_id"
        case voiceSettings = "voice_settings"
    }
}

/// ElevenLabs API client for text-to-speech synthesis.
final class ElevenLabsClient {

    private static let baseURL = "https://api.elevenlabs.io/v1"
    private static let modelId = "eleven_turbo_v2_5"

    func getVoices(apiKey: String) async -> Result<[ElevenLabsVoice], Error> {
        guard let url = URL(string: "\(Self.baseURL)/voices") else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(URLError(.badServerResponse))
            }
            let decoded = try JSONDecoder().decode(VoicesResponse.self, from: data)
            return .success(decoded.voices)
        } catch {
            return .failure(error)
        }
    }

    func synthesize(apiKey: String, voiceId: String, text: String, speed: Double = 1.0) async -> Result<Data, Error> {
        guard let url = URL(string: "\(Self.baseURL)/text-to-speech/\(voiceId)/stream") else {
            return .failure(URLError(.badURL))
        }

        let settings = speed != 1.0 ? VoiceSettings(speed: speed) : nil
        let body = SynthesisRequest(text: text, modelId: Self.modelId, voiceSettings: settings)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(NSError(domain: "ElevenLabs", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                        userInfo: [NSLocalizedDescriptionKey: msg]))
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }
}
