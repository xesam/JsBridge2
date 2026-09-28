package io.github.xesam.android.bridge.security.session;


public interface SessionStore {
    SessionRecord create(String origin, String pageInstanceId, long ttlMs);

    SessionRecord find(String sessionId);

    void clearByPageInstance(String pageInstanceId);

    void clearAll();
}
