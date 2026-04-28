import Foundation
import Combine

/// Manages wake signal coordination so messages are buffered when glasses may be in standby,
/// then flushed once the glasses acknowledge they are awake.
@MainActor
final class WakeSignalManager: ObservableObject {

    enum WakeState {
        case unknown
        case awake
        case standby
        case wakingUp
    }

    @Published private(set) var wakeState: WakeState = .unknown
    @Published private(set) var enabled: Bool

    private var messageBuffer: [(String, Bool, Bool)] = []  // (json, isStream, isNew)
    private var wakeAckTask: Task<Void, Never>?
    private var activeStreamMessageId: String?

    private let sendToGlasses: (String) -> Void
    private static let wakeAckTimeoutSeconds: UInt64 = 3
    private static let prefsKey = "wake_on_stream_enabled"

    init(sendToGlasses: @escaping (String) -> Void) {
        self.sendToGlasses = sendToGlasses
        self.enabled = UserDefaults.standard.object(forKey: Self.prefsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.prefsKey)
    }

    func handleGlassesConnected() {
        wakeState = .awake
        flushBuffer()
    }

    func handleGlassesDisconnected() {
        wakeState = .unknown
        messageBuffer.removeAll()
        wakeAckTask?.cancel()
    }

    func handleGlassesActivity() {
        if wakeState != .awake { wakeState = .awake }
    }

    func handleWakeAck(_ ready: Bool) {
        wakeAckTask?.cancel()
        wakeState = ready ? .awake : .standby
        if ready { flushBuffer() }
    }

    func notifyStreamStart(_ messageId: String) {
        activeStreamMessageId = messageId
    }

    func notifyStreamEnd(_ messageId: String) {
        if activeStreamMessageId == messageId { activeStreamMessageId = nil }
    }

    func sendMessage(_ json: String, isStreamContent: Bool = false, isNewMessage: Bool = false) {
        guard enabled else {
            sendToGlasses(json)
            return
        }

        switch wakeState {
        case .awake:
            sendToGlasses(json)
        case .standby, .unknown:
            if isStreamContent || isNewMessage {
                messageBuffer.append((json, isStreamContent, isNewMessage))
                sendWakeSignal(reason: isStreamContent ? WakeSignal.Reason.streamContent : WakeSignal.Reason.newMessage,
                               bufferedCount: messageBuffer.count)
            } else {
                sendToGlasses(json)
            }
        case .wakingUp:
            messageBuffer.append((json, isStreamContent, isNewMessage))
        }
    }

    private func sendWakeSignal(reason: String, bufferedCount: Int) {
        guard wakeState != .wakingUp else { return }
        wakeState = .wakingUp
        let signal = WakeSignal(reason: reason, bufferedCount: bufferedCount)
        sendToGlasses(signal.toJson())

        wakeAckTask?.cancel()
        wakeAckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.wakeAckTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // Timed out waiting for ack — assume awake and flush
            self.wakeState = .awake
            self.flushBuffer()
        }
    }

    private func flushBuffer() {
        let buffered = messageBuffer
        messageBuffer.removeAll()
        for (json, _, _) in buffered {
            sendToGlasses(json)
        }
    }
}
