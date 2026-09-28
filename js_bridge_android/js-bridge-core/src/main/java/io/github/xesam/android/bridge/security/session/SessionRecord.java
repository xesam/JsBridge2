package io.github.xesam.android.bridge.security.session;

public final class SessionRecord {
    private final String sessionId;
    private final String origin;
    private final String pageInstanceId;
    private final long expiresAtMs;

    public SessionRecord(String sessionId, String origin, String pageInstanceId, long expiresAtMs) {
        this.sessionId = sessionId;
        this.origin = origin;
        this.pageInstanceId = pageInstanceId;
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

    public boolean isExpired(long nowMs) {
        // expiresAtMs <= 0 时永不过期（-1 为哨兵值；docs/03 §10：ttlMs == 0 永不失效，C60）
        return expiresAtMs > 0 && nowMs >= expiresAtMs;
    }
}
