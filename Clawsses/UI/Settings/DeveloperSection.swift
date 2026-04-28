import SwiftUI

struct DeveloperSection: View {
    @ObservedObject var glassesManager: GlassesConnectionManager

    var body: some View {
        Section("Developer") {
            Toggle("Debug Wi-Fi Mode", isOn: Binding(
                get: { glassesManager.debugModeEnabled },
                set: { enabled in
                    if enabled { glassesManager.enableDebugMode() }
                    else { glassesManager.disableDebugMode() }
                }
            ))

            if glassesManager.debugModeEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone runs a WebSocket server on port 8081.")
                    Text("On the glasses (Android), configure the debug client to connect to this phone's IP address on port 8081.")
                    Text("Find your phone's IP: Settings → Wi-Fi → tap your network.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Link("Rokid SDK documentation",
                 destination: URL(string: "https://developer.rokid.com")!)
                .font(.caption)
        }
    }
}
