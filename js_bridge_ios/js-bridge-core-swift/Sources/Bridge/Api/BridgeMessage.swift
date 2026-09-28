import Foundation

public enum BridgeMessageKind: String, Codable, Sendable {
    case request
    case response
    case event
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct BridgeMessage: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var kind: BridgeMessageKind
    public var method: String
    public var ts: Int64
    public var timeoutMs: Int64
    public var keep: Bool
    public var payload: JSONValue?
    public var reqId: String?
    public var done: Bool?
    public var ok: Bool?
    public var error: BridgeError?
    public var scopeId: String?

    public init(
        id: String,
        sessionId: String = "",
        kind: BridgeMessageKind,
        method: String,
        ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        timeoutMs: Int64 = 0,
        keep: Bool = false,
        payload: JSONValue? = nil,
        reqId: String? = nil,
        done: Bool? = nil,
        ok: Bool? = nil,
        error: BridgeError? = nil,
        scopeId: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.method = method
        self.ts = ts
        self.timeoutMs = timeoutMs
        self.keep = keep
        self.payload = payload
        self.reqId = reqId
        self.done = done
        self.ok = ok
        self.error = error
        self.scopeId = scopeId
    }

    /// 自定义解码：`id`/`kind`/`method` 为必填（缺失或类型非法即丢弃整条消息）；
    /// 其余字段缺失时取与其他三端一致的默认值（协议将 `timeoutMs`/`keep` 声明为可选，
    /// v1 演进约定要求新增字段可被旧消息安全省略）。字段存在但类型不匹配时仍整条丢弃（fail-closed）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        self.kind = try container.decode(BridgeMessageKind.self, forKey: .kind)
        self.method = try container.decode(String.self, forKey: .method)
        self.ts = try container.decodeIfPresent(Int64.self, forKey: .ts) ?? 0
        self.timeoutMs = try container.decodeIfPresent(Int64.self, forKey: .timeoutMs) ?? 0
        self.keep = try container.decodeIfPresent(Bool.self, forKey: .keep) ?? false
        self.payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
        self.reqId = try container.decodeIfPresent(String.self, forKey: .reqId)
        self.done = try container.decodeIfPresent(Bool.self, forKey: .done)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        self.error = try container.decodeIfPresent(BridgeError.self, forKey: .error)
        self.scopeId = try container.decodeIfPresent(String.self, forKey: .scopeId)
    }

    public static func fromJsonString(_ raw: String) -> BridgeMessage? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BridgeMessage.self, from: data)
    }

    public func toJsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
