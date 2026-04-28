import SwiftUI

struct VoiceSection: View {
    @ObservedObject var voiceManager: VoiceRecognitionManager
    @State private var apiKeyInput = ""
    @State private var showKey = false

    var body: some View {
        Section("Voice Recognition") {
            Toggle("Use OpenAI Realtime (higher quality)", isOn: Binding(
                get: { voiceManager.isOpenAIVoiceEnabled() },
                set: { voiceManager.setOpenAIVoiceEnabled($0) }
            ))

            if voiceManager.isOpenAIVoiceEnabled() {
                HStack {
                    if showKey {
                        TextField("sk-...", text: $apiKeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("OpenAI API Key", text: $apiKeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                }
                .onAppear { apiKeyInput = voiceManager.getOpenAIApiKey() }

                Button("Save API Key") {
                    voiceManager.setOpenAIApiKey(apiKeyInput)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(apiKeyInput.isEmpty)
            }

            HStack {
                Text("Mode")
                Spacer()
                Text(voiceManager.getModeDescription())
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
