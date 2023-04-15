package io.github.xesam.android.bridge.security.session;


import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public final class InMemoryCapabilitySessionStore implements CapabilitySessionStore {
    private final Map<String, SessionRecord> sessions = new ConcurrentHashMap<>();

    @Override
    public SessionRecord create(String origin, String pageInstanceId, Set<String> capabilities, long ttlMs) {
        long nowMs = System.currentTimeMillis();
        String sessionId = UUID.randomUUID().toString();
        SessionRecord sessionRecord = new SessionRecord(sessionId, origin, pageInstanceId, capabilities, nowMs + ttlMs);
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
