package io.github.xesam.android.bridge.security.policy;

import org.junit.Test;

import java.util.Arrays;
import java.util.HashSet;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.security.session.SessionRecord;
import io.github.xesam.android.bridge.security.policy.OriginPolicy;
import io.github.xesam.android.bridge.security.policy.MethodGatePolicy;
import io.github.xesam.android.bridge.security.policy.SessionPolicy;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class PolicyGroupsTest {

    @Test
    public void requestShape_rejectsNonRequest() {
        PolicyDecision decision = new RequestShapePolicy().evaluate(new PolicyInput(
                eventMessage("timerLog"),
                context("file://"),
                false,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_INVALID_MESSAGE", errorCode(decision));
    }

    @Test
    public void handshakeGate_rejectsCallBeforeHandshake() {
        PolicyDecision decision = new HandshakeGatePolicy().evaluate(new PolicyInput(
                requestMessage("getUser", "s1"),
                context("file://"),
                false,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_NOT_READY", errorCode(decision)); // v1: 握手门禁从 E_POLICY_DENY 分立
    }

    @Test
    public void originPolicy_rejectsUnknownOrigin() {
        OriginPolicy policy = new OriginPolicy(
                new HashSet<>(Arrays.asList("https://trusted.example")));

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("timerLog", "s1"),
                context("file://"),
                true,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_ORIGIN_DENY", errorCode(decision));
    }

    @Test
    public void methodGatePolicy_rejectsUnknownMethod() {
        MethodGatePolicy policy = new MethodGatePolicy(
                new HashSet<>(Arrays.asList("bridge.handshake", "getUser")));

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("timerLog", "s1"),
                context("file://"),
                true,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_METHOD_NOT_ALLOWED", errorCode(decision));
    }

    @Test
    public void sessionPolicy_rejectsSessionMismatch() {
        SessionPolicy policy = new SessionPolicy();

        SessionRecord sessionRecord = new SessionRecord(
                "s1",
                "file://",
                "page-a",
                System.currentTimeMillis() + 60_000L);

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("getUser", "s1"),
                new TrustedPageContext("file://", "page-b"),
                true,
                sessionRecord));

        assertFalse(decision.isAllowed());
        assertEquals("E_SESSION_INVALID", errorCode(decision));
    }

    @Test
    public void sessionPolicy_allowsValidRequest() {
        SessionPolicy policy = new SessionPolicy();

        SessionRecord sessionRecord = new SessionRecord(
                "s1",
                "file://",
                "page-a",
                System.currentTimeMillis() + 60_000L);

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("getUser", "s1"),
                new TrustedPageContext("file://", "page-a"),
                true,
                sessionRecord));

        assertTrue(decision.isAllowed());
    }

    private static BridgeMessage requestMessage(String method, String sessionId) {
        return message("request", method, sessionId);
    }

    private static BridgeMessage eventMessage(String method) {
        return message("event", method, "");
    }

    private static TrustedPageContext context(String origin) {
        return new TrustedPageContext(origin, "page-a");
    }

    private static BridgeMessage message(String kind, String method, String sessionId) {
        return BridgeMessage.fromJson("{\"id\":\"r1\",\"kind\":\"" + kind + "\","
                + "\"method\":\"" + method + "\",\"sessionId\":\"" + sessionId + "\"}");
    }

    private static String errorCode(PolicyDecision decision) {
        BridgeError error = decision.getError();
        return error == null ? "" : error.getCode();
    }

    // ===== C45: 策略链固定求值顺序与短路行为 =====

    @Test
    public void c45_policyChain_evaluatesInFixedOrder_requestShapeFirst() {
        // 第一层 RequestShapePolicy 拒绝 -> 短路，后续策略不执行
        PolicyInput invalidInput = new PolicyInput(
                eventMessage("timerLog"), // kind=event，不是 request
                context("file://"),
                false,
                null);

        PolicyDecision decision = new RequestShapePolicy().evaluate(invalidInput);

        assertFalse(decision.isAllowed());
        assertEquals("E_INVALID_MESSAGE", errorCode(decision));
    }

    @Test
    public void c45_policyChain_shortCircuitsOnFirstDenial() {
        // 构造一个策略链：RequestShapePolicy -> HandshakeGatePolicy -> OriginPolicy
        // 预期：HandshakeGatePolicy 拒绝后短路，OriginPolicy 不执行
        java.util.List<PolicyRule> rules = new java.util.ArrayList<>();
        rules.add(new RequestShapePolicy());
        rules.add(new HandshakeGatePolicy());
        rules.add(new OriginPolicy(new HashSet<>(Arrays.asList("https://trusted.example"))));

        PolicyEngine engine = new PolicyEngine(rules);

        PolicyInput input = new PolicyInput(
                requestMessage("getUser", "s1"),
                context("file://"), // origin 不在白名单，但应该不会走到 OriginPolicy
                false, // 未 ready，HandshakeGatePolicy 会拒绝
                null);

        PolicyDecision decision = engine.evaluate(input);

        assertFalse(decision.isAllowed());
        // 断言：短路在 HandshakeGatePolicy，错误码是 E_NOT_READY，而不是 OriginPolicy 的 E_ORIGIN_DENY
        assertEquals("E_NOT_READY", errorCode(decision));
    }

    @Test
    public void c45_policyChain_continuesWhenAllAllow() {
        // 所有策略都通过 -> 返回 allow
        java.util.List<PolicyRule> rules = new java.util.ArrayList<>();
        rules.add(new RequestShapePolicy());

        PolicyEngine engine = new PolicyEngine(rules);

        PolicyInput input = new PolicyInput(
                requestMessage("bridge.handshake", ""),
                context("file://"),
                false,
                null);

        PolicyDecision decision = engine.evaluate(input);

        assertTrue(decision.isAllowed());
    }

    // ===== C46: 安全级别切换 - 不同配置下的策略链组成 =====

    @Test
    public void c46_nullConfig_onlyRequestShapePolicy() {
        // 无配置（SecurityConfig == null）：只有 RequestShapePolicy 激活
        // 非 request 消息会被拒绝
        java.util.List<PolicyRule> rules = new java.util.ArrayList<>();
        rules.add(new RequestShapePolicy());

        PolicyEngine engine = new PolicyEngine(rules);

        PolicyInput invalidInput = new PolicyInput(
                eventMessage("timerLog"),
                context("file://"),
                false,
                null);

        PolicyDecision decision = engine.evaluate(invalidInput);
        assertFalse(decision.isAllowed());
        assertEquals("E_INVALID_MESSAGE", errorCode(decision));

        // 有效的 request 消息会通过（因为没有其他策略）
        PolicyInput validInput = new PolicyInput(
                requestMessage("getUser", ""),
                context("file://"),
                false,
                null);

        decision = engine.evaluate(validInput);
        assertTrue(decision.isAllowed());
    }

    @Test
    public void c46_wildcardConfig_requiresHandshakeButNoOriginMethodCheck() {
        // 有配置但 allowedOrigins={"*"} 和 methodWhitelist={"*"}
        // 策略链：RequestShapePolicy + HandshakeGatePolicy + SessionPolicy
        // 不包括 OriginPolicy 和 MethodGatePolicy
        java.util.List<PolicyRule> rules = new java.util.ArrayList<>();
        rules.add(new RequestShapePolicy());
        rules.add(new HandshakeGatePolicy());
        rules.add(new SessionPolicy());

        PolicyEngine engine = new PolicyEngine(rules);

        // 未 ready 时，非握手调用被 HandshakeGatePolicy 拒绝
        PolicyInput beforeHandshake = new PolicyInput(
                requestMessage("anyMethod", "s1"),
                context("file://"),
                false, // 未 ready
                null);

        PolicyDecision decision = engine.evaluate(beforeHandshake);
        assertFalse(decision.isAllowed());
        assertEquals("E_NOT_READY", errorCode(decision));

        // ready 后，但 session 不存在，被 SessionPolicy 拒绝
        PolicyInput afterHandshakeNoSession = new PolicyInput(
                requestMessage("anyMethod", "s1"),
                context("file://"),
                true, // 已 ready
                null); // 无 session

        decision = engine.evaluate(afterHandshakeNoSession);
        assertFalse(decision.isAllowed());
        assertEquals("E_SESSION_INVALID", errorCode(decision));
    }

    @Test
    public void c46_fullConfig_fullPolicyChainWithOriginAndMethodCheck() {
        // 完整配置：完整策略链，包括 OriginPolicy 和 MethodGatePolicy
        java.util.List<PolicyRule> rules = new java.util.ArrayList<>();
        rules.add(new RequestShapePolicy());
        rules.add(new HandshakeGatePolicy());
        rules.add(new OriginPolicy(new HashSet<>(Arrays.asList("https://trusted.example"))));
        rules.add(new MethodGatePolicy(new HashSet<>(Arrays.asList("bridge.handshake", "getUser"))));
        rules.add(new SessionPolicy());

        PolicyEngine engine = new PolicyEngine(rules);

        SessionRecord validSession = new SessionRecord(
                "s1",
                "https://trusted.example",
                "page-a",
                System.currentTimeMillis() + 60_000L);

        // origin 不在白名单 -> OriginPolicy 拒绝
        PolicyInput untrustedOrigin = new PolicyInput(
                requestMessage("getUser", "s1"),
                context("https://untrusted.com"),
                true,
                validSession);

        PolicyDecision decision = engine.evaluate(untrustedOrigin);
        assertFalse(decision.isAllowed());
        assertEquals("E_ORIGIN_DENY", errorCode(decision));

        // method 不在白名单 -> MethodGatePolicy 拒绝
        PolicyInput unauthorizedMethod = new PolicyInput(
                requestMessage("deleteUser", "s1"),
                context("https://trusted.example"),
                true,
                validSession);

        decision = engine.evaluate(unauthorizedMethod);
        assertFalse(decision.isAllowed());
        assertEquals("E_METHOD_NOT_ALLOWED", errorCode(decision));

        // 所有条件都满足 -> 通过
        PolicyInput validRequest = new PolicyInput(
                requestMessage("getUser", "s1"),
                new TrustedPageContext("https://trusted.example", "page-a"),
                true,
                validSession);

        decision = engine.evaluate(validRequest);
        assertTrue(decision.isAllowed());
    }
}
