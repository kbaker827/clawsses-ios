import SwiftUI

struct GlassesSection: View {
    @ObservedObject var glassesManager: GlassesConnectionManager

    var body: some View {
        Section("Rokid Glasses") {
            // Connection status
            HStack {
                connectionLabel
                Spacer()
                connectionActions
            }

            // Scan results
            if case .scanning = glassesManager.connectionState {
                if glassesManager.discoveredDevices.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Scanning for Rokid glasses…").foregroundStyle(.secondary).font(.caption)
                    }
                } else {
                    ForEach(glassesManager.discoveredDevices) { device in
                        Button {
                            glassesManager.connectToDevice(device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).font(.subheadline)
                                    Text("RSSI: \(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle").foregroundStyle(.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Wake on stream toggle
            Toggle("Wake display on new stream", isOn: Binding(
                get: { glassesManager.wakeSignalManager.enabled },
                set: { glassesManager.wakeSignalManager.setEnabled($0) }
            ))

            // BLE limitation note
            if !glassesManager.debugModeEnabled {
                Text("Note: Full BLE data transport requires Rokid's iOS SDK. Device discovery is functional. Use debug Wi-Fi mode for complete operation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch glassesManager.connectionState {
        case .disconnected:
            Label("Disconnected", systemImage: "circle").foregroundStyle(.secondary)
        case .scanning:
            Label("Scanning…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.yellow)
        case .connecting:
            Label("Connecting…", systemImage: "arrow.clockwise.circle").foregroundStyle(.yellow)
        case .connected(let name):
            Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .reconnecting(let attempt, _):
            Label("Reconnecting #\(attempt)…", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .error(let msg):
            Label(msg.prefix(40), systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var connectionActions: some View {
        switch glassesManager.connectionState {
        case .disconnected:
            Button("Scan") { glassesManager.startScanning() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .scanning:
            Button("Stop") { glassesManager.stopScanning() }
                .buttonStyle(.bordered).controlSize(.small)
        case .connected:
            Button("Disconnect") { glassesManager.disconnect() }
                .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.red)
        case .reconnecting:
            HStack(spacing: 8) {
                Button("Retry") { glassesManager.retryReconnectNow() }.buttonStyle(.bordered).controlSize(.small)
                Button("Cancel") { glassesManager.cancelReconnect() }.buttonStyle(.bordered).controlSize(.small)
            }
        default:
            EmptyView()
        }
    }
}
