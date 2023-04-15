package io.github.xesam.android.bridge.api.model;


import org.json.JSONException;
import org.json.JSONObject;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;

public class BridgeError {
    public static final class NotFound extends BridgeError {
        public NotFound(String methodName) {
            super(BridgeApiContract.ERR_METHOD_NOT_FOUND, "Method not found: " + methodName);
        }
    }

    private final String code;
    private final String message;
    private final boolean retryable;
    private final JSONObject details;

    public BridgeError(String code, String message) {
        this(code, message, false, new JSONObject());
    }

    public BridgeError(String code, String message, boolean retryable, JSONObject details) {
        this.code = code;
        this.message = message;
        this.retryable = retryable;
        this.details = details == null ? new JSONObject() : details;
    }

    public static BridgeError normalize(Object rawError) {
        if (rawError instanceof BridgeError) {
            return (BridgeError) rawError;
        }
        if (rawError instanceof Throwable) {
            String msg = ((Throwable) rawError).getMessage();
            return new BridgeError(BridgeApiContract.ERR_INTERNAL, msg == null ? "Internal error" : msg);
        }
        if (rawError instanceof JSONObject) {
            JSONObject json = (JSONObject) rawError;
            String code = json.optString("code", BridgeApiContract.ERR_INTERNAL);
            String message = json.optString("message", "Internal error");
            boolean retryable = json.optBoolean("retryable", false);
            JSONObject details = json.optJSONObject("details");
            return new BridgeError(code, message, retryable, details);
        }
        if (rawError instanceof String) {
            return new BridgeError(BridgeApiContract.ERR_INTERNAL, (String) rawError);
        }
        return new BridgeError(BridgeApiContract.ERR_INTERNAL, "Internal error");
    }

    public JSONObject toJsonObject() {
        JSONObject json = new JSONObject();
        try {
            json.put("code", code);
            json.put("message", message);
            json.put("retryable", retryable);
            json.put("details", details);
        } catch (JSONException e) {
            throw new RuntimeException(e);
        }
        return json;
    }

        @Override
    public String toString() {
        return toJsonObject().toString();
    }
}
