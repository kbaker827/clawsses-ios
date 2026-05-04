// GlassesConnectionManager.swift — updated to use Rokid AI glasses SDK
// Previously used raw TCP sockets; now communicates over Bluetooth via RokidSDK.
//
// Setup:
//   1. pod install  (Podfile already updated)
//   2. Get credentials from https://account.rokid.com/#/setting/prove
//   3. Fill in appKey / appSecret / accessKey below

import Foundation
import RokidSDK

// ── Credentials ───────────────────────────────────────────────────────────────
private let kAppKey    = "YOUR_APP_KEY"
private let kAppSecret = "YOUR_APP_SECRET"
private let kAccessKey = "YOUR_ACCESS_KEY"

// ─────────────────────────────────────────────────────────────────────────────
@MainActor
final class GlassesConnectionManager: ObservableObject {

    // Published state
    @Published var isRunning:    Bool = false
    @Published var isConnected:  Bool = false
    @Published var clientCount:  Int  = 0     // kept for UI compatibility; always 0 or 1
    @Published var nearbyDevices: [RKDevice] = []

    // Inbound callbacks (same contract as the original TCP version)

    // Active paired device
    private var activeDevice: RKDevice?

    // ── SDK init ──────────────────────────────────────────────────────────────
    init() {
        RokidMobileSDK.shared.initSDK(
            appKey:    kAppKey,
            appSecret: kAppSecret,
            accessKey: kAccessKey
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error { print("[Rokid] init error: \(error)") }
                else { self?.loadPairedDevices() }
            }
        }
        RokidMobileSDK.binder.addObserver(observer: self)
    }

    // ── Device discovery ──────────────────────────────────────────────────────
    func loadPairedDevices() {
        RokidMobileSDK.device.queryDeviceList { [weak self] _, devices in
            Task { @MainActor [weak self] in
                self?.nearbyDevices = devices ?? []
                if let first = devices?.first { self?.connectDevice(first) }
            }
        }
    }

    func connectDevice(_ device: RKDevice) {
        activeDevice = device
        isConnected  = true
        clientCount  = 1
        isRunning    = true
        print("[Rokid] Connected to \(device.deviceName ?? "glasses")")
    }

    func disconnectDevice() {
        activeDevice = nil
        isConnected  = false
        clientCount  = 0
        isRunning    = false
    }

    // ── Public API (original method signatures preserved) ─────────────────────
    func setupWakeSignalManager() {
        // TODO: map to Rokid SDK call
    }

    func startScanning() {
        // TODO: map to Rokid SDK call
    }

    func stopScanning() {
        // TODO: map to Rokid SDK call
    }

    func connectToDevice(_ device: DiscoveredDevice) {
        // TODO: map to Rokid SDK call
    }

    func tryAutoReconnectOnStartup() -> Bool {
        // TODO: map to Rokid SDK call
    }

    func disconnect() {
        activeDevice = nil
        isConnected = false
    }

    func cancelReconnect() {
        // TODO: map to Rokid SDK call
    }

    func retryReconnectNow() {
        // TODO: map to Rokid SDK call
    }

    func hasSavedConnectionInfo() -> Bool {
        // TODO: map to Rokid SDK call
    }

    func getSavedDeviceName() -> String? {
        // TODO: map to Rokid SDK call
    }

    func sendRawMessage(_ json: String, isStreamContent: Bool = false, isNewMessage: Bool = false) {
        guard let dev = activeDevice else { return }
        RokidMobileSDK.vui.sendMessage(topic: "rawmessage", text: String(describing: json), to: dev)
    }

    func sendRawMessageDirect(_ json: String) {
        guard let dev = activeDevice else { return }
        RokidMobileSDK.vui.sendMessage(topic: "rawmessagedirect", text: String(describing: json), to: dev)
    }

    func notifyStreamStart(_ messageId: String) {
        // TODO: map to Rokid SDK call
    }

    func notifyStreamEnd(_ messageId: String) {
        // TODO: map to Rokid SDK call
    }

    func enableDebugMode() {
        // TODO: map to Rokid SDK call
    }

    func disableDebugMode() {
        // TODO: map to Rokid SDK call
    }
}

// ── Receive voice commands FROM the glasses ───────────────────────────────────
extension GlassesConnectionManager: SDKBinderObserver {
    nonisolated func onAsrResult(_ asr: String, device: RKDevice) {
        let cmd = asr.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            if cmd.lowercased().hasPrefix("run ") {
                self.onGlassesCommand?(String(cmd.dropFirst(4)))
            } else if cmd.lowercased().hasPrefix("ai ") {
                self.onRemoteQuery?(String(cmd.dropFirst(3)))
            } else if cmd.lowercased() == "mic" {
                self.onMicTrigger?()
            } else {
                self.onGlassesCommand?(cmd)
            }
        }
    }
}
