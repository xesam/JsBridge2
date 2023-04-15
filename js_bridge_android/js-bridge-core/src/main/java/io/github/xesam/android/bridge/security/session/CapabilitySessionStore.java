package io.github.xesam.android.bridge.security.session;


import java.util.Set;

public interface CapabilitySessionStore {
    SessionRecord create(String origin, String pageInstanceId, Set<String> capabilities, long ttlMs);

        SessionRecord find(String sessionId);

    void clearByPageInstance(String pageInstanceId);

    void clearAll();
}
