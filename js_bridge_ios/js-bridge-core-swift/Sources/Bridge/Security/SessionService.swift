import Foundation

public struct SessionRecord: Equatable {
    public let sessionId: String
    public let origin: String
    public let pageInstanceId: String
    public let expiresAtMs: Int64

    public func isExpired(nowMs: Int64) -> Bool {
        // expiresAtMs == -1 为"永不过期"哨兵（docs/03 §10：ttlMs == 0 永不失效，C60）
        expiresAtMs > 0 && nowMs >= expiresAtMs
    }
}

public final class SessionService {
    private var sessions: [String: SessionRecord] = [:]
    private let clock: () -> Int64

    /// - Parameter clock: 当前毫秒时间戳的取值器；默认取系统墙钟，测试可注入假时钟
    ///   以确定性地推进 TTL（验收锚点 C56）。
    public init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    /// 存储记录数。内部观察口，仅供测试断言「签发时顺带清扫」的时机
    /// （若仅在 find 时惰性移除，过期后签发不改变计数）。
    var sessionCount: Int { sessions.count }

    public func issue(
        context: TrustedPageContext,
        ttlMs: Int64
    ) -> SessionRecord {
        let nowMs = clock()
        // 过期清扫（docs/03 §10，四端统一）：签发时顺带清扫存储中已过期的记录，
        // 防止长期运行进程中过期而不再被查询的记录无界累积（验收锚点 C56）；
        // 同时移除同 pageInstanceId 的既有记录——重复握手刷新而非并存（验收锚点 C61）
        sessions = sessions.filter {
            !$0.value.isExpired(nowMs: nowMs) && $0.value.pageInstanceId != context.pageInstanceId
        }
        let record = SessionRecord(
            sessionId: UUID().uuidString,
            origin: context.origin,
            pageInstanceId: context.pageInstanceId,
            // docs/03 §10 三态（C60）：ttl > 0 有限期；ttl == 0 永不过期（-1 哨兵）；ttl < 0 测试驱动用立即过期
            expiresAtMs: ttlMs > 0 ? nowMs + ttlMs : (ttlMs == 0 ? -1 : nowMs)
        )
        sessions[record.sessionId] = record
        return record
    }

    public func find(sessionId: String) -> SessionRecord? {
        guard let session = sessions[sessionId] else {
            return nil
        }
        if session.isExpired(nowMs: clock()) {
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
