import Foundation

// MARK: - OpenClaw Gateway Protocol

struct OpenClawRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String
    let params: [String: AnyCodable]?
}

struct OpenClawResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: [String: AnyCodable]?
    let error: [String: AnyCodable]?
}

struct OpenClawEvent: Decodable {
    let type: String
    let event: String
    let payload: [String: AnyCodable]?
    let seq: Int64?
    let stateVersion: Int64?
}

enum OpenClawMethods {
    static let connect = "connect"
    static let chatSend = "chat.send"
    static let channelSend = "channel.send"
    static let channelList = "channel.list"
    static let sessionCreate = "session.create"
    static let sessionReset = "sessions.reset"
    static let sessionList = "sessions.list"
    static let sessionRun = "session.run"
    static let chatHistory = "chat.history"
    static let configGet = "config.get"
    static let systemPresence = "system-presence"
}

enum OpenClawEvents {
    static let connectChallenge = "connect.challenge"
    static let agent = "agent"
    static let chat = "chat"
    static let presence = "presence"
    static let heartbeat = "heartbeat"
}

// MARK: - Phone → Glasses Messages

struct ChatMessage: Codable, Identifiable {
    let type: String
    let id: String
    let role: String
    let content: String
    let timestamp: Int64

    init(id: String, role: String, content: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.type = "chat_message"
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct AgentThinking: Codable {
    let type: String = "agent_thinking"
    let id: String
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct ChatStream: Codable {
    let type: String = "chat_stream"
    let id: String
    let role: String = "assistant"
    let chunk: String
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct ChatStreamEnd: Codable {
    let type: String = "chat_stream_end"
    let id: String
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct ConnectionUpdate: Codable {
    let type: String = "connection_update"
    let connected: Bool
    let sessionId: String?
    let sessionName: String?
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct SessionListUpdate: Codable {
    let type: String = "session_list"
    let sessions: [SessionInfo]
    let currentSessionKey: String?
    let unreadSessionKeys: [String]
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct SessionInfo: Codable, Identifiable {
    let key: String
    let displayName: String?
    let label: String?
    let derivedTitle: String?
    let updatedAt: Int64?
    let kind: String?

    var id: String { key }
    var name: String { label ?? displayName ?? derivedTitle ?? key }
}

// MARK: - Glasses → Phone Messages

struct UserInput: Codable {
    let type: String = "user_input"
    let text: String
    let imageBase64: String?
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct SessionAction: Codable {
    let type: String
    let sessionKey: String?
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct SlashCommand: Codable {
    let type: String = "slash_command"
    let command: String
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct RequestMoreHistory: Codable {
    let type: String = "request_more_history"
    let beforeMessageId: String?
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

// MARK: - Wake Signal Protocol

struct WakeSignal: Codable {
    let type: String = "wake_signal"
    let reason: String
    let bufferedCount: Int
    let messageId: String?
    let timestamp: Int64

    init(reason: String, bufferedCount: Int = 0, messageId: String? = nil) {
        self.reason = reason
        self.bufferedCount = bufferedCount
        self.messageId = messageId
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    }

    enum Reason {
        static let streamContent = "stream_content"
        static let newMessage = "new_message"
        static let cronMessage = "cron_message"
    }

    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct WakeAck: Codable {
    let type: String = "wake_ack"
    let ready: Bool
    let timestamp: Int64
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

// MARK: - TTS State Protocol

struct TtsToggle: Codable {
    let type: String = "tts_toggle"
    let enabled: Bool
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

struct TtsState: Codable {
    let type: String = "tts_state"
    let enabled: Bool
    let voiceName: String?
    func toJson() -> String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

// MARK: - Utility

func extractMessageType(from json: String) -> String? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["type"] as? String
}

// MARK: - AnyCodable helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let int64 = try? container.decode(Int64.self) { value = int64 }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyCodable].self) { value = array.map(\.value) }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict.mapValues(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let int64 as Int64: try container.encode(int64)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}

// MARK: - JSON helpers

extension Dictionary where Key == String, Value == AnyCodable {
    func string(_ key: String) -> String? { value[key] as? String }
    func bool(_ key: String) -> Bool? { value[key] as? Bool }
    func int64(_ key: String) -> Int64? {
        if let v = value[key] as? Int64 { return v }
        if let v = value[key] as? Int { return Int64(v) }
        if let v = value[key] as? Double { return Int64(v) }
        return nil
    }
    func array(_ key: String) -> [[String: Any]]? { value[key] as? [[String: Any]] }
    var value: [String: Any] { self.mapValues(\.value) }
}
