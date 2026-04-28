import SwiftUI

struct ServerSection: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var token: String
    let state: OpenClawClient.ConnectionState
    let onApply: () -> Void

    var body: some View {
        Section("OpenClaw Server") {
            LabeledContent("Host") {
                TextField("192.168.1.1", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            LabeledContent("Port") {
                TextField("18789", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
            LabeledContent("Token") {
                SecureField("Access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            HStack {
                statusIndicator
                Spacer()
                Button("Apply & Reconnect", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting, .authenticating:
            Label("Connecting…", systemImage: "arrow.clockwise.circle").foregroundStyle(.yellow)
        case .pairingRequired:
            Label("Pairing required", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .error(let msg):
            Label(msg.prefix(40), systemImage: "xmark.circle").foregroundStyle(.red)
        default:
            Label("Disconnected", systemImage: "circle").foregroundStyle(.secondary)
        }
    }
}
