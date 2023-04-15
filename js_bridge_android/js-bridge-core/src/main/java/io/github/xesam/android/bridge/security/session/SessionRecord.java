package io.github.xesam.android.bridge.security.session;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

public final class SessionRecord {
    private final String sessionId;
    private final String origin;
    private final String pageInstanceId;
    private final Set<String> capabilities;
    private final long expiresAtMs;

    public SessionRecord(String sessionId, String origin, String pageInstanceId, Set<String> capabilities, long expiresAtMs) {
        this.sessionId = sessionId;
        this.origin = origin;
        this.pageInstanceId = pageInstanceId;
        this.capabilities = Collections.unmodifiableSet(new HashSet<>(capabilities));
        this.expiresAtMs = expiresAtMs;
    }

    public String getSessionId() {
        return sessionId;
    }

    public String getOrigin() {
        return origin;
    }

    public String getPageInstanceId() {
        return pageInstanceId;
    }

    public Set<String> getCapabilities() {
        return capabilities;
    }

    public long getExpiresAtMs() {
        return expiresAtMs;
    }

    public boolean isExpired(long nowMs) {
        return nowMs >= expiresAtMs;
    }
}
