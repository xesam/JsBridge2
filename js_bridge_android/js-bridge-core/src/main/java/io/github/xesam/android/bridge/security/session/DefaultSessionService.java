package io.github.xesam.android.bridge.security.session;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.Set;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;

public final class DefaultSessionService implements SessionService {
    private final CapabilitySessionStore sessionStore;
    private final Set<String> defaultCapabilities;
    private final long sessionTtlMs;
    private final String policyVersion;

    public DefaultSessionService(
            CapabilitySessionStore sessionStore,
            Set<String> defaultCapabilities,
            long sessionTtlMs,
            String policyVersion) {
        this.sessionStore = sessionStore;
        this.defaultCapabilities = new HashSet<>(defaultCapabilities);
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
                defaultCapabilities,
                sessionTtlMs);
        JSONObject payload = new JSONObject();
        try {
            payload.put("sessionId", sessionRecord.getSessionId());
            payload.put("capabilities", new JSONArray(defaultCapabilities));
            payload.put("sessionTtlMs", sessionTtlMs);
            payload.put("policyVersion", policyVersion);
            payload.put("origin", trustedPageContext.getOrigin());
            payload.put("accepted", true);
        } catch (JSONException ignored) {
        }
        return new HandshakeResult(sessionRecord, payload);
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
