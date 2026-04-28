import SwiftUI

struct SettingsView: View {
    @Binding var openClawHost: String
    @Binding var openClawPort: String
    @Binding var openClawToken: String
    let openClawState: OpenClawClient.ConnectionState
    @ObservedObject var glassesManager: GlassesConnectionManager
    @ObservedObject var voiceManager: VoiceRecognitionManager
    @ObservedObject var ttsSettings: TtsSettingsManager
    let elevenLabsClient: ElevenLabsClient
    let onApplyServer: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ServerSection(
                    host: $openClawHost,
                    port: $openClawPort,
                    token: $openClawToken,
                    state: openClawState,
                    onApply: onApplyServer
                )

                GlassesSection(glassesManager: glassesManager)

                VoiceSection(voiceManager: voiceManager)

                TtsSection(settings: ttsSettings, elevenLabsClient: elevenLabsClient)

                DeveloperSection(glassesManager: glassesManager)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}
