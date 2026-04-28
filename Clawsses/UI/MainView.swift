import SwiftUI
import PhotosUI

@MainActor
struct MainView: View {

    @StateObject private var glassesManager = GlassesConnectionManager()
    @StateObject private var openClawClient: OpenClawClient
    @StateObject private var voiceManager = VoiceRecognitionManager()
    @StateObject private var ttsSettings = TtsSettingsManager()

    private let deviceIdentity = DeviceIdentity()
    private let elevenLabs = ElevenLabsClient()
    @StateObject private var ttsPlayback: TtsPlaybackManager

    @State private var inputText = ""
    @State private var showSettings = false
    @State private var showSessionPicker = false
    @State private var pendingPhotos: [String] = []
    @State private var openClawHost: String
    @State private var openClawPort: String
    @State private var openClawToken: String
    @State private var glassesMessageLimit = 20
    @State private var isPhoneLoadingMore = false

    init() {
        let identity = DeviceIdentity()
        let client = OpenClawClient(deviceIdentity: identity)
        _openClawClient = StateObject(wrappedValue: client)

        let settings = TtsSettingsManager()
        let labs = ElevenLabsClient()
        _ttsPlayback = StateObject(wrappedValue: TtsPlaybackManager(elevenLabsClient: labs, settingsManager: settings))
        _ttsSettings = StateObject(wrappedValue: settings)

        let prefs = UserDefaults.standard
        _openClawHost  = State(initialValue: prefs.string(forKey: "openclaw_host")  ?? "192.168.1.1")
        _openClawPort  = State(initialValue: prefs.string(forKey: "openclaw_port")  ?? "18789")
        _openClawToken = State(initialValue: prefs.string(forKey: "openclaw_token") ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionStatusBar(
                    glassesState: glassesManager.connectionState,
                    openClawState: openClawClient.connectionState,
                    onConnectGlasses: { glassesManager.startScanning() },
                    onConnectOpenClaw: {
                        let portNum = Int(openClawPort) ?? 18789
                        openClawClient.connect(host: openClawHost, port: portNum, token: openClawToken)
                    }
                )

                if case .connected = openClawClient.connectionState {
                    SessionSelector(
                        sessions: openClawClient.sessionList,
                        currentSessionKey: openClawClient.currentSessionKey,
                        unreadSessionKeys: openClawClient.unreadSessions,
                        expanded: $showSessionPicker,
                        onToggle: {
                            if !showSessionPicker { openClawClient.requestSessions() }
                            showSessionPicker.toggle()
                        },
                        onSelect: { session in
                            showSessionPicker = false
                            openClawClient.switchSession(session.key)
                        }
                    )
                }

                ChatList(
                    messages: openClawClient.chatMessages,
                    isLoadingMore: openClawClient.isLoadingMoreHistory,
                    onScrolledToTop: {
                        openClawClient.loadMoreHistory()
                    }
                )

                if !pendingPhotos.isEmpty {
                    PhotoThumbnailStrip(photos: $pendingPhotos, onRemove: { idx in
                        pendingPhotos.remove(at: idx)
                        glassesManager.sendRawMessage("""
                        {"type":"remove_photo","index":\(idx)}
                        """)
                    })
                }

                InputBar(
                    text: $inputText,
                    isListening: voiceManager.isListening,
                    voiceMode: voiceManager.activeMode,
                    glassesConnected: glassesManager.connectionState.isConnected,
                    onSend: sendMessage,
                    onVoice: toggleVoice,
                    onCamera: takePhoto
                )
            }
            .background(Color(red: 0.12, green: 0.12, blue: 0.12))
            .navigationTitle("Clawsses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    openClawHost: $openClawHost,
                    openClawPort: $openClawPort,
                    openClawToken: $openClawToken,
                    openClawState: openClawClient.connectionState,
                    glassesManager: glassesManager,
                    voiceManager: voiceManager,
                    ttsSettings: ttsSettings,
                    elevenLabsClient: elevenLabs,
                    onApplyServer: {
                        let prefs = UserDefaults.standard
                        prefs.set(openClawHost, forKey: "openclaw_host")
                        prefs.set(openClawPort, forKey: "openclaw_port")
                        prefs.set(openClawToken, forKey: "openclaw_token")
                        openClawClient.disconnect()
                    },
                    onDismiss: { showSettings = false }
                )
            }
        }
        .onAppear { wireCallbacks() }
        .task { glassesManager.tryAutoReconnectOnStartup() }
        .onChange(of: openClawClient.connectionState) { _, newState in
            if case .connected = newState { openClawClient.requestSessions() }
        }
        .onChange(of: glassesManager.connectionState) { _, newState in
            if case .connected = newState {
                let msgs = openClawClient.chatMessages
                if !msgs.isEmpty { glassesManager.sendRawMessage(buildChatHistoryJson(msgs)) }
                let tts = TtsState(enabled: ttsSettings.isEnabled, voiceName: ttsSettings.selectedVoiceName)
                glassesManager.sendRawMessage(tts.toJson())
            }
        }
        .onChange(of: ttsSettings.isEnabled) { _, _ in syncTtsState() }
        .onChange(of: ttsSettings.selectedVoiceName) { _, _ in syncTtsState() }
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let photos = pendingPhotos.isEmpty ? nil : pendingPhotos
        openClawClient.sendMessage(inputText, images: photos)
        inputText = ""
        pendingPhotos = []
        if photos != nil {
            glassesManager.sendRawMessage("""
            {"type":"remove_photo","all":true}
            """)
        }
    }

    private func toggleVoice() {
        if voiceManager.isListening {
            voiceManager.stopListening()
        } else {
            voiceManager.startListening { result in
                switch result {
                case .text(let text) where !text.isEmpty:
                    openClawClient.sendMessage(text)
                default:
                    break
                }
            }
        }
    }

    private func takePhoto() {
        // On iOS we launch the camera via UIImagePickerController / PhotosPicker
        // The result is encoded to base64 and added to pendingPhotos.
        // This is wired via PhotoCaptureCoordinator in the InputBar.
    }

    private func syncTtsState() {
        guard glassesManager.connectionState.isConnected else { return }
        let tts = TtsState(enabled: ttsSettings.isEnabled, voiceName: ttsSettings.selectedVoiceName)
        glassesManager.sendRawMessage(tts.toJson())
    }

    // MARK: - Callback wiring

    private func wireCallbacks() {
        openClawClient.onChatMessage = { [weak glassesManager] msg in
            glassesManager?.sendRawMessage(msg.toJson())
        }
        openClawClient.onChatHistory = { [weak glassesManager, weak self] messages in
            self?.glassesMessageLimit = 20
            glassesManager?.sendRawMessage(buildChatHistoryJson(messages))
        }
        openClawClient.onAgentThinking = { [weak glassesManager] msg in
            glassesManager?.notifyStreamStart(msg.id)
            glassesManager?.sendRawMessage(msg.toJson(), isStreamContent: true)
        }
        openClawClient.onChatStream = { [weak glassesManager] msg in
            glassesManager?.sendRawMessage(msg.toJson(), isStreamContent: true)
        }
        openClawClient.onChatStreamEnd = { [weak self, weak glassesManager] msg in
            glassesManager?.notifyStreamEnd(msg.id)
            glassesManager?.sendRawMessage(msg.toJson())
            if let text = self?.openClawClient.chatMessages.last(where: { $0.id == msg.id })?.content {
                self?.ttsPlayback.onMessageComplete(text)
            }
        }
        openClawClient.onSessionList = { [weak glassesManager] msg in
            glassesManager?.sendRawMessage(msg.toJson())
        }
        openClawClient.onConnectionUpdate = { [weak glassesManager] msg in
            glassesManager?.sendRawMessage(msg.toJson())
        }
        openClawClient.onMoreHistoryLoaded = { [weak self, weak glassesManager] count, hasMore in
            guard let self else { return }
            if count > 0 { self.glassesMessageLimit += count }
            let json = buildChatHistoryJson(self.openClawClient.chatMessages, max: self.glassesMessageLimit, isLoadMore: true, hasMore: hasMore)
            glassesManager?.sendRawMessage(json)
        }

        glassesManager.onMessageFromGlasses = { [weak self] message in
            self?.handleGlassesMessage(message)
        }

        voiceManager.onPartialResult = { [weak glassesManager] partial in
            let msg = """
            {"type":"voice_state","state":"recognizing","text":"\(partial.escaped)"}
            """
            glassesManager?.sendRawMessage(msg)
        }
    }

    private func handleGlassesMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "user_input":
            let text = obj["text"] as? String ?? ""
            if !text.isEmpty {
                openClawClient.sendMessage(text, images: pendingPhotos.isEmpty ? nil : pendingPhotos)
                pendingPhotos = []
            }
        case "start_voice":
            let mode = voiceManager.isOpenAIAvailable() ? "openai" : "device"
            glassesManager.sendRawMessage("""
            {"type":"voice_state","state":"listening","mode":"\(mode)"}
            """)
            voiceManager.onSpeechStopped = { [weak self] in
                self?.glassesManager.sendRawMessage("""
                {"type":"voice_state","state":"processing","mode":"\(mode)"}
                """)
            }
            voiceManager.startListening { [weak self] result in
                guard let self else { return }
                switch result {
                case .text(let text):
                    let resultMsg = """
                    {"type":"voice_result","result_type":"text","text":"\(text.escaped)"}
                    """
                    self.glassesManager.sendRawMessage(resultMsg)
                case .command(let cmd):
                    let resultMsg = """
                    {"type":"voice_result","result_type":"command","text":"\(cmd.escaped)"}
                    """
                    self.glassesManager.sendRawMessage(resultMsg)
                case .error(let err):
                    let resultMsg = """
                    {"type":"voice_result","result_type":"error","text":"\(err.escaped)"}
                    """
                    self.glassesManager.sendRawMessage(resultMsg)
                }
            }
        case "cancel_voice":
            voiceManager.stopListening()
            glassesManager.sendRawMessage("""
            {"type":"voice_state","state":"idle"}
            """)
        case "list_sessions":
            openClawClient.requestSessions()
        case "switch_session":
            if let key = obj["sessionKey"] as? String, !key.isEmpty {
                openClawClient.switchSession(key)
            }
        case "create_session":
            openClawClient.createSession()
        case "slash_command":
            if let cmd = obj["command"] as? String, !cmd.isEmpty {
                openClawClient.sendSlashCommand(cmd)
            }
        case "request_state":
            let isConnected: Bool
            if case .connected = openClawClient.connectionState { isConnected = true } else { isConnected = false }
            let update = ConnectionUpdate(connected: isConnected, sessionId: openClawClient.currentSessionKey, sessionName: nil)
            glassesManager.sendRawMessage(update.toJson())
            glassesManager.sendRawMessage(buildChatHistoryJson(openClawClient.chatMessages))
            let tts = TtsState(enabled: ttsSettings.isEnabled, voiceName: ttsSettings.selectedVoiceName)
            glassesManager.sendRawMessage(tts.toJson())
        case "tts_toggle":
            let enabled = obj["enabled"] as? Bool ?? false
            ttsSettings.setEnabled(enabled)
            syncTtsState()
        case "request_more_history":
            let all = openClawClient.chatMessages
            if glassesMessageLimit < all.count {
                glassesMessageLimit = min(glassesMessageLimit + 15, all.count)
                glassesManager.sendRawMessage(buildChatHistoryJson(all, max: glassesMessageLimit, isLoadMore: true, hasMore: true))
            } else {
                openClawClient.loadMoreHistory()
            }
        default:
            break
        }
    }
}

// MARK: - Chat list

private struct ChatList: View {
    let messages: [ChatMessage]
    let isLoadingMore: Bool
    let onScrolledToTop: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    ForEach(messages) { msg in
                        ChatMessageRow(msg: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color(red: 0.12, green: 0.12, blue: 0.12))
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .overlay(alignment: .top) {
                // Trigger load-more when near top
                GeometryReader { geo in
                    Color.clear.onAppear {
                        if geo.frame(in: .global).minY > 0 { onScrolledToTop() }
                    }
                }.frame(height: 1)
            }
        }
    }
}

// MARK: - Input bar

private struct InputBar: View {
    @Binding var text: String
    let isListening: Bool
    let voiceMode: VoiceRecognitionManager.RecognitionMode
    let glassesConnected: Bool
    let onSend: () -> Void
    let onVoice: () -> Void
    let onCamera: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("Type message...", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .onSubmit { onSend() }

            Button(action: onCamera) {
                Image(systemName: "camera")
                    .foregroundStyle(glassesConnected ? .primary : .secondary)
            }
            .disabled(!glassesConnected)

            Button(action: onVoice) {
                Image(systemName: isListening ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(voiceIconColor)
            }

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var voiceIconColor: Color {
        guard isListening else { return .primary }
        return voiceMode == .openAI ? .blue : .red
    }
}

// MARK: - Photo thumbnail strip

private struct PhotoThumbnailStrip: View {
    @Binding var photos: [String]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.offset) { idx, base64 in
                    ZStack(alignment: .topTrailing) {
                        if let image = base64ToImage(base64) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipped()
                                .cornerRadius(6)
                        }
                        Button { onRemove(idx) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(.systemGray6))
    }

    private func base64ToImage(_ base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Helpers

private func buildChatHistoryJson(_ messages: [ChatMessage], max: Int = 20, isLoadMore: Bool = false, hasMore: Bool = true) -> String {
    let maxContentLength = 2000
    let recent = Array(messages.suffix(max))
    var obj: [String: Any] = ["type": "chat_history"]
    if isLoadMore { obj["isLoadMore"] = true; obj["hasMore"] = hasMore }
    let arr = recent.map { msg -> [String: Any] in
        let content = msg.content.count > maxContentLength
            ? String(msg.content.prefix(maxContentLength)) + "..."
            : msg.content
        return ["id": msg.id, "role": msg.role, "content": content, "timestamp": msg.timestamp]
    }
    obj["messages"] = arr
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let json = String(data: data, encoding: .utf8) else { return "{}" }
    return json
}

extension GlassesConnectionManager.ConnectionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

extension String {
    var escaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
