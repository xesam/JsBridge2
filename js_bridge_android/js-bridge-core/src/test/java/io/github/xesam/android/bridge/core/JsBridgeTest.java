package io.github.xesam.android.bridge.core;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;

import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
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

public class JsBridgeTest {

    @Test
    public void requestBeforeHandshake_rejectedByGate() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.resetForNewPage();

        transport.deliver(requestJson("r1", "echo", "", "{\"k\":\"v\"}"));

        String response = transport.lastSent();
        assertNotNull(response);
        assertTrue(response.contains("\"ok\":false"));
        assertTrue(response.contains("\"code\":\"E_POLICY_DENY\""));
    }

    @Test
    public void handshakeThenHandlerRequest_successResponse() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        bridge.resetForNewPage();

        bridge.addReadyListener(() -> {
        });
        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        String handshakeResponse = transport.lastSent();
        String sessionId = extractStringField(handshakeResponse, "sessionId");
        assertNotNull(sessionId);

        transport.deliver(requestJson("r2", "echo", sessionId, "{\"ok\":1}"));
        String response = transport.lastSent();
        assertTrue(response.contains("\"ok\":true"));
        assertTrue(response.contains("\"method\":\"echo\""));
        assertTrue(response.contains("\"payload\":{\"ok\":1}"));
    }

    @Test
    public void extraPolicy_canDenyAfterBaselineRules() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        List<PolicyRule> extraPolicies = Arrays.asList(new PolicyRule() {
            @Override
            public PolicyDecision evaluate(PolicyInput input) {
                if ("echo".equals(input.getMessage().getMethod())) {
                    return PolicyDecision.deny(name(), new BridgeError("E_TEST_DENY", "blocked by extra policy"));
                }
                return PolicyDecision.allow();
            }

            @Override
            public String name() {
                return "TestDenyPolicy";
            }
        });
        JsBridge bridge = newBridge(transport, extraPolicies);
        bridge.registerNativeHandler("echo", (data, callback) -> callback.success(data));
        bridge.resetForNewPage();

        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        String sessionId = extractStringField(transport.lastSent(), "sessionId");
        assertNotNull(sessionId);

        transport.deliver(requestJson("r2", "echo", sessionId, "{}"));
        String response = transport.lastSent();
        assertTrue(response.contains("\"ok\":false"));
        assertTrue(response.contains("\"code\":\"E_TEST_DENY\""));
    }

    @Test
    public void handlerThrows_returnsInternalErrorResponse() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.registerNativeHandler("echo", (data, callback) -> {
            throw new RuntimeException("boom");
        });
        bridge.resetForNewPage();

        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        String sessionId = extractStringField(transport.lastSent(), "sessionId");
        assertNotNull(sessionId);

        transport.deliver(requestJson("r2", "echo", sessionId, "{\"ok\":1}"));
        String response = transport.lastSent();
        assertNotNull(response);
        assertTrue(response.contains("\"ok\":false"));
        assertTrue(response.contains("\"code\":\"E_INTERNAL\""));
        assertTrue(response.contains("\"message\":\"boom\""));
    }

    @Test
    public void sendFailure_handshakeKeepsReadyAndPostEventReturnsFalse() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        transport.setSendEnabled(false);
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.resetForNewPage();

        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        assertTrue(bridge.isReady());
        assertEquals(0, transport.sentCount());
        assertFalse(bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, "{\"state\":\"resumed\"}"));
    }

    @Test
    public void defaultConfig_isReadyImmediatelyAfterBindPage() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                new JsBridge.KernelConfig(),
                new JsBridge.SecurityConfig());
        bridge.resetForNewPage();
        assertTrue(bridge.isReady());
    }

    @Test
    public void defaultConfig_handlerDispatchedWithoutHandshake() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                new JsBridge.KernelConfig(),
                new JsBridge.SecurityConfig());
        bridge.registerNativeHandler("echo", (data, callback) -> callback.success("ok"));
        bridge.resetTransport();
        bridge.resetForNewPage();

        transport.deliver(requestJson("r1", "echo", "", "{}"));

        String response = transport.lastSent();
        assertNotNull(response);
        assertTrue(response.contains("\"ok\":true"));
        assertTrue(response.contains("\"method\":\"echo\""));
        assertTrue(response.contains("\"reqId\":\"r1\""));
    }

    @Test
    public void defaultConfig_postEventImmediatelyAvailable() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                new JsBridge.KernelConfig(),
                new JsBridge.SecurityConfig());
        bridge.resetForNewPage();

        boolean sent = bridge.postEvent("runtime.state", "{\"state\":\"active\"}");

        assertTrue(sent);
        String lastMessage = transport.lastSent();
        assertNotNull(lastMessage);
        assertTrue(lastMessage.contains("\"kind\":\"event\""));
        assertTrue(lastMessage.contains("\"method\":\"runtime.state\""));
    }

    @Test
    public void secure_withWildcardOrigins_throws() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge.SecurityConfig config = JsBridge.SecurityConfig.secure();
        try {
            new JsBridge(
                    transport,
                    contextProvider,
                    new JsBridge.KernelConfig(),
                    config);
            org.junit.Assert.fail("expected IllegalArgumentException when access control enabled with wildcard allowedOrigins");
        } catch (IllegalArgumentException expected) {
            assertTrue(expected.getMessage().contains("allowedOrigins"));
        }
    }

    @Test
    public void contextHandler_receivesTrustedPageContext() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        java.util.concurrent.atomic.AtomicReference<TrustedPageContext> seen = new java.util.concurrent.atomic.AtomicReference<>();
        bridge.registerNativeHandlerWithContext("echo", (trustedPageContext, data, callback) -> {
            seen.set(trustedPageContext);
            callback.success(data);
        });
        bridge.resetForNewPage();

        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        String sessionId = extractStringField(transport.lastSent(), "sessionId");
        assertNotNull(sessionId);

        transport.deliver(requestJson("r2", "echo", sessionId, "{}"));
        assertNotNull(seen.get());
        assertEquals("file://", seen.get().getOrigin());
    }

    private static JsBridge newBridge(FakeBridgeTransport transport, List<PolicyRule> extraPolicies) {
        JsBridge.SecurityConfig securityConfig = JsBridge.SecurityConfig.secure()
                .allowedOrigins(new HashSet<>(Arrays.asList("file://")))
                .methodWhitelist(new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")))
                .defaultCapabilities(new HashSet<>(Arrays.asList("echo")))
                .extraPolicies(extraPolicies);
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                new JsBridge.KernelConfig(),
                securityConfig);
        bridge.resetTransport();
        return bridge;
    }

    private static String requestJson(String id, String method, String sessionId, String payloadJson) {
        return "{\"id\":\"" + id + "\","
                + "\"kind\":\"request\","
                + "\"method\":\"" + method + "\","
                + "\"sessionId\":\"" + sessionId + "\","
                + "\"payload\":" + payloadJson + "}";
    }

    private static String extractStringField(String json, String field) {
        String marker = "\"" + field + "\":\"";
        int begin = json.indexOf(marker);
        if (begin < 0) {
            return null;
        }
        int valueStart = begin + marker.length();
        int valueEnd = json.indexOf("\"", valueStart);
        if (valueEnd <= valueStart) {
            return null;
        }
        return json.substring(valueStart, valueEnd);
    }

    private static final class FakeBridgeTransport implements BridgeTransport {
        private Listener listener;
        private final List<String> sent = new ArrayList<>();
        private boolean sendEnabled = true;

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

        void setSendEnabled(boolean sendEnabled) {
            this.sendEnabled = sendEnabled;
        }
    }
}
