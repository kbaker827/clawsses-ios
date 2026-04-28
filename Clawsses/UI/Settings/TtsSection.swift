import SwiftUI

struct TtsSection: View {
    @ObservedObject var settings: TtsSettingsManager
    let elevenLabsClient: ElevenLabsClient

    @State private var apiKeyInput = ""
    @State private var showKey = false
    @State private var voices: [ElevenLabsVoice] = []
    @State private var isLoadingVoices = false
    @State private var voiceError: String?

    var body: some View {
        Section("Text-to-Speech (ElevenLabs)") {
            Toggle("Enable TTS", isOn: Binding(
                get: { settings.isEnabled },
                set: { settings.setEnabled($0) }
            ))

            if settings.isEnabled {
                HStack {
                    if showKey {
                        TextField("ElevenLabs API Key", text: $apiKeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("ElevenLabs API Key", text: $apiKeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                }
                .onAppear { apiKeyInput = settings.apiKey }

                Button("Save & Load Voices") { saveAndLoadVoices() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(apiKeyInput.isEmpty)

                if isLoadingVoices {
                    HStack { ProgressView(); Text("Loading voices…").font(.caption) }
                } else if let err = voiceError {
                    Text(err).foregroundStyle(.red).font(.caption)
                } else if !voices.isEmpty {
                    Picker("Voice", selection: Binding(
                        get: { settings.selectedVoiceId ?? "" },
                        set: { id in
                            if let v = voices.first(where: { $0.voiceId == id }) {
                                settings.setVoice(id: v.voiceId, name: v.name)
                            }
                        }
                    )) {
                        ForEach(voices) { voice in
                            Text(voice.name).tag(voice.voiceId)
                        }
                    }
                }

                if let name = settings.selectedVoiceName {
                    HStack {
                        Text("Active voice")
                        Spacer()
                        Text(name).foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
    }

    private func saveAndLoadVoices() {
        settings.setApiKey(apiKeyInput)
        isLoadingVoices = true
        voiceError = nil
        Task {
            let result = await elevenLabsClient.getVoices(apiKey: apiKeyInput)
            isLoadingVoices = false
            switch result {
            case .success(let list): voices = list
            case .failure(let err): voiceError = err.localizedDescription
            }
        }
    }
}
