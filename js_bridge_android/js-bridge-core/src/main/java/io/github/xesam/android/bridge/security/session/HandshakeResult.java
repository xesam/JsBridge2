package io.github.xesam.android.bridge.security.session;

import org.json.JSONObject;

public final class HandshakeResult {
    private final SessionRecord sessionRecord;
    private final JSONObject payload;

    public HandshakeResult(SessionRecord sessionRecord, JSONObject payload) {
        this.sessionRecord = sessionRecord;
        this.payload = payload;
    }

    public SessionRecord getSessionRecord() {
        return sessionRecord;
    }

    public JSONObject getPayload() {
        return payload;
    }
}
