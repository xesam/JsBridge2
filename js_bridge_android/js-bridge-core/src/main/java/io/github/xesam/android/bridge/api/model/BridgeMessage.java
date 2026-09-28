package io.github.xesam.android.bridge.api.model;


import org.json.JSONException;
import org.json.JSONObject;

import java.util.UUID;

public final class BridgeMessage {
    public static final String KIND_REQUEST = "request";
    public static final String KIND_RESPONSE = "response";
    public static final String KIND_EVENT = "event";

    private String id;
    private String sessionId;
    private String kind;
    private String method;
    private long ts;
    private long timeoutMs;
    private boolean keep;
    private Object payload;
    private String reqId;
    private Boolean done;
    private Boolean ok;
    private Object error;
    private String scopeId;

        public static BridgeMessage fromJson(String messageJsonString) {
        BridgeMessage ret = new BridgeMessage();
        try {
            JSONObject json = new JSONObject(messageJsonString);
            Object idRaw = json.opt("id");
            if (!(idRaw instanceof String)) {
                return null;
            }
            ret.id = (String) idRaw;
            Object sessionIdRaw = json.opt("sessionId");
            if (sessionIdRaw == null) {
                ret.sessionId = "";
            } else if (sessionIdRaw instanceof String) {
                ret.sessionId = (String) sessionIdRaw;
            } else {
                return null;
            }
            Object kindRaw = json.opt("kind");
            if (!(kindRaw instanceof String)
                    || (!KIND_REQUEST.equals(kindRaw)
                        && !KIND_RESPONSE.equals(kindRaw)
                        && !KIND_EVENT.equals(kindRaw))) {
                return null;
            }
            ret.kind = (String) kindRaw;
            Object methodRaw = json.opt("method");
            if (!(methodRaw instanceof String)) {
                return null;
            }
            ret.method = (String) methodRaw;
            ret.ts = json.optLong("ts", 0L);
            ret.timeoutMs = json.optLong("timeoutMs", 0L);
            ret.keep = json.optBoolean("keep", false);
            ret.payload = json.has("payload") ? json.opt("payload") : null;
            ret.reqId = json.optString("reqId", null);
            if (json.has("done") && !json.isNull("done")) {
                ret.done = json.optBoolean("done");
            }
            if (json.has("ok") && !json.isNull("ok")) {
                ret.ok = json.optBoolean("ok");
            }
            ret.error = json.has("error") ? json.opt("error") : null;
            ret.scopeId = json.optString("scopeId", null);
        } catch (JSONException e) {
            return null;
        }
        return ret;
    }

    public static BridgeMessage createSuccessResponse(BridgeMessage requestMessage, Object payload, boolean done) {
        BridgeMessage response = createBaseResponse(requestMessage);
        response.done = done;
        response.ok = true;
        response.payload = payload;
        response.error = null;
        return response;
    }

    public static BridgeMessage createFailResponse(BridgeMessage requestMessage, Object error) {
        BridgeMessage response = createBaseResponse(requestMessage);
        response.done = true;
        response.ok = false;
        response.payload = null;
        response.error = BridgeError.normalize(error).toJsonObject();
        return response;
    }

    public static BridgeMessage createEvent(String method, Object payload) {
        BridgeMessage event = new BridgeMessage();
        event.id = UUID.randomUUID().toString();
        event.sessionId = "";
        event.kind = KIND_EVENT;
        event.method = method;
        event.ts = System.currentTimeMillis();
        event.payload = payload;
        event.reqId = null;
        event.done = null;
        event.ok = null;
        event.error = null;
        return event;
    }

    private static BridgeMessage createBaseResponse(BridgeMessage requestMessage) {
        BridgeMessage response = new BridgeMessage();
        response.id = UUID.randomUUID().toString();
        response.reqId = requestMessage.id;
        response.sessionId = requestMessage.sessionId;
        response.kind = KIND_RESPONSE;
        response.method = requestMessage.method;
        response.ts = System.currentTimeMillis();
        response.timeoutMs = requestMessage.timeoutMs;
        response.keep = requestMessage.keep;
        return response;
    }

    public boolean isRequest() {
        return KIND_REQUEST.equals(kind);
    }

    public String getMethod() {
        return method;
    }

    public String getId() {
        return id;
    }

    public String getSessionId() {
        return sessionId;
    }

    public String getScopeId() {
        return scopeId;
    }

    public Object getPayload() {
        return payload;
    }

    public String toJsonString() {
        return toJsonObject().toString();
    }

        @Override
    public String toString() {
        return toJsonString();
    }

    private JSONObject toJsonObject() {
        JSONObject json = new JSONObject();
        try {
            json.put("id", id);
            json.put("sessionId", sessionId);
            json.put("kind", kind);
            json.put("method", method);
            json.put("ts", ts);
            json.put("timeoutMs", timeoutMs);
            json.put("keep", keep);
            if (payload == null) {
                json.put("payload", JSONObject.NULL);
            } else {
                json.put("payload", payload);
            }
            if (reqId == null) {
                json.put("reqId", JSONObject.NULL);
            } else {
                json.put("reqId", reqId);
            }
            if (done == null) {
                json.put("done", JSONObject.NULL);
            } else {
                json.put("done", done);
            }
            if (ok == null) {
                json.put("ok", JSONObject.NULL);
            } else {
                json.put("ok", ok);
            }
            if (error == null) {
                json.put("error", JSONObject.NULL);
            } else {
                json.put("error", error);
            }
            if (scopeId != null) {
                json.put("scopeId", scopeId);
            }
        } catch (JSONException e) {
            throw new RuntimeException(e);
        }
        return json;
    }
}
