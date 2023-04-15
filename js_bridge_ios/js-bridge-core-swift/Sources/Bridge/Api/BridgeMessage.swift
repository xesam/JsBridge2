import Foundation

public enum BridgeMessageKind: String, Codable {
    case request
    case response
    case event
}

public enum JSONValue: Codable, Equatable {
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

    public static func fromAny(_ value: Any?) -> JSONValue? {
        guard let value else { return .null }
        if value is NSNull { return .null }
        if let value = value as? JSONValue { return value }
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? NSNumber {
            if String(cString: value.objCType) == "c" {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        }
        if let value = value as? [String: Any] {
            var object: [String: JSONValue] = [:]
            for (key, anyValue) in value {
                object[key] = JSONValue.fromAny(anyValue) ?? .null
            }
            return .object(object)
        }
        if let value = value as? [Any] {
            return .array(value.map { JSONValue.fromAny($0) ?? .null })
        }
        return nil
    }

    public func toAny() -> Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.toAny() }
        case .array(let value):
            return value.map { $0.toAny() }
        case .null:
            return NSNull()
        }
    }
}

public struct BridgeMessage: Codable, Equatable {
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

    public static func fromJsonString(_ raw: String) -> BridgeMessage? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BridgeMessage.self, from: data)
    }

    public func toJsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
