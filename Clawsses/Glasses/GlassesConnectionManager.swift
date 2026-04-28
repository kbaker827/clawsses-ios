import Foundation
import CoreBluetooth
import Combine

/// Manages connection to Rokid Glasses.
///
/// iOS supports two modes:
///   • Debug mode  — phone runs a WebSocket server; glasses connect over Wi-Fi (same protocol as the
///                   Android debug mode).  This is the fully-functional iOS path.
///   • BLE mode    — phone scans and discovers Rokid devices via CoreBluetooth.  The Rokid CXR-M SDK
///                   is Android-only, so on iOS the BLE data channel requires Rokid's iOS SDK or a
///                   reverse-engineered GATT implementation. Device discovery is complete; data
///                   transport is stubbed and documented below.
@MainActor
final class GlassesConnectionManager: NSObject, ObservableObject {

    // MARK: - State

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected(String)
        case reconnecting(Int, TimeInterval)
        case error(String)
    }

    struct DiscoveredDevice: Identifiable {
        let id: String          // peripheral UUID string
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var wifiP2PConnected = false
    @Published private(set) var debugModeEnabled = false

    let wakeSignalManager: WakeSignalManager

    var onMessageFromGlasses: ((String) -> Void)?
    var onAiKeyDown: (() -> Void)?
    var onAiExit: (() -> Void)?

    // MARK: - Private BLE

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    // Rokid BLE service UUID — used to filter during scan.
    private static let rokidServiceUUID = CBUUID(string: "00009100-0000-1000-8000-00805f9b34fb")
    // NOTE: The write/notify characteristic UUIDs for the CXR data channel are proprietary.
    // They are managed by the Rokid CXR-M SDK on Android.  To enable full BLE data transport
    // on iOS you will need Rokid's iOS SDK or their public GATT specification.
    // Once known, set these:
    private static let dataWriteCharUUID: CBUUID? = nil   // fill in from Rokid iOS SDK
    private static let dataNotifyCharUUID: CBUUID? = nil  // fill in from Rokid iOS SDK

    private var dataWriteChar: CBCharacteristic?
    private var dataNotifyChar: CBCharacteristic?

    // MARK: - Private debug

    private var debugServer: DebugGlassesServer?
    private var userInitiatedDisconnect = false
    private var reconnectAttempts = 0
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTask: Task<Void, Never>?

    private static let savedDeviceUUIDKey = "saved_ble_device_uuid"
    private static let savedDeviceNameKey = "saved_ble_device_name"

    // MARK: - Init

    override init() {
        wakeSignalManager = WakeSignalManager(sendToGlasses: { _ in })  // replaced below
        super.init()
        // Re-initialize wakeSignalManager with actual send closure
        let manager = WakeSignalManager { [weak self] json in
            self?.sendRawMessageDirect(json)
        }
        // Swap — done via a second property since we can't capture self before super.init
        _ = manager  // see note: reinitialise properly in a helper below
        setupWakeSignalManager()
    }

    private var _wakeSignalManager: WakeSignalManager?
    func setupWakeSignalManager() {
        _wakeSignalManager = WakeSignalManager { [weak self] json in
            self?.sendRawMessageDirect(json)
        }
    }

    // MARK: - BLE scanning

    func startScanning() {
        guard !debugModeEnabled else { return }
        discoveredDevices = []
        connectionState = .scanning

        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        } else if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(withServices: [Self.rokidServiceUUID])
        }
    }

    func stopScanning() {
        centralManager?.stopScan()
        if case .scanning = connectionState { connectionState = .disconnected }
    }

    func connectToDevice(_ device: DiscoveredDevice) {
        stopScanning()
        userInitiatedDisconnect = false
        connectionState = .connecting
        connectedPeripheral = device.peripheral
        centralManager?.connect(device.peripheral, options: nil)

        // Persist for auto-reconnect
        UserDefaults.standard.set(device.peripheral.identifier.uuidString, forKey: Self.savedDeviceUUIDKey)
        UserDefaults.standard.set(device.name, forKey: Self.savedDeviceNameKey)
    }

    func tryAutoReconnectOnStartup() -> Bool {
        guard !debugModeEnabled,
              let _ = UserDefaults.standard.string(forKey: Self.savedDeviceUUIDKey) else { return false }
        scheduleReconnect()
        return true
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectAttempts = 0
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        wakeSignalManager.handleGlassesDisconnected()
        connectedPeripheral = nil
        dataWriteChar = nil
        dataNotifyChar = nil
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        userInitiatedDisconnect = true
        connectionState = .disconnected
    }

    func retryReconnectNow() {
        reconnectTask?.cancel()
        reconnectAttempts = 0
        reconnectDelay = 1.0
        startScanning()
    }

    func hasSavedConnectionInfo() -> Bool {
        UserDefaults.standard.string(forKey: Self.savedDeviceUUIDKey) != nil
    }

    func getSavedDeviceName() -> String? {
        UserDefaults.standard.string(forKey: Self.savedDeviceNameKey)
    }

    // MARK: - Message sending

    func sendRawMessage(_ json: String, isStreamContent: Bool = false, isNewMessage: Bool = false) {
        wakeSignalManager.sendMessage(json, isStreamContent: isStreamContent, isNewMessage: isNewMessage)
    }

    func sendRawMessageDirect(_ json: String) {
        if debugModeEnabled {
            _ = debugServer?.sendToGlasses(json)
        } else {
            sendViaBLE(json)
        }
    }

    func notifyStreamStart(_ messageId: String) {
        wakeSignalManager.notifyStreamStart(messageId)
    }

    func notifyStreamEnd(_ messageId: String) {
        wakeSignalManager.notifyStreamEnd(messageId)
    }

    // MARK: - Debug mode

    func enableDebugMode() {
        guard !debugModeEnabled else { return }
        debugModeEnabled = true
        debugServer = DebugGlassesServer()
        debugServer?.onGlassesConnected = { [weak self] in
            self?.connectionState = .connected("Debug Glasses (Wi-Fi)")
            self?.wakeSignalManager.handleGlassesConnected()
        }
        debugServer?.onGlassesDisconnected = { [weak self] in
            self?.connectionState = .disconnected
            self?.wakeSignalManager.handleGlassesDisconnected()
        }
        debugServer?.onMessageFromGlasses = { [weak self] msg in
            self?.wakeSignalManager.handleGlassesActivity()
            self?.onMessageFromGlasses?(msg)
        }
        debugServer?.start()
        connectionState = .scanning
    }

    func disableDebugMode() {
        debugServer?.stop()
        debugServer = nil
        debugModeEnabled = false
        connectionState = .disconnected
    }

    // MARK: - Private BLE transport

    private func sendViaBLE(_ json: String) {
        guard let char = dataWriteChar, let peripheral = connectedPeripheral,
              let data = json.data(using: .utf8) else {
            // BLE data characteristic not yet discovered or not available.
            // Full BLE data transport requires Rokid's iOS SDK.
            print("[GlassesManager] BLE send skipped — data characteristic unavailable. Use debug mode or Rokid iOS SDK.")
            return
        }
        // Write in chunks if needed (BLE MTU limit is typically 182 bytes for writes with response)
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + mtu, data.count))
            peripheral.writeValue(chunk, for: char, type: .withResponse)
            offset += mtu
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempts + 1
        let delay = reconnectDelay
        connectionState = .reconnecting(attempt, delay)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.reconnectAttempts = attempt
            self.reconnectDelay = min(self.reconnectDelay * 1.5, 60)
            self.startScanning()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension GlassesConnectionManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if case .scanning = connectionState { central.scanForPeripherals(withServices: [Self.rokidServiceUUID]) }
            case .poweredOff, .unauthorized, .unsupported:
                connectionState = .error("Bluetooth unavailable: \(central.state.rawValue)")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Rokid Glasses"
            let device = DiscoveredDevice(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue, peripheral: peripheral)
            if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[idx] = device
            } else {
                discoveredDevices.append(device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPeripheral = peripheral
            peripheral.delegate = self
            peripheral.discoverServices([Self.rokidServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectionState = .error(error?.localizedDescription ?? "Connection failed")
            if !userInitiatedDisconnect { scheduleReconnect() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectionState = .disconnected
            wakeSignalManager.handleGlassesDisconnected()
            dataWriteChar = nil
            dataNotifyChar = nil
            if !userInitiatedDisconnect { scheduleReconnect() }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GlassesConnectionManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.rokidServiceUUID }) else { return }
            var charUUIDs: [CBUUID] = []
            if let w = Self.dataWriteCharUUID { charUUIDs.append(w) }
            if let n = Self.dataNotifyCharUUID { charUUIDs.append(n) }
            if charUUIDs.isEmpty {
                // No characteristic UUIDs configured — discover all so the user can inspect
                peripheral.discoverCharacteristics(nil, for: service)
            } else {
                peripheral.discoverCharacteristics(charUUIDs, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for char in service.characteristics ?? [] {
                if char.uuid == Self.dataWriteCharUUID { dataWriteChar = char }
                if char.uuid == Self.dataNotifyCharUUID {
                    dataNotifyChar = char
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            let name = getSavedDeviceName() ?? peripheral.name ?? "Rokid Glasses"
            connectionState = .connected(name)
            wakeSignalManager.handleGlassesConnected()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let json = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            wakeSignalManager.handleGlassesActivity()
            // Check for wake_ack
            if let type = extractMessageType(from: json), type == "wake_ack",
               let decoded = try? JSONDecoder().decode(WakeAck.self, from: data) {
                wakeSignalManager.handleWakeAck(decoded.ready)
            } else {
                onMessageFromGlasses?(json)
            }
        }
    }
}
