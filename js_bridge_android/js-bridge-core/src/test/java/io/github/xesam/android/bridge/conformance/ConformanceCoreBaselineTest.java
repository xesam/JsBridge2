package io.github.xesam.android.bridge.conformance;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.extensions.lifecycle.LifecycleExtension;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.security.context.PageContextProvider;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.security.policy.PolicyDecision;
import io.github.xesam.android.bridge.security.policy.PolicyInput;
import io.github.xesam.android.bridge.security.policy.PolicyRule;
import io.github.xesam.android.bridge.core.transport.BridgeTransport;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

public class ConformanceCoreBaselineTest {

    @Test
    public void C01_requestBeforeHandshake_deniedByGate() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetForNewPage();
        fixture.transport.deliver(requestJson("r1", "echo", "", "{}"));

        assertEquals("E_POLICY_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C02_handshake_returnsSessionPayload() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetForNewPage();

        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        JSONObject response = parse(fixture.transport.lastSent());
        JSONObject payload = response.optJSONObject("payload");

        assertTrue(response.optBoolean("ok"));
        assertNotNull(payload);
        assertTrue(payload.optString("sessionId").length() > 0);
        assertTrue(payload.has("capabilities"));
        assertTrue(payload.has("sessionTtlMs"));
        assertTrue(payload.has("policyVersion"));
        assertEquals("file://", payload.optString("origin"));
        assertTrue(payload.optBoolean("accepted"));
    }

    @Test
    public void C03_methodNotAllowed_denied() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "notAllowed", sessionId, "{}"));
        assertEquals("E_METHOD_NOT_ALLOWED", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C04_originNotAllowed_denied() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("https://trusted.example")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                new HashSet<>(Arrays.asList("echo")),
                new ArrayList<>());
        fixture.bridge.resetForNewPage();
        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        assertEquals("E_ORIGIN_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C05_validHandshakeThenValidRequest_success() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{\"k\":\"v\"}"));
        JSONObject response = parse(fixture.transport.lastSent());

        assertTrue(response.optBoolean("ok"));
        assertEquals("echo", response.optString("method"));
    }

    @Test
    public void C06_missingSessionAfterReady_denied() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        fixture.bridge.resetForNewPage();
        fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", "", "{}"));
        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C07_sessionOriginMismatch_denied() {
        MutableContextProvider contextProvider = new MutableContextProvider("file://", null);
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://", "https://trusted.example")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                new HashSet<>(Arrays.asList("echo")),
                new ArrayList<>(),
                contextProvider);
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        contextProvider.setOrigin("https://trusted.example");
        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));

        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C08_sessionPageMismatch_denied() {
        MutableContextProvider contextProvider = new MutableContextProvider("file://", "fixed-page-a");
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                new HashSet<>(Arrays.asList("echo")),
                new ArrayList<>(),
                contextProvider);
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        contextProvider.setForcedPageInstanceId("fixed-page-b");
        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));

        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C09_capabilityDenied_denied() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "admin")),
                new HashSet<>(Arrays.asList("echo")),
                new ArrayList<>());
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "admin", sessionId, "{}"));
        assertEquals("E_CAPABILITY_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C10_methodNotFound_denied() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "missing")),
                new HashSet<>(Arrays.asList("missing")),
                new ArrayList<>());
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "missing", sessionId, "{}"));
        assertEquals("E_METHOD_NOT_FOUND", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C11_handlerThrows_normalizedToInternal() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> {
            throw new RuntimeException("boom");
        });
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));
        assertEquals("E_INTERNAL", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C12_extraPolicyDeny_takesEffect() {
        List<PolicyRule> extraPolicies = Arrays.asList(new PolicyRule() {
            @Override
            public PolicyDecision evaluate(PolicyInput input) {
                if ("echo".equals(input.getMessage().getMethod())) {
                    return PolicyDecision.deny(name(), new BridgeError("E_TEST_DENY", "blocked"));
                }
                return PolicyDecision.allow();
            }

            @Override
            public String name() {
                return "ExtraDeny";
            }
        });
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                new HashSet<>(Arrays.asList("echo")),
                extraPolicies);
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));
        assertEquals("E_TEST_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C13_streamingResponse_emitsDoneFalseThenDoneTrue() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "stream")),
                new HashSet<>(Arrays.asList("stream")),
                new ArrayList<>());
        fixture.bridge.registerNativeHandler("stream", (data, callback) -> {
            callback.success(jsonOf("tick", 1), false);
            callback.success(jsonOf("tick", 2), true);
        });
        fixture.bridge.resetForNewPage();
        String sessionId = fixture.handshake();
        int before = fixture.transport.sentCount();

        fixture.transport.deliver(requestJson("r1", "stream", sessionId, "{}"));

        assertEquals(before + 2, fixture.transport.sentCount());
        JSONObject first = parse(fixture.transport.sentAt(before));
        JSONObject second = parse(fixture.transport.sentAt(before + 1));
        assertFalse(first.optBoolean("done", true));
        assertTrue(second.optBoolean("done", false));
    }

    @Test
    public void C17_sendFailure_observableAndPostEventReturnsFalse() {
        Fixture fixture = new Fixture();
        fixture.transport.setSendEnabled(false);
        fixture.bridge.resetForNewPage();
        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        assertTrue(fixture.bridge.isReady());
        assertFalse(fixture.bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, "{}"));
    }

    @Test
    public void C18_resetForNewPageRotatesContextAndOldSessionInvalid() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        fixture.bridge.resetForNewPage();
        String oldSessionId = fixture.handshake();

        fixture.bridge.resetForNewPage();
        fixture.handshake();
        fixture.transport.deliver(requestJson("r1", "echo", oldSessionId, "{}"));

        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C28_lifecycleEventsBeforeReady_queuedAndFlushedInOrder() {
        Fixture fixture = new Fixture();
        LifecycleExtension lifecycle = new LifecycleExtension(fixture.bridge);
        fixture.bridge.resetForNewPage();

        lifecycle.onHostEvent("created");
        lifecycle.onHostEvent("started");
        lifecycle.onHostEvent("resumed");
        assertEquals(0, lifecycleEvents(fixture).size());

        fixture.handshake();

        List<JSONObject> events = lifecycleEvents(fixture);
        assertEquals(3, events.size());
        assertEquals("created", events.get(0).optString("state"));
        assertEquals("started", events.get(1).optString("state"));
        assertEquals("resumed", events.get(2).optString("state"));
        assertEquals(1, events.get(0).optInt("seq"));
        assertEquals(2, events.get(1).optInt("seq"));
        assertEquals(3, events.get(2).optInt("seq"));
    }

    @Test
    public void C29_lifecycleQueueOverflow_dropsOldestKeepsSeq() {
        Fixture fixture = new Fixture();
        LifecycleExtension lifecycle = new LifecycleExtension(fixture.bridge, 2);
        fixture.bridge.resetForNewPage();

        lifecycle.onHostEvent("created");   // seq=1，将被丢弃
        lifecycle.onHostEvent("started");   // seq=2
        lifecycle.onHostEvent("resumed");   // seq=3

        fixture.handshake();

        List<JSONObject> events = lifecycleEvents(fixture);
        assertEquals(2, events.size());
        assertEquals("started", events.get(0).optString("state"));
        assertEquals(2, events.get(0).optInt("seq"));
        assertEquals("resumed", events.get(1).optString("state"));
        assertEquals(3, events.get(1).optInt("seq"));
    }

    @Test
    public void C30_lifecycleAfterReady_sentImmediatelyWithExactPayload() {
        Fixture fixture = new Fixture();
        LifecycleExtension lifecycle = new LifecycleExtension(fixture.bridge);
        fixture.bridge.resetForNewPage();
        fixture.handshake();

        lifecycle.onHostEvent("resumed");

        List<JSONObject> events = lifecycleEvents(fixture);
        assertEquals(1, events.size());
        JSONObject payload = events.get(0);
        assertEquals("resumed", payload.optString("state"));
        assertEquals(1, payload.optInt("seq"));
        assertEquals(2, payload.length()); // payload 恰为 {state, seq}
    }

    private static List<JSONObject> lifecycleEvents(Fixture fixture) {
        List<JSONObject> events = new ArrayList<>();
        for (String sent : fixture.transport.sentMessages()) {
            JSONObject message = parse(sent);
            if (BridgeApiContract.METHOD_LIFECYCLE.equals(message.optString("method"))
                    && "event".equals(message.optString("kind"))) {
                events.add(message.optJSONObject("payload"));
            }
        }
        return events;
    }

    private static String requestJson(String id, String method, String sessionId, String payloadJson) {
        return "{\"id\":\"" + id + "\","
                + "\"kind\":\"request\","
                + "\"method\":\"" + method + "\","
                + "\"sessionId\":\"" + sessionId + "\","
                + "\"payload\":" + payloadJson + "}";
    }

    private static JSONObject parse(String json) {
        try {
            return new JSONObject(json);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static JSONObject jsonOf(String key, Object value) {
        JSONObject jsonObject = new JSONObject();
        try {
            jsonObject.put(key, value);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        return jsonObject;
    }

    private static String errorCode(String responseJson) {
        JSONObject response = parse(responseJson);
        JSONObject error = response.optJSONObject("error");
        if (error == null) {
            return "";
        }
        return error.optString("code");
    }

    private static final class Fixture {
        final FakeBridgeTransport transport = new FakeBridgeTransport();
        final JsBridge bridge;

        Fixture() {
            this(new HashSet<>(Arrays.asList("file://")),
                    new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo", "forbidden")),
                    new HashSet<>(Arrays.asList("echo")),
                    new ArrayList<>());
        }

        Fixture(
                HashSet<String> allowedOrigins,
                HashSet<String> allowedMethods,
                HashSet<String> capabilities,
                List<PolicyRule> extraPolicies) {
            this(allowedOrigins, allowedMethods, capabilities, extraPolicies, new MutableContextProvider("file://", null));
        }

        Fixture(
                HashSet<String> allowedOrigins,
                HashSet<String> allowedMethods,
                HashSet<String> capabilities,
                List<PolicyRule> extraPolicies,
                PageContextProvider pageContextProvider) {
            JsBridge.SecurityConfig securityConfig = JsBridge.SecurityConfig.secure()
                    .allowedOrigins(allowedOrigins)
                    .methodWhitelist(allowedMethods)
                    .defaultCapabilities(capabilities)
                    .extraPolicies(extraPolicies);
            bridge = new JsBridge(
                    transport,
                    pageContextProvider,
                    new JsBridge.KernelConfig(),
                    securityConfig);
            bridge.resetTransport();
        }

        String handshake() {
            transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
            JSONObject response = parse(transport.lastSent());
            JSONObject payload = response.optJSONObject("payload");
            if (payload == null) {
                return "";
            }
            return payload.optString("sessionId");
        }
    }

    private static final class MutableContextProvider implements PageContextProvider {
        private String origin;
        private String forcedPageInstanceId;

        MutableContextProvider(String origin, String forcedPageInstanceId) {
            this.origin = origin;
            this.forcedPageInstanceId = forcedPageInstanceId;
        }

        @Override
        public TrustedPageContext createContext(io.github.xesam.android.bridge.api.model.BridgeMessage bridgeMessage, String pageInstanceId) {
            String page = forcedPageInstanceId == null ? pageInstanceId : forcedPageInstanceId;
            return new TrustedPageContext(origin, page);
        }

        void setOrigin(String origin) {
            this.origin = origin;
        }

        void setForcedPageInstanceId(String forcedPageInstanceId) {
            this.forcedPageInstanceId = forcedPageInstanceId;
        }
    }

    private static final class FakeBridgeTransport implements BridgeTransport {
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

        void deliver(String messageJson) {
            if (listener != null) {
                listener.onMessage(messageJson);
            }
        }

        String lastSent() {
            if (sent.isEmpty()) {
                return null;
            }
            return sent.get(sent.size() - 1);
        }

        int sentCount() {
            return sent.size();
        }

        String sentAt(int index) {
            return sent.get(index);
        }

        void setSendEnabled(boolean sendEnabled) {
            this.sendEnabled = sendEnabled;
        }

        List<String> sentMessages() {
            return new ArrayList<>(sent);
        }
    }
}
