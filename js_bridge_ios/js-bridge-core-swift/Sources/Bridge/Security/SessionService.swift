import Foundation

public struct SessionRecord: Equatable {
    public let sessionId: String
    public let origin: String
    public let pageInstanceId: String
    public let capabilities: Set<String>
    public let expiresAtMs: Int64

    public func isExpired(nowMs: Int64) -> Bool {
        nowMs >= expiresAtMs
    }
}

public final class SessionService: SessionServiceProtocol {
    private var sessions: [String: SessionRecord] = [:]

    public init() {}

    public func issue(
        context: TrustedPageContext,
        capabilities: Set<String>,
        ttlMs: Int64
    ) -> SessionRecord {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let record = SessionRecord(
            sessionId: UUID().uuidString,
            origin: context.origin,
            pageInstanceId: context.pageInstanceId,
            capabilities: capabilities,
            expiresAtMs: nowMs + ttlMs
        )
        sessions[record.sessionId] = record
        return record
    }

    public func find(sessionId: String) -> SessionRecord? {
        guard let session = sessions[sessionId] else {
            return nil
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if session.isExpired(nowMs: nowMs) {
            sessions.removeValue(forKey: sessionId)
            return nil
        }
        return session
    }

    public func clear(pageInstanceId: String) {
        sessions = sessions.filter { $0.value.pageInstanceId != pageInstanceId }
    }

    public func clearAll() {
        sessions.removeAll()
    }
}
