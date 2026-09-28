package io.github.xesam.android.bridge;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.core.transport.BridgeTransport;

/**
 * 单元测试共享基建：FakeBridgeTransport + 请求构造 / 响应解析助手。
 * 供 JsBridgeTest / ConformanceCoreBaselineTest / UnifiedHandlerApiTest 共用，
 * 避免「同一验证逻辑多套副本」的漂移（此前三处各维护一份等价实现）。
 */
public final class BridgeTestSupport {

    private BridgeTestSupport() {
    }

    public static String requestJson(String id, String method, String sessionId, String payloadJson) {
        return "{\"id\":\"" + id + "\","
                + "\"kind\":\"request\","
                + "\"method\":\"" + method + "\","
                + "\"sessionId\":\"" + sessionId + "\","
                + "\"payload\":" + payloadJson + "}";
    }

    public static String requestJson(String id, String method, String sessionId, String payloadJson, boolean keep) {
        return "{\"id\":\"" + id + "\","
                + "\"kind\":\"request\","
                + "\"method\":\"" + method + "\","
                + "\"sessionId\":\"" + sessionId + "\","
                + "\"keep\":" + keep + ","
                + "\"payload\":" + payloadJson + "}";
    }

    public static JSONObject parse(String json) {
        try {
            return new JSONObject(json);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    public static JSONObject jsonOf(String key, Object value) {
        try {
            return new JSONObject().put(key, value);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /** 响应帧 error.code；无 error 时返回 ""。 */
    public static String errorCode(String responseJson) {
        return errorCode(parse(responseJson));
    }

    /** 响应帧 error.code；无 error 时返回 ""（接受已解析对象，避免同帧重复解析）。 */
    public static String errorCode(JSONObject response) {
        JSONObject error = response.optJSONObject("error");
        if (error == null) {
            return "";
        }
        return error.optString("code");
    }

    /** 投递 bridge.handshake 并解析响应 payload.sessionId（"握手 → sessionId"惯用式的共享形态，
     * 三测试文件统一走此实现）；无 payload（握手被拒）时返回 ""。 */
    public static String handshakeSessionId(FakeBridgeTransport transport) {
        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        JSONObject payload = parse(transport.lastSent()).optJSONObject("payload");
        return payload == null ? "" : payload.optString("sessionId");
    }

    public static final class FakeBridgeTransport implements BridgeTransport {
        private Listener listener;
        private boolean sendEnabled = true;
        private final List<String> sent = new ArrayList<>();

        @Override
        public void bind(Listener listener) {
            this.listener = listener;
        }

        @Override
        public boolean send(String messageJson) {
            if (!sendEnabled) {
                return false;
            }
            sent.add(messageJson);
            return true;
        }

        @Override
        public void close() {
            listener = null;
        }

        public void deliver(String messageJson) {
            if (listener != null) {
                listener.onMessage(messageJson);
            }
        }

        public String lastSent() {
            if (sent.isEmpty()) {
                return null;
            }
            return sent.get(sent.size() - 1);
        }

        public int sentCount() {
            return sent.size();
        }

        public String sentAt(int index) {
            return sent.get(index);
        }

        public List<String> sentMessages() {
            return new ArrayList<>(sent);
        }

        public void setSendEnabled(boolean sendEnabled) {
            this.sendEnabled = sendEnabled;
        }

        /** 所有 reqId == requestId 的响应帧，按发送顺序。 */
        public List<JSONObject> framesForReqId(String requestId) {
            List<JSONObject> result = new ArrayList<>();
            for (String json : sent) {
                JSONObject obj = parse(json);
                if (requestId.equals(obj.optString("reqId"))) {
                    result.add(obj);
                }
            }
            return result;
        }
    }
}
