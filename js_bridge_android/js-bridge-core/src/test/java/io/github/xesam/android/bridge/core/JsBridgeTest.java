package io.github.xesam.android.bridge.core;

import org.json.JSONObject;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;

import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.BridgeTestSupport.FakeBridgeTransport;
import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.security.context.PageContextProvider;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.security.policy.PolicyDecision;
import io.github.xesam.android.bridge.security.policy.PolicyInput;
import io.github.xesam.android.bridge.security.policy.PolicyRule;

import static io.github.xesam.android.bridge.BridgeTestSupport.errorCode;
import static io.github.xesam.android.bridge.BridgeTestSupport.handshakeSessionId;
import static io.github.xesam.android.bridge.BridgeTestSupport.parse;
import static io.github.xesam.android.bridge.BridgeTestSupport.requestJson;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

public class JsBridgeTest {

    @Test
    public void requestBeforeHandshake_rejectedByGate() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.resetPageInstance();

        transport.deliver(requestJson("r1", "echo", "", "{\"k\":\"v\"}"));

        JSONObject parsed = parse(transport.lastSent());
        assertFalse(parsed.optBoolean("ok", true));
        assertEquals("E_NOT_READY", errorCode(parsed)); // v1: 握手门禁从 E_POLICY_DENY 分立
    }

    @Test
    public void handshakeThenHandlerRequest_successResponse() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        bridge.resetPageInstance();

        bridge.addReadyListener(() -> {
        });
        String sessionId = handshakeSessionId(transport);

        transport.deliver(requestJson("r2", "echo", sessionId, "{\"ok\":1}"));
        JSONObject response = parse(transport.lastSent());
        assertTrue(response.optBoolean("ok", false));
        assertEquals("echo", response.optString("method"));
        assertEquals(1, response.optJSONObject("payload").optInt("ok"));
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
        bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        bridge.resetPageInstance();

        String sessionId = handshakeSessionId(transport);

        transport.deliver(requestJson("r2", "echo", sessionId, "{}"));
        JSONObject response = parse(transport.lastSent());
        assertFalse(response.optBoolean("ok", true));
        assertEquals("E_TEST_DENY", errorCode(response));
    }

    @Test
    public void handlerThrows_returnsInternalErrorResponse() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.registerSimpleHandler("echo", (ctx, payload) -> {
            throw new RuntimeException("boom");
        });
        bridge.resetPageInstance();

        String sessionId = handshakeSessionId(transport);

        transport.deliver(requestJson("r2", "echo", sessionId, "{\"ok\":1}"));
        JSONObject fail = parse(transport.lastSent());
        assertFalse(fail.optBoolean("ok", true));
        assertEquals("E_INTERNAL", errorCode(fail));
        assertEquals("boom", fail.optJSONObject("error").optString("message"));
    }

    @Test
    public void sendFailure_handshakeKeepsReadyAndPostEventReturnsFalse() throws Exception {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        transport.setSendEnabled(false);
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        bridge.resetPageInstance();

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
                null);
        bridge.resetPageInstance();
        assertTrue(bridge.isReady());
    }

    @Test
    public void defaultConfig_handlerDispatchedWithoutHandshake() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                null);
        bridge.registerSimpleHandler("echo", (ctx, payload) -> "ok");
        bridge.resetTransport();
        bridge.resetPageInstance();

        transport.deliver(requestJson("r1", "echo", "", "{}"));

        JSONObject response = parse(transport.lastSent());
        assertTrue(response.optBoolean("ok", false));
        assertEquals("echo", response.optString("method"));
        assertEquals("r1", response.optString("reqId"));
    }

    @Test
    public void defaultConfig_postEventImmediatelyAvailable() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                null);
        bridge.resetPageInstance();

        boolean sent = bridge.postEvent("runtime.state", "{\"state\":\"active\"}");

        assertTrue(sent);
        JSONObject lastMessage = parse(transport.lastSent());
        assertEquals("event", lastMessage.optString("kind"));
        assertEquals("runtime.state", lastMessage.optString("method"));
    }

    @Test
    public void secure_withoutAllowedOrigins_throws() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge.SecurityConfig config = new JsBridge.SecurityConfig();
        try {
            new JsBridge(
                    transport,
                    contextProvider,
                    config);
            org.junit.Assert.fail("expected IllegalArgumentException when SecurityConfig provided without allowedOrigins");
        } catch (IllegalArgumentException expected) {
            assertTrue(expected.getMessage().contains("allowedOrigins"));
        }
    }

    @Test
    public void secure_withoutMethodWhitelist_throws() {
        // validate() 双字段的对称半边：allowedOrigins 已有用例，methodWhitelist 为 null 同样构造期报错
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge.SecurityConfig config = new JsBridge.SecurityConfig()
                .allowedOrigins(new HashSet<>(Arrays.asList("file://")));
        try {
            new JsBridge(
                    transport,
                    contextProvider,
                    config);
            org.junit.Assert.fail("expected IllegalArgumentException when SecurityConfig provided without methodWhitelist");
        } catch (IllegalArgumentException expected) {
            assertTrue(expected.getMessage().contains("methodWhitelist"));
        }
    }

    /**
     * {"*"} 是合法的显式"不限制该维度"声明：构造不抛异常，对应策略节点不进链。
     * 装配后的放行行为由 ConformanceCoreBaselineTest 的 c65 断言（行为级）。
     */
    @Test
    public void secure_withWildcardSets_allowed() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge.SecurityConfig config = new JsBridge.SecurityConfig()
                .allowedOrigins(new HashSet<>(Arrays.asList("*")))
                .methodWhitelist(new HashSet<>(Arrays.asList("*")));
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                config);
        assertNotNull(bridge);
    }

    @Test
    public void contextHandler_receivesTrustedPageContext() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = newBridge(transport, new ArrayList<>());
        java.util.concurrent.atomic.AtomicReference<TrustedPageContext> seen = new java.util.concurrent.atomic.AtomicReference<>();
        // context 作为 handler 首形参传入——策略求值时使用的那一个对象
        bridge.registerSimpleHandler("echo", (trustedPageContext, payload) -> {
            seen.set(trustedPageContext);
            return payload;
        });
        bridge.resetPageInstance();

        String sessionId = handshakeSessionId(transport);

        transport.deliver(requestJson("r2", "echo", sessionId, "{}"));
        assertNotNull(seen.get());
        assertEquals("file://", seen.get().getOrigin());
    }

    private static JsBridge newBridge(FakeBridgeTransport transport, List<PolicyRule> extraPolicies) {
        JsBridge.SecurityConfig securityConfig = new JsBridge.SecurityConfig()
                .allowedOrigins(new HashSet<>(Arrays.asList("file://")))
                .methodWhitelist(new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")))
                .extraPolicies(extraPolicies);
        PageContextProvider contextProvider = (bridgeMessage, pageInstanceId) -> new TrustedPageContext("file://", pageInstanceId);
        JsBridge bridge = new JsBridge(
                transport,
                contextProvider,
                securityConfig);
        bridge.resetTransport();
        return bridge;
    }
}
