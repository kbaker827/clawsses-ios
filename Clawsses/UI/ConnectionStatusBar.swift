import SwiftUI

struct ConnectionStatusBar: View {
    let glassesState: GlassesConnectionManager.ConnectionState
    let openClawState: OpenClawClient.ConnectionState
    let onConnectGlasses: () -> Void
    let onConnectOpenClaw: () -> Void

    var body: some View {
        HStack {
            // Glasses side
            HStack(spacing: 4) {
                Circle()
                    .fill(glassesStatusColor)
                    .frame(width: 8, height: 8)
                Image(systemName: "eyeglasses")
                    .font(.caption)
                glassesLabel
            }

            Spacer()

            // OpenClaw side
            HStack(spacing: 4) {
                openClawLabel
                Image(systemName: "cloud")
                    .font(.caption)
                Circle()
                    .fill(openClawStatusColor)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .font(.caption)
    }

    @ViewBuilder
    private var glassesLabel: some View {
        switch glassesState {
        case .disconnected:
            Button("Connect", action: onConnectGlasses).font(.caption)
        case .scanning:
            Text("Scanning...").foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting...").foregroundStyle(.secondary)
        case .connected(let name):
            Text(name).foregroundStyle(.secondary)
        case .reconnecting(let attempt, _):
            Text("Reconnecting #\(attempt)...").foregroundStyle(.orange)
        case .error(let msg):
            Text(msg.prefix(30)).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var openClawLabel: some View {
        switch openClawState {
        case .disconnected:
            Button("Connect", action: onConnectOpenClaw).font(.caption)
        case .connecting:
            Text("Connecting...").foregroundStyle(.secondary)
        case .authenticating:
            Text("Authenticating...").foregroundStyle(.secondary)
        case .connected:
            Text("Connected").foregroundStyle(.secondary)
        case .pairingRequired(let msg):
            Text(msg.prefix(30)).foregroundStyle(.orange)
        case .error(let msg):
            Text(msg.prefix(30)).foregroundStyle(.red)
        }
    }

    private var glassesStatusColor: Color {
        switch glassesState {
        case .connected:    return .green
        case .scanning, .connecting: return .yellow
        case .reconnecting: return .orange
        case .error:        return .red
        default:            return .gray
        }
    }

    private var openClawStatusColor: Color {
        switch openClawState {
        case .connected:    return .green
        case .connecting, .authenticating: return .yellow
        case .pairingRequired: return .orange
        case .error:        return .red
        default:            return .gray
        }
    }
}
