package io.github.xesam.android.bridge.security.session;

import org.json.JSONObject;

public final class HandshakeResult {
    private final JSONObject payload;

    public HandshakeResult(JSONObject payload) {
        this.payload = payload;
    }

    public JSONObject getPayload() {
        return payload;
    }
}
