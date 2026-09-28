package io.github.xesam.android.bridge.security.session;

import org.json.JSONException;
import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;

public final class DefaultSessionService implements SessionService {
    private final SessionStore sessionStore;
    private final long sessionTtlMs;
    private final String policyVersion;

    public DefaultSessionService(
            SessionStore sessionStore,
            long sessionTtlMs,
            String policyVersion) {
        this.sessionStore = sessionStore;
        this.sessionTtlMs = sessionTtlMs;
        this.policyVersion = policyVersion;
    }

    @Override
    public SessionRecord find(String sessionId) {
        return sessionStore.find(sessionId);
    }

    @Override
    public HandshakeResult issueHandshake(TrustedPageContext trustedPageContext) {
        SessionRecord sessionRecord = sessionStore.create(
                trustedPageContext.getOrigin(),
                trustedPageContext.getPageInstanceId(),
                sessionTtlMs);
        JSONObject payload = new JSONObject();
        try {
            payload.put("sessionId", sessionRecord.getSessionId());
            payload.put("sessionTtlMs", sessionTtlMs);
            payload.put("policyVersion", policyVersion);
            payload.put("origin", trustedPageContext.getOrigin());
            payload.put("accepted", true);
        } catch (JSONException ignored) {
        }
        return new HandshakeResult(payload);
    }

    @Override
    public void clearByPageInstance(String pageInstanceId) {
        sessionStore.clearByPageInstance(pageInstanceId);
    }

    @Override
    public void clearAll() {
        sessionStore.clearAll();
    }
}
