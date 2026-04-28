import Foundation
import Network

/// WebSocket server that listens for the Rokid glasses app to connect (debug/emulator mode).
/// The glasses app connects to <phone-IP>:8081 when in debug mode.
final class DebugGlassesServer {

    static let defaultPort: UInt16 = 8081

    var onGlassesConnected: (() -> Void)?
    var onGlassesDisconnected: (() -> Void)?
    var onMessageFromGlasses: ((String) -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.clawsses.debug-server", qos: .userInitiated)

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
        guard let listener = try? NWListener(using: parameters, on: port) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[DebugServer] Listening on port \(Self.defaultPort)")
            case .failed(let error):
                print("[DebugServer] Listener failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }

    func sendToGlasses(_ message: String) -> Bool {
        guard let connection else { return false }
        guard let data = message.data(using: .utf8) else { return false }
        // Prefix with 4-byte big-endian length for simple framing
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        connection.send(content: frame, completion: .idempotent)
        return true
    }

    private func handleNewConnection(_ conn: NWConnection) {
        // Only allow one connection at a time
        connection?.cancel()
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.onGlassesConnected?() }
                self?.receiveNextMessage(from: conn)
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.onGlassesDisconnected?() }
                if self?.connection === conn { self?.connection = nil }
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func receiveNextMessage(from conn: NWConnection) {
        // Read the 4-byte length prefix first
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("[DebugServer] Receive error: \(error)")
                return
            }
            guard let data, data.count == 4 else {
                if isComplete { DispatchQueue.main.async { self.onGlassesDisconnected?() } }
                return
            }
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] bodyData, _, _, bodyError in
                guard let self else { return }
                if let bodyError {
                    print("[DebugServer] Body receive error: \(bodyError)")
                    return
                }
                if let bodyData, let message = String(data: bodyData, encoding: .utf8) {
                    DispatchQueue.main.async { self.onMessageFromGlasses?(message) }
                }
                self.receiveNextMessage(from: conn)
            }
        }
    }
}
