package io.github.xesam.android.bridge.security.session;


import java.util.Iterator;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public final class InMemorySessionStore implements SessionStore {
    private final Map<String, SessionRecord> sessions = new ConcurrentHashMap<>();

    @Override
    public SessionRecord create(String origin, String pageInstanceId, long ttlMs) {
        long nowMs = System.currentTimeMillis();
        String sessionId = UUID.randomUUID().toString();
        // docs/03 §10 三态（C60）：ttl > 0 有限期；ttl == 0 永不过期（-1 哨兵）；ttl < 0 测试驱动用立即过期
        long expiresAtMs = ttlMs > 0 ? nowMs + ttlMs : (ttlMs == 0 ? -1L : nowMs);
        // docs/03 §10 刷新语义（C61）：同 pageInstanceId 重复握手时旧 session 立即失效（刷新而非并存），
        // 异常页面循环握手不会造成同页 session 无界累积
        sessions.values().removeIf(record -> pageInstanceId.equals(record.getPageInstanceId()));
        SessionRecord sessionRecord = new SessionRecord(sessionId, origin, pageInstanceId, expiresAtMs);
        sessions.put(sessionId, sessionRecord);
        cleanup(nowMs);
        return sessionRecord;
    }

    @Override
    public SessionRecord find(String sessionId) {
        if (sessionId == null || sessionId.isEmpty()) {
            return null;
        }
        SessionRecord sessionRecord = sessions.get(sessionId);
        if (sessionRecord == null) {
            return null;
        }
        if (sessionRecord.isExpired(System.currentTimeMillis())) {
            sessions.remove(sessionId);
            return null;
        }
        return sessionRecord;
    }

    @Override
    public void clearByPageInstance(String pageInstanceId) {
        if (pageInstanceId == null || pageInstanceId.isEmpty()) {
            return;
        }
        Iterator<Map.Entry<String, SessionRecord>> iterator = sessions.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<String, SessionRecord> entry = iterator.next();
            if (pageInstanceId.equals(entry.getValue().getPageInstanceId())) {
                iterator.remove();
            }
        }
    }

    @Override
    public void clearAll() {
        sessions.clear();
    }

    /** 当前存储条数（conformance C56 观测"签发时顺带清扫过期记录"效果用）。 */
    public int size() {
        return sessions.size();
    }

    private void cleanup(long nowMs) {
        Iterator<Map.Entry<String, SessionRecord>> iterator = sessions.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<String, SessionRecord> entry = iterator.next();
            if (entry.getValue().isExpired(nowMs)) {
                iterator.remove();
            }
        }
    }
}
