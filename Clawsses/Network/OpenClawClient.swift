import Foundation
import Combine

/// WebSocket client for the OpenClaw Gateway.
/// Handles auth handshake (Ed25519), request/response correlation, event streaming, and auto-reconnect.
@MainActor
final class OpenClawClient: ObservableObject {

    // MARK: - Connection State

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case pairingRequired(String)
        case error(String)
    }

    // MARK: - Published state

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var sessionList: [SessionInfo] = []
    @Published private(set) var currentSessionKey: String? = nil
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var unreadSessions: Set<String> = []

    // MARK: - Callbacks for glasses bridge

    var onChatMessage: ((ChatMessage) -> Void)?
    var onChatHistory: (([ChatMessage]) -> Void)?
    var onAgentThinking: ((AgentThinking) -> Void)?
    var onChatStream: ((ChatStream) -> Void)?
    var onChatStreamEnd: ((ChatStreamEnd) -> Void)?
    var onSessionList: ((SessionListUpdate) -> Void)?
    var onConnectionUpdate: ((ConnectionUpdate) -> Void)?
    var onMoreHistoryLoaded: ((Int, Bool) -> Void)?

    // MARK: - Private

    private let deviceIdentity: DeviceIdentity
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var shouldReconnect = false

    private var host = ""
    private var port = 18789
    private var token = ""

    private var pendingRequests: [String: CheckedContinuation<OpenClawResponse, Error>] = [:]
    private var requestSeq: Int64 = 1

    private var challengeNonce: String?
    private var activeRunId: String?
    private var activeMessageId: String?
    private var activeSessionKey: String?
    private var streamingContent = ""

    private var currentHistoryLimit = 50

    private static let protocolVersion = 3
    private static let reconnectDelaySeconds: UInt64 = 3

    init(deviceIdentity: DeviceIdentity) {
        self.deviceIdentity = deviceIdentity
    }

    // MARK: - Public API

    func connect(host: String, port: Int, token: String) {
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.port = port
        self.token = token
        self.shouldReconnect = true
        openWebSocket()
    }

    func disconnect() {
        shouldReconnect = false
        closeWebSocket()
        connectionState = .disconnected
        notifyConnectionUpdate(connected: false)
        failAllPending()
    }

    func sendMessage(_ text: String, images: [String]? = nil) {
        Task {
            let userMsgId = UUID().uuidString
            let userMsg = ChatMessage(id: userMsgId, role: "user", content: text)
            addMessage(userMsg)
            onChatMessage?(userMsg)

            let idempotencyKey = UUID().uuidString
            var params: [String: Any] = [
                "sessionKey": currentSessionKey ?? "main",
                "idempotencyKey": idempotencyKey,
                "message": text
            ]
            if let images = images, !images.isEmpty {
                let attachments = images.enumerated().map { (i, base64) -> [String: Any] in
                    let mime = detectImageMimeType(base64)
                    let ext = mime == "image/webp" ? "webp" : "jpg"
                    return ["type": "image", "mimeType": mime, "fileName": "glasses-photo-\(i+1).\(ext)", "content": base64]
                }
                params["attachments"] = attachments
            }

            let assistantMsgId = UUID().uuidString
            activeMessageId = assistantMsgId
            activeSessionKey = currentSessionKey
            streamingContent = ""

            guard let response = try? await sendRequest(method: OpenClawMethods.chatSend, params: params) else { return }
            if response.ok {
                activeRunId = response.payload?.string("runId")
                onAgentThinking?(AgentThinking(id: assistantMsgId))
            } else {
                activeRunId = nil
                activeMessageId = nil
            }
        }
    }

    func requestSessions() {
        Task {
            let params: [String: Any] = ["includeDerivedTitles": true]
            guard let response = try? await sendRequest(method: OpenClawMethods.sessionList, params: params),
                  response.ok,
                  let sessionsRaw = response.payload?.array("sessions") else { return }
            let sessions = sessionsRaw.compactMap { obj -> SessionInfo? in
                guard let key = obj["key"] as? String else { return nil }
                return SessionInfo(
                    key: key,
                    displayName: obj["displayName"] as? String,
                    label: obj["label"] as? String,
                    derivedTitle: obj["derivedTitle"] as? String,
                    updatedAt: obj["updatedAt"] as? Int64,
                    kind: obj["kind"] as? String
                )
            }
            sessionList = sessions
            onSessionList?(SessionListUpdate(sessions: sessions, currentSessionKey: currentSessionKey, unreadSessionKeys: Array(unreadSessions)))
        }
    }

    func createSession() {
        Task {
            let key = currentSessionKey ?? "main"
            let params: [String: Any] = ["key": key]
            guard let response = try? await sendRequest(method: OpenClawMethods.sessionReset, params: params),
                  response.ok else { return }
            let newKey = response.payload?.string("key") ?? key
            currentSessionKey = newKey
            chatMessages = []
            notifyConnectionUpdate(connected: true, sessionId: newKey)
            onChatHistory?([])
        }
    }

    func switchSession(_ sessionKey: String) {
        currentSessionKey = sessionKey
        chatMessages = []
        currentHistoryLimit = 50
        unreadSessions.remove(sessionKey)
        notifyConnectionUpdate(connected: true, sessionId: sessionKey)
        loadSessionHistory(sessionKey: sessionKey)
    }

    func loadSessionHistory(sessionKey: String? = nil) {
        let key = sessionKey ?? currentSessionKey ?? "main"
        Task {
            let params: [String: Any] = ["sessionKey": key, "limit": 50]
            guard let response = try? await sendRequest(method: OpenClawMethods.chatHistory, params: params) else {
                chatMessages = []; onChatHistory?([]); return
            }
            guard response.ok, let messagesRaw = response.payload?.array("messages") else {
                chatMessages = []; onChatHistory?([]); return
            }
            let messages = parseHistoryMessages(messagesRaw)
            chatMessages = messages
            onChatHistory?(messages)
        }
    }

    func loadMoreHistory() {
        guard !isLoadingMoreHistory else { return }
        isLoadingMoreHistory = true
        let key = currentSessionKey ?? "main"
        let existingCount = chatMessages.count

        Task {
            currentHistoryLimit = min(currentHistoryLimit + 50, 500)
            let params: [String: Any] = ["sessionKey": key, "limit": currentHistoryLimit]
            guard let response = try? await sendRequest(method: OpenClawMethods.chatHistory, params: params),
                  response.ok, let messagesRaw = response.payload?.array("messages") else {
                isLoadingMoreHistory = false
                onMoreHistoryLoaded?(0, false)
                return
            }

            let totalReturnedByGateway = messagesRaw.count
            let rawMessages = parseHistoryMessages(messagesRaw)
            let newOlderCount = max(rawMessages.count - existingCount, 0)
            let olderMessages = rawMessages.prefix(newOlderCount).map { msg in
                ChatMessage(id: UUID().uuidString, role: msg.role, content: msg.content, timestamp: msg.timestamp)
            }
            chatMessages = Array(olderMessages) + chatMessages
            let hasMore = totalReturnedByGateway >= currentHistoryLimit
            isLoadingMoreHistory = false
            onMoreHistoryLoaded?(newOlderCount, hasMore)
        }
    }

    func sendSlashCommand(_ command: String) {
        sendMessage(command)
    }

    func cleanup() {
        shouldReconnect = false
        disconnect()
        receiveTask?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: - Internal

    private func openWebSocket() {
        let urlString: String
        if host.hasPrefix("ws://") || host.hasPrefix("wss://") {
            let trimmed = host
            urlString = trimmed.range(of: #":\d+$"#, options: .regularExpression) != nil
                ? trimmed : "\(trimmed):\(port)"
        } else {
            urlString = "ws://\(host):\(port)"
        }

        guard let url = URL(string: urlString) else {
            connectionState = .error("Invalid URL: \(urlString)")
            return
        }

        let originHost = host
            .replacingOccurrences(of: "ws://", with: "")
            .replacingOccurrences(of: "wss://", with: "")
        let originPort = originHost.range(of: #":\d+$"#, options: .regularExpression) != nil ? "" : ":\(port)"
        let origin = "http://\(originHost)\(originPort)"

        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        webSocketTask = urlSession?.webSocketTask(with: request)
        connectionState = .connecting
        webSocketTask?.resume()
        startReceiving()
    }

    private func closeWebSocket() {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession = nil
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = self.webSocketTask else { break }
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): await self.handleFrame(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleFrame(text)
                        }
                    @unknown default: break
                    }
                } catch {
                    if !Task.isCancelled {
                        await self.handleDisconnect(error: error)
                    }
                    break
                }
            }
        }
    }

    private func handleDisconnect(error: Error?) {
        connectionState = .disconnected
        notifyConnectionUpdate(connected: false)
        failAllPending()
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.reconnectDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled, self.shouldReconnect else { return }
            let state = self.connectionState
            if case .disconnected = state { self.openWebSocket() }
            else if case .error = state { self.openWebSocket() }
            else if case .pairingRequired = state { self.openWebSocket() }
        }
    }

    @MainActor
    private func handleFrame(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "res": handleResponse(obj)
        case "event": handleEvent(obj)
        default: break
        }
    }

    private func handleResponse(_ obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        let ok = obj["ok"] as? Bool ?? false
        let payloadRaw = obj["payload"] as? [String: Any]
        let errorRaw = obj["error"] as? [String: Any]

        let payload = payloadRaw?.mapValues { AnyCodable($0) }
        let error = errorRaw?.mapValues { AnyCodable($0) }
        let response = OpenClawResponse(type: "res", id: id, ok: ok, payload: payload, error: error)

        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: response)
        }
    }

    private func handleEvent(_ obj: [String: Any]) {
        guard let eventName = obj["event"] as? String else { return }
        let payloadRaw = obj["payload"] as? [String: Any]

        switch eventName {
        case OpenClawEvents.connectChallenge:
            challengeNonce = payloadRaw?["nonce"] as? String
            Task { await self.performAuth() }
        case OpenClawEvents.chat:
            handleChatEvent(payloadRaw)
        case "tick", OpenClawEvents.heartbeat:
            break
        default:
            break
        }
    }

    private func performAuth() async {
        guard let nonce = challengeNonce else {
            connectionState = .error("No challenge nonce")
            return
        }

        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let scopesList = ["operator.admin", "operator.read", "operator.write"]
        let signature = deviceIdentity.signAuthPayload(
            clientId: "openclaw-control-ui",
            clientMode: "ui",
            role: "operator",
            scopes: scopesList,
            signedAtMs: signedAtMs,
            token: token,
            nonce: nonce
        )

        var deviceDict: [String: Any] = [
            "id": deviceIdentity.deviceId,
            "publicKey": deviceIdentity.publicKeyBase64Url,
            "signature": signature,
            "signedAt": signedAtMs,
            "nonce": nonce
        ]
        if let savedToken = deviceIdentity.deviceToken {
            deviceDict["deviceToken"] = savedToken
        }

        let params: [String: Any] = [
            "minProtocol": Self.protocolVersion,
            "maxProtocol": Self.protocolVersion,
            "client": ["id": "openclaw-control-ui", "version": "1.0.0", "platform": "ios", "mode": "ui"],
            "role": "operator",
            "scopes": scopesList,
            "auth": ["token": token],
            "device": deviceDict,
            "locale": Locale.current.identifier,
            "userAgent": "clawsses-ios/1.0.0"
        ]

        guard let response = try? await sendRequest(method: OpenClawMethods.connect, params: params) else { return }

        if response.ok {
            if let dt = response.payload?.string("deviceToken") {
                deviceIdentity.deviceToken = dt
            }
            if let mainKey = (response.payload?.value["snapshot"] as? [String: Any])?["sessionDefaults"] as? [String: Any],
               let key = mainKey["mainSessionKey"] as? String {
                currentSessionKey = key
            }
            connectionState = .connected
            notifyConnectionUpdate(connected: true, sessionId: currentSessionKey)
            loadSessionHistory()
        } else {
            let errorMsg = response.error?.string("message") ?? "Authentication failed"
            let errorCode = response.error?.string("code") ?? ""
            if errorCode == "pairing_required" || errorMsg.lowercased().contains("pair") {
                connectionState = .pairingRequired(errorMsg)
            } else {
                connectionState = .error(errorMsg)
                shouldReconnect = false
            }
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func handleChatEvent(_ payload: [String: Any]?) {
        guard let payload,
              let state = payload["state"] as? String else { return }

        let runId = payload["runId"] as? String
        let eventSessionKey = payload["sessionKey"] as? String

        if let esk = eventSessionKey, let csk = currentSessionKey, esk != csk {
            unreadSessions.insert(esk)
            if runId != nil && runId == activeRunId {
                if state == "final" || state == "aborted" || state == "error" {
                    activeRunId = nil; activeMessageId = nil; activeSessionKey = nil; streamingContent = ""
                }
            }
            return
        }

        if let runId, let activeRunId, runId != activeRunId { return }
        guard let msgId = activeMessageId else { return }

        switch state {
        case "delta":
            let fullText = extractTextFromMessage(payload)
            if fullText.count > streamingContent.count {
                let newChunk = String(fullText.dropFirst(streamingContent.count))
                streamingContent = fullText
                onChatStream?(ChatStream(id: msgId, chunk: newChunk))
                updateStreamingMessage(id: msgId, fullText: fullText)
            }
        case "final":
            let fullText = extractTextFromMessage(payload)
            if !fullText.isEmpty && fullText.count > streamingContent.count {
                let newChunk = String(fullText.dropFirst(streamingContent.count))
                onChatStream?(ChatStream(id: msgId, chunk: newChunk))
                streamingContent = fullText
            }
            finalizeStreaming()
        case "aborted", "error":
            finalizeStreaming()
        default:
            break
        }
    }

    private func extractTextFromMessage(_ payload: [String: Any]) -> String {
        guard let message = payload["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]] else { return "" }
        return contentArray.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    private func finalizeStreaming() {
        guard let msgId = activeMessageId else { return }
        let content = streamingContent
        if !content.isEmpty {
            let msg = ChatMessage(id: msgId, role: "assistant", content: content)
            updateOrAddMessage(msg)
            onChatMessage?(msg)
        }
        onChatStreamEnd?(ChatStreamEnd(id: msgId))
        activeRunId = nil; activeMessageId = nil; activeSessionKey = nil; streamingContent = ""
    }

    private func addMessage(_ message: ChatMessage) {
        chatMessages.append(message)
    }

    private func updateOrAddMessage(_ message: ChatMessage) {
        if let idx = chatMessages.firstIndex(where: { $0.id == message.id }) {
            chatMessages[idx] = message
        } else {
            chatMessages.append(message)
        }
    }

    private func updateStreamingMessage(id: String, fullText: String) {
        let msg = ChatMessage(id: id, role: "assistant", content: fullText)
        if let idx = chatMessages.firstIndex(where: { $0.id == id }) {
            chatMessages[idx] = msg
        } else {
            chatMessages.append(msg)
        }
    }

    private func notifyConnectionUpdate(connected: Bool, sessionId: String? = nil) {
        let sessionName = sessionId.flatMap { id in sessionList.first(where: { $0.key == id })?.name }
        onConnectionUpdate?(ConnectionUpdate(connected: connected, sessionId: sessionId, sessionName: sessionName))
    }

    private func failAllPending() {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for c in continuations {
            c.resume(throwing: URLError(.networkConnectionLost))
        }
    }

    private func sendRequest(method: String, params: [String: Any]? = nil) async throws -> OpenClawResponse {
        let id = "\(method)-\(requestSeq)"
        requestSeq += 1

        let body: [String: Any?] = ["type": "req", "id": id, "method": method, "params": params]
        let filtered = body.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: filtered),
              let json = String(data: data, encoding: .utf8) else {
            throw URLError(.badURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            webSocketTask?.send(.string(json)) { [weak self] error in
                if let error {
                    self?.pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
            // 30-second timeout
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let c = self.pendingRequests.removeValue(forKey: id) {
                    c.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    private func parseHistoryMessages(_ raw: [[String: Any]]) -> [ChatMessage] {
        raw.compactMap { obj -> ChatMessage? in
            guard let role = obj["role"] as? String,
                  role == "user" || role == "assistant" else { return nil }
            let content: String
            if let str = obj["content"] as? String {
                content = str
            } else if let blocks = obj["content"] as? [[String: Any]] {
                content = blocks.compactMap { b -> String? in
                    guard b["type"] as? String == "text" else { return nil }
                    return b["text"] as? String
                }.joined()
            } else { return nil }
            guard !content.isEmpty else { return nil }
            let timestamp = obj["timestamp"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
            return ChatMessage(id: UUID().uuidString, role: role, content: content, timestamp: timestamp)
        }
    }

    private func detectImageMimeType(_ base64: String) -> String {
        guard let data = Data(base64Encoded: String(base64.prefix(16))), data.count >= 4 else { return "image/webp" }
        if data[0] == 0xFF && data[1] == 0xD8 { return "image/jpeg" }
        if data[0] == 0x89 && data[1] == 0x50 { return "image/png" }
        if data[0] == 0x52 && data[1] == 0x49 { return "image/webp" }
        return "image/webp"
    }
}
