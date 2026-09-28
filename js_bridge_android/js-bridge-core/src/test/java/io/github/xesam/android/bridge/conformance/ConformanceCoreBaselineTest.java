package io.github.xesam.android.bridge.conformance;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.BridgeTestSupport;
import io.github.xesam.android.bridge.BridgeTestSupport.FakeBridgeTransport;
import io.github.xesam.android.bridge.api.OriginNormalizer;
import io.github.xesam.android.bridge.core.CoreBridge;
import io.github.xesam.android.bridge.extensions.lifecycle.LifecycleExtension;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.security.context.PageContextProvider;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.security.policy.PolicyDecision;
import io.github.xesam.android.bridge.security.policy.PolicyInput;
import io.github.xesam.android.bridge.security.policy.PolicyRule;
import io.github.xesam.android.bridge.security.session.DefaultSessionService;
import io.github.xesam.android.bridge.security.session.HandshakeResult;
import io.github.xesam.android.bridge.security.session.InMemorySessionStore;

import static io.github.xesam.android.bridge.BridgeTestSupport.errorCode;
import static io.github.xesam.android.bridge.BridgeTestSupport.jsonOf;
import static io.github.xesam.android.bridge.BridgeTestSupport.parse;
import static io.github.xesam.android.bridge.BridgeTestSupport.requestJson;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class ConformanceCoreBaselineTest {

    @Test
    public void C01_requestBeforeHandshake_deniedByGate() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetPageInstance();
        fixture.transport.deliver(requestJson("r1", "echo", "", "{}"));

        assertEquals("E_NOT_READY", errorCode(fixture.transport.lastSent())); // v1: 握手门禁从 E_POLICY_DENY 分立（docs/03 §8 传输层类）
    }

    @Test
    public void C02_handshake_returnsSessionPayload() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetPageInstance();

        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        JSONObject response = parse(fixture.transport.lastSent());
        JSONObject payload = response.optJSONObject("payload");

        assertTrue(response.optBoolean("ok"));
        assertNotNull(payload);
        assertTrue(payload.optString("sessionId").length() > 0);
        assertTrue(payload.has("sessionTtlMs"));
        assertTrue(payload.has("policyVersion"));
        assertEquals("file://", payload.optString("origin"));
        assertTrue(payload.optBoolean("accepted"));
    }

    @Test
    public void C03_methodNotAllowed_denied() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "notAllowed", sessionId, "{}"));
        assertEquals("E_METHOD_NOT_ALLOWED", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C04_originNotAllowed_denied() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("https://trusted.example")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                new ArrayList<>());
        fixture.bridge.resetPageInstance();
        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        assertEquals("E_ORIGIN_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C04b_originPrefixButNotExact_denied() {
        MutableContextProvider contextProvider = new MutableContextProvider("https://trusted.example.evil", null);
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("https://trusted.example")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                new ArrayList<>(),
                contextProvider);
        fixture.bridge.resetPageInstance();
        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        assertEquals("E_ORIGIN_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C05_validHandshakeThenValidRequest_success() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{\"k\":\"v\"}"));
        JSONObject response = parse(fixture.transport.lastSent());

        assertTrue(response.optBoolean("ok"));
        assertEquals("echo", response.optString("method"));
    }

    @Test
    public void C06_missingSessionAfterReady_denied() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
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
                new ArrayList<>(),
                contextProvider);
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
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
                new ArrayList<>(),
                contextProvider);
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        contextProvider.setForcedPageInstanceId("fixed-page-b");
        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));

        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C10_methodNotFound_denied() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "missing")),
                new ArrayList<>());
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "missing", sessionId, "{}"));
        assertEquals("E_METHOD_NOT_FOUND", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C11_handlerThrows_normalizedToInternal() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> {
            throw new RuntimeException("boom");
        });
        fixture.bridge.resetPageInstance();
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
                extraPolicies);
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));
        assertEquals("E_TEST_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C13_streamingResponse_emitsDoneFalseThenDoneTrue() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "stream")),
                new ArrayList<>());
        // 多帧只能经 Async Handler + ResponseEmitter 表达（Simple 恒为单帧且 done=true，见 docs/08 §2）
        fixture.bridge.registerAsyncHandler("stream", (ctx, payload, emitter) -> {
            emitter.success(jsonOf("tick", 1), false);
            emitter.success(jsonOf("tick", 2), true);
        });
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();
        int before = fixture.transport.sentCount();

        fixture.transport.deliver(requestJson("r1", "stream", sessionId, "{}", true));

        // Android 的 emitter 在 dispatch() 内同步执行，帧在 deliver() 返回前到达 transport
        assertEquals(before + 2, fixture.transport.sentCount());
        JSONObject first = parse(fixture.transport.sentAt(before));
        JSONObject second = parse(fixture.transport.sentAt(before + 1));

        // 帧序契约：首帧 done=false，末帧 done=true
        assertFalse(first.optBoolean("done", true));
        assertTrue(second.optBoolean("done", false));
        assertTrue(first.optBoolean("ok", false));
        assertTrue(second.optBoolean("ok", false));
        // 帧关联单次请求（reqId），且 keep=true 请求的帧保持 keep=true
        assertEquals("r1", first.optString("reqId"));
        assertEquals("r1", second.optString("reqId"));
        assertTrue(first.optBoolean("keep", false));
        assertTrue(second.optBoolean("keep", false));
        assertEquals(1, first.optJSONObject("payload").optInt("tick"));
        assertEquals(2, second.optJSONObject("payload").optInt("tick"));
    }

    @Test
    public void C17_sendFailure_observableAndPostEventReturnsFalse() {
        Fixture fixture = new Fixture();
        fixture.transport.setSendEnabled(false);
        fixture.bridge.resetPageInstance();
        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        assertTrue(fixture.bridge.isReady());
        assertFalse(fixture.bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, "{}"));
    }

    @Test
    public void C18_resetPageInstanceRotatesContextAndOldSessionInvalid() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        String oldSessionId = fixture.handshake();

        fixture.bridge.resetPageInstance();
        fixture.handshake();
        fixture.transport.deliver(requestJson("r1", "echo", oldSessionId, "{}"));

        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C28_lifecycleEventsBeforeReady_queuedAndFlushedInOrder() {
        Fixture fixture = new Fixture();
        LifecycleExtension lifecycle = new LifecycleExtension(fixture.bridge);
        fixture.bridge.resetPageInstance();

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
        fixture.bridge.resetPageInstance();

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
        fixture.bridge.resetPageInstance();
        fixture.handshake();

        lifecycle.onHostEvent("resumed");

        List<JSONObject> events = lifecycleEvents(fixture);
        assertEquals(1, events.size());
        JSONObject payload = events.get(0);
        assertEquals("resumed", payload.optString("state"));
        assertEquals(1, payload.optInt("seq"));
        assertEquals(2, payload.length()); // payload 恰为 {state, seq}
    }

    @Test
    public void C33_emptyMethod_deniedAsInvalidMessage() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetPageInstance();

        fixture.transport.deliver(requestJson("r1", "", "", "{}"));

        assertEquals("E_INVALID_MESSAGE", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C34_missingKind_silentlyDropped() {
        Fixture fixture = new Fixture();
        fixture.bridge.resetPageInstance();

        fixture.transport.deliver("{\"id\":\"r1\",\"sessionId\":\"\",\"method\":\"echo\",\"payload\":{}}");

        assertNull(fixture.transport.lastSent());
        assertEquals(0, fixture.transport.sentCount());
    }

    @Test
    public void C35_handshakeNotInWhitelist_autoAllowed() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList("echo")),
                new ArrayList<>());
        fixture.bridge.resetPageInstance();

        fixture.transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));

        // 协议方法由框架装配期自动并入放行集，白名单未含 bridge.handshake 时握手仍成功
        JSONObject response = parse(fixture.transport.lastSent());
        assertTrue(response.optBoolean("ok"));
        assertFalse(response.optJSONObject("payload").optString("sessionId").isEmpty());
    }

    @Test
    public void C36_unknownSessionId_denied() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", "bogus-session", "{}"));

        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void C37_cancelScope_echoesPayloadScopeIdWithAccepted() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, BridgeApiContract.METHOD_CANCEL_SCOPE)),
                new ArrayList<>());
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson(
                "c1", BridgeApiContract.METHOD_CANCEL_SCOPE, sessionId, "{\"scopeId\":\"s-1\"}"));

        JSONObject response = parse(fixture.transport.lastSent());
        JSONObject payload = response.optJSONObject("payload");
        assertTrue(response.optBoolean("ok"));
        assertEquals("s-1", payload.optString("scopeId"));
        assertTrue(payload.optBoolean("accepted"));
    }

    @Test
    public void C38_missingOptionalFields_defaultsApplied() {
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = new JsBridge(
                transport,
                new MutableContextProvider("file://", null),
                null);
        bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        bridge.resetPageInstance();
        bridge.resetTransport();

        transport.deliver("{\"id\":\"r38\",\"kind\":\"request\",\"method\":\"echo\"}");

        JSONObject response = parse(transport.lastSent());
        assertTrue(response.optBoolean("ok"));
    }

    @Test
    public void C48_protocolMethods_autoMergedIntoWhitelist() {
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList("echo")), // 不含任何协议方法
                new ArrayList<>());
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();

        String sessionId = fixture.handshake();
        assertFalse(sessionId.isEmpty());

        // 协议方法 bridge.cancelScope 自动放行并回显 scopeId
        fixture.transport.deliver(requestJson(
                "c1", BridgeApiContract.METHOD_CANCEL_SCOPE, sessionId, "{\"scopeId\":\"s-1\"}"));
        JSONObject cancelResponse = parse(fixture.transport.lastSent());
        assertTrue(cancelResponse.optBoolean("ok"));
        assertEquals("s-1", cancelResponse.optJSONObject("payload").optString("scopeId"));

        // 白名单外业务方法仍被拒绝
        fixture.transport.deliver(requestJson("r1", "forbidden", sessionId, "{}"));
        assertEquals("E_METHOD_NOT_ALLOWED", errorCode(fixture.transport.lastSent()));

        // 白名单内业务方法正常成功
        fixture.transport.deliver(requestJson("r2", "echo", sessionId, "{}"));
        JSONObject echoResponse = parse(fixture.transport.lastSent());
        assertTrue(echoResponse.optBoolean("ok"));
    }

    @Test
    public void C49_duplicateRegistration_lastWins() {
        // 单一注册表：同一 method 重复注册时后者覆盖前者（无隐式优先级、无并存条目）
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = new JsBridge(
                transport,
                new MutableContextProvider("file://", null),
                null);
        final AtomicBoolean firstInvoked = new AtomicBoolean(false);
        bridge.registerSimpleHandler("dup", (ctx, payload) -> {
            firstInvoked.set(true);
            return jsonOf("from", "h1");
        });
        bridge.registerSimpleHandler("dup", (ctx, payload) -> jsonOf("from", "h2"));
        bridge.resetPageInstance();
        bridge.resetTransport();

        transport.deliver(requestJson("r49", "dup", "", "{}"));

        // 仅一帧，payload 来自后注册者；先注册者未被调用
        assertEquals(1, transport.sentCount());
        JSONObject response = parse(transport.lastSent());
        assertTrue(response.optBoolean("ok"));
        assertEquals("h2", response.optJSONObject("payload").optString("from"));
        assertTrue(response.optBoolean("done", false));
        assertFalse("先注册的 handler 不应被调用", firstInvoked.get());

        // 跨态覆盖：Async 覆盖 Simple 后只剩 Async 的帧序列，无 Simple 残留帧
        bridge.registerAsyncHandler("dup", (ctx, payload, emitter) -> {
            emitter.success(jsonOf("from", "h3"), false);
            emitter.success(jsonOf("from", "h3"), true);
        });
        int before = transport.sentCount();

        transport.deliver(requestJson("r49b", "dup", "", "{}"));

        assertEquals(before + 2, transport.sentCount());
        assertFalse(parse(transport.sentAt(before)).optBoolean("done", true));
        assertTrue(parse(transport.sentAt(before + 1)).optBoolean("done", false));
        assertEquals("h3", parse(transport.sentAt(before)).optJSONObject("payload").optString("from"));
    }

    @Test
    public void c51_malformedRequiredFieldTypes_silentlyDropped() {
        // C51：必填字段类型非法（id/kind/method/sessionId 非字符串）→ 静默丢弃，
        // 无任何响应且不影响后续正常请求（docs/03 §3.4：禁止宽容转换）
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = new JsBridge(
                transport,
                new MutableContextProvider("file://", null),
                null);
        bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        bridge.resetPageInstance();
        bridge.resetTransport();

        transport.deliver("{\"id\":123,\"kind\":\"request\",\"method\":\"echo\",\"sessionId\":\"\",\"payload\":{}}");
        transport.deliver("{\"id\":\"r2\",\"kind\":123,\"method\":\"echo\",\"sessionId\":\"\",\"payload\":{}}");
        transport.deliver("{\"id\":\"r3\",\"kind\":\"request\",\"method\":42,\"sessionId\":\"\",\"payload\":{}}");
        transport.deliver("{\"id\":\"r4\",\"kind\":\"request\",\"method\":\"echo\",\"sessionId\":55,\"payload\":{}}");

        // 四条畸形消息均无任何响应
        assertEquals(0, transport.sentCount());
        assertNull(transport.lastSent());

        // 后续正常请求不受影响
        transport.deliver(requestJson("r5", "echo", "", "{}"));
        assertEquals(1, transport.sentCount());
        JSONObject response = parse(transport.lastSent());
        assertTrue(response.optBoolean("ok"));
        assertEquals("r5", response.optString("reqId"));
    }

    @Test
    public void c52_simpleHandlerReturnsNull_emitsSingleDoneFrame() {
        // C52：handler 无数据成功（success(null)）必须照常发出终止帧——
        // 恰好 1 帧 ok=true、payload=null、done=true，禁止静默吞帧（docs/03 §6 done 标志）
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = new JsBridge(
                transport,
                new MutableContextProvider("file://", null),
                null);
        bridge.registerSimpleHandler("noop", (ctx, payload) -> null);
        bridge.resetPageInstance();
        bridge.resetTransport();

        transport.deliver(requestJson("r52", "noop", "", "{}"));

        assertEquals(1, transport.sentCount());
        JSONObject response = parse(transport.lastSent());
        assertTrue(response.optBoolean("ok"));
        assertTrue(response.isNull("payload"));
        assertTrue(response.optBoolean("done", false));
    }

    @Test
    public void c53_extraPolicyDenyWithoutError_fallsBackToPolicyDeny() {
        // C53：策略 deny 但不携带 error → 以 E_POLICY_DENY 兜底，fail-closed，
        // 禁止静默放行到 dispatch（docs/03 §9 细则 3）
        List<PolicyRule> extraPolicies = Arrays.asList(new PolicyRule() {
            @Override
            public PolicyDecision evaluate(PolicyInput input) {
                if ("echo".equals(input.getMessage().getMethod())) {
                    return PolicyDecision.deny(name(), null);
                }
                return PolicyDecision.allow();
            }

            @Override
            public String name() {
                return "DenyWithoutError";
            }
        });
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo")),
                extraPolicies);
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));

        JSONObject response = parse(fixture.transport.lastSent());
        assertFalse(response.optBoolean("ok"));
        assertEquals("E_POLICY_DENY", errorCode(fixture.transport.lastSent()));
    }

    @Test
    public void c54_originNormalizer_defaultPortsOmitted() {
        // C54：默认端口（443/80）必须省略（docs/03 §9 细则 5）
        assertEquals("https://host", OriginNormalizer.normalize("https://host:443"));
        assertEquals("http://host", OriginNormalizer.normalize("http://host:80"));
        // scheme 与 host 小写
        assertEquals("https://host", OriginNormalizer.normalize("HTTPS://HoSt:443"));
    }

    @Test
    public void c54_originNormalizer_nonDefaultPortsKept() {
        // C54：非默认端口保留原样
        assertEquals("https://host:8443", OriginNormalizer.normalize("https://host:8443"));
        assertEquals("http://host:8080", OriginNormalizer.normalize("http://host:8080"));
    }

    @Test
    public void c54_originNormalizer_missingUrlYieldsEmptyOrigin() {
        // C54：URL 缺失 → ""（不用 "about:blank" 等占位值），空串永不命中白名单——fail-closed
        assertEquals("", OriginNormalizer.normalize(null));
        assertEquals("", OriginNormalizer.normalize(""));
    }

    @Test
    public void c54_originNormalizer_vectorSuite() {
        // C54：四端共享的 origin 归一化全量向量，正本为 docs/origin-normalizer-vectors.json，
        // 由 scripts/check_origin_vectors.sh 强制四端 C54 测试内嵌同一向量集——修改必须四端同改
        // ORIGIN_VECTORS:BEGIN
        v("", "");
        v("   ", "");
        v("host/path", "");
        v("::::", "");
        v("123://host", "");
        v("a b://host", "");
        v("ab+cd-.://host", "ab+cd-.://host");
        v("about:blank", "");
        v("data:text/html,x", "");
        v("mailto:a@b", "");
        v("javascript:alert(1)", "");
        v("file:///sdcard/index.html", "file://");
        v("file://media/path", "file://");
        v("FILE:///x.html", "file://");
        v("content:///settings", "content://");
        v("flutter-asset:///assets/web/index.html", "flutter-asset://");
        v("asset://", "asset://");
        v("https://", "https://");
        v("https://example.com", "https://example.com");
        v("HTTPS://EXAMPLE.com/Path?x=1#f", "https://example.com");
        v("https://host:443", "https://host");
        v("http://host:80", "http://host");
        v("https://host:0443", "https://host");
        v("http://host:080", "http://host");
        v("https://host:8443", "https://host:8443");
        v("http://host:8080/a/b?c#d", "http://host:8080");
        v("http://u:p@host:8080", "http://host:8080");
        v("http://host:65535", "http://host:65535");
        v("http://host:99999", "");
        v("custom://host:8080", "custom://host:8080");
        v("custom://host", "custom://host");
        v("ftp://host:21", "ftp://host:21");
        v("https://:8080", "");
        v("http://host:abc", "");
        v("http://host:0", "");
        v("http://host:00", "");
        v("http://host:-80", "");
        v("http://host:", "");
        v("http://::", "");
        v("http://[::1]", "http://[::1]");
        v("http://[::1]:8443", "http://[::1]:8443");
        v("http://[2001:DB8::1]:443", "http://[2001:db8::1]:443");
        v("http://[::1]:0", "");
        // ORIGIN_VECTORS:END
    }

    /** C54 向量套件的单条断言（带上失败信息的 assertEquals）。 */
    private void v(String input, String expected) {
        assertEquals("normalize(" + input + ")", expected, OriginNormalizer.normalize(input));
    }

    @Test
    public void c55_postEventWithoutSession_eventHasEmptySessionId() {
        // C55：postEvent 事件帧 sessionId 恒为 ""（v1 广播唯一形态，无定向投送入口，四端一致）
        FakeBridgeTransport transport = new FakeBridgeTransport();
        JsBridge bridge = new JsBridge(
                transport,
                new MutableContextProvider("file://", null),
                null);
        bridge.resetPageInstance();
        bridge.resetTransport();

        // 握手建立 session 后再 postEvent
        transport.deliver(requestJson("h1", BridgeApiContract.METHOD_HANDSHAKE, "", "{}"));
        assertTrue(parse(transport.lastSent()).optBoolean("ok"));
        assertTrue(bridge.postEvent("custom.event", jsonOf("tick", 1)));

        JSONObject event = parse(transport.lastSent());
        assertEquals("event", event.optString("kind"));
        assertEquals("custom.event", event.optString("method"));
        assertEquals("", event.optString("sessionId"));
        assertEquals(1, event.optJSONObject("payload").optInt("tick"));
    }

    @Test
    public void c56_issueHandshakeCleansExpiredRecords_newSessionIssued() {
        // C56：签发时顺带清扫过期 session 记录（docs/03 §10 签发小节）——
        // 推进时钟越过 A 的 TTL 后再次签发 B：find(A) 失效（E_SESSION_INVALID 语义），
        // 且存储中过期 A 被签发时清扫移除（不随过期条目无界增长）
        InMemorySessionStore store = new InMemorySessionStore();
        DefaultSessionService sessionService = new DefaultSessionService(store, 1L, "v1");

        String sessionAId = sessionService.issueHandshake(
                new TrustedPageContext("file://", "page-56")).getPayload().optString("sessionId");

        awaitExpired(); // 推进时钟超过 A 的 TTL（1ms）

        HandshakeResult handshakeB = sessionService.issueHandshake(
                new TrustedPageContext("file://", "page-56"));

        // 过期 A 已被签发 B 时的顺带清扫移除（size 区分"清扫移除"与"find 惰性删除"）
        assertNull(sessionService.find(sessionAId));
        assertEquals(1, store.size());
        assertFalse(handshakeB.getPayload().optString("sessionId").isEmpty());
    }

    @Test
    public void c60_sessionTtlZero_neverExpires() {
        // C60：docs/03 §10 三态——sessionTtlMs=0 表示永不过期（-1 哨兵）。
        // 此前 Android/iOS/Harmony 误实现为立即过期：签发即死、find 立刻失效
        InMemorySessionStore store = new InMemorySessionStore();
        DefaultSessionService sessionService = new DefaultSessionService(store, 0L, "v1");

        TrustedPageContext context = new TrustedPageContext("file://", "page-60");
        String sessionAId = sessionService.issueHandshake(context).getPayload().optString("sessionId");
        awaitExpired(); // 墙钟推进：ttl=0 的会话不受时钟影响仍有效

        // 不同 pageInstanceId 签发 B，A 不受刷新语义影响（C61 只刷新同页）
        HandshakeResult handshakeB =
                sessionService.issueHandshake(new TrustedPageContext("file://", "page-60-b"));
        assertNotNull(sessionService.find(sessionAId)); // 永不失效
        assertEquals(2, store.size()); // 签发清扫不得移除永不过期记录
        assertFalse(handshakeB.getPayload().optString("sessionId").isEmpty());
    }

    @Test
    public void c61_repeatedHandshakeRefreshes_invalidatesPriorSession() {
        // C61：docs/03 §7.1 幂等性——同 pageInstanceId 重复握手应"刷新"而非并存：
        // 新 session 签发即旧 session 失效，存储内同页至多存活 1 条
        InMemorySessionStore store = new InMemorySessionStore();
        DefaultSessionService sessionService = new DefaultSessionService(store, 60_000L, "v1");

        TrustedPageContext context = new TrustedPageContext("file://", "page-61");
        String sessionAId = sessionService.issueHandshake(context).getPayload().optString("sessionId");
        assertNotNull(sessionService.find(sessionAId));

        String sessionBId = sessionService.issueHandshake(context).getPayload().optString("sessionId");

        assertNull(sessionService.find(sessionAId)); // 旧 session 已被刷新失效
        assertNotNull(sessionService.find(sessionBId));
        assertEquals(1, store.size()); // 同页至多 1 条存活
    }

    @Test
    public void c62_dispatchLaunchesAsyncWithoutBlocking_pipelineKeepsProcessing() throws Exception {
        // C62：docs/09 —— dispatch 对 Async handler 启动即返：busy handler 发射首帧后挂起，
        // 期间 ping（Simple）请求仍可被完整处理（busy 挂起不得阻塞入站管线）
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "busy", "ping")),
                new ArrayList<>());
        CountDownLatch firstFrameSent = new CountDownLatch(1);
        CountDownLatch releaseBusy = new CountDownLatch(1);
        fixture.bridge.registerAsyncHandler("busy", (ctx, payload, emitter) -> {
            // 真实流式形态：handler 启动 worker 后立即返回，帧由 worker 推送
            Thread worker = new Thread(() -> {
                emitter.success(jsonOf("tick", 1), false);
                firstFrameSent.countDown();
                try {
                    releaseBusy.await(); // 挂起不收尾
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                emitter.success(jsonOf("tick", 2), true);
            });
            worker.setDaemon(true);
            worker.start();
        });
        fixture.bridge.registerSimpleHandler("ping", (ctx, payload) -> jsonOf("pong", true));
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();
        int before = fixture.transport.sentCount();

        // busy：dispatch 启动 worker 后立即返回，首帧由 worker 推送
        fixture.transport.deliver(requestJson("r62a", "busy", sessionId, "{}", true));
        assertTrue(firstFrameSent.await(2, TimeUnit.SECONDS));

        // busy 仍挂起时发起 ping：dispatch 不得被未完成的流式 handler 阻塞
        fixture.transport.deliver(requestJson("r62b", "ping", sessionId, "{}"));
        assertEquals(before + 2, fixture.transport.sentCount());

        JSONObject busyFrame = parse(fixture.transport.sentAt(before));
        assertEquals("r62a", busyFrame.optString("reqId"));
        assertFalse(busyFrame.optBoolean("done", true)); // busy 仅有首帧，无终帧逃逸
        JSONObject pingResponse = parse(fixture.transport.sentAt(before + 1));
        assertEquals("r62b", pingResponse.optString("reqId"));
        assertTrue(pingResponse.optBoolean("done", false)); // ping 已完整落定
        assertTrue(pingResponse.optJSONObject("payload").optBoolean("pong"));

        releaseBusy.countDown();
    }

    @Test
    public void c64_dispatchIgnoresNonRequestEnvelopes_tier1kindGuard() throws Exception {
        // C64：docs/09 —— Tier-1 kind 路由守卫：standalone CoreBridge 对非 request 信封
        // （response/event 是 Native→JS 方向）不派发——同名 handler 不得被误命中，
        // 不产生任何响应帧。Tier-2 路径由 RequestShapePolicy 先行拒绝（既有用例覆盖）。
        FakeBridgeTransport transport = new FakeBridgeTransport();
        CoreBridge core = new CoreBridge(transport);
        core.bind();
        AtomicBoolean handlerInvoked = new AtomicBoolean(false);
        core.registerSimpleHandler("leak.test", (ctx, payload) -> {
            handlerInvoked.set(true);
            return jsonOf("leaked", true);
        });
        TrustedPageContext context = new TrustedPageContext("file://", "page-64");

        // kind=response / kind=event 信封：命中注册表同名 method 也不得派发
        BridgeMessage responseKind = BridgeMessage.fromJson(
                "{\"id\":\"r64a\",\"sessionId\":\"\",\"kind\":\"response\",\"method\":\"leak.test\",\"reqId\":\"x\",\"done\":true,\"ok\":false}");
        BridgeMessage eventKind = BridgeMessage.fromJson(
                "{\"id\":\"r64b\",\"sessionId\":\"\",\"kind\":\"event\",\"method\":\"leak.test\",\"payload\":{}}");
        assertNotNull(responseKind);
        assertNotNull(eventKind);
        core.dispatch(responseKind, context);
        core.dispatch(eventKind, context);
        assertFalse(handlerInvoked.get());
        assertEquals(0, transport.sentCount());

        // 对照组：kind=request 正常派发（守卫不得误伤正常路径）
        core.dispatch(BridgeMessage.fromJson(
                        "{\"id\":\"r64c\",\"sessionId\":\"\",\"kind\":\"request\",\"method\":\"leak.test\",\"payload\":{}}"),
                context);
        assertTrue(handlerInvoked.get());
        assertEquals(1, transport.sentCount());
    }

    @Test
    public void c65_wildcardSets_skipOriginAndMethodGate_realAssembly() {
        // C65：docs/09 —— 通配 {"*"} 是"对应策略节点不进链"而非"装配后放行一切"：
        // 以真实 JsBridge 装配验证（此前 Origin/MethodGate 的通配排除分支仅为"代码为真、无用例锁定"——
        // 策略链单测 c46_* 手拼链无法拦截装配层回归）。白名单外方法 + 未白名单 origin 的请求
        // 仍能到达 handler；SessionPolicy 仍在链，换 origin 复用 session 必被拒。
        MutableContextProvider contextProvider = new MutableContextProvider("https://arbitrary.example", null);
        Fixture fixture = new Fixture(
                new HashSet<>(Arrays.asList("*")),
                new HashSet<>(Arrays.asList("*")),
                new ArrayList<>(),
                contextProvider);
        fixture.bridge.registerSimpleHandler("not.in.whitelist", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        String sessionId = fixture.handshake();
        assertFalse(sessionId.isEmpty());

        // 同 origin：Origin/MethodGate 均未进链 → 白名单外业务方法 ok=true
        // （非通配配置下同输入为 E_ORIGIN_DENY / E_METHOD_NOT_ALLOWED，见 C04/C03）
        fixture.transport.deliver(requestJson("r65a", "not.in.whitelist", sessionId, "{}"));
        JSONObject response = parse(fixture.transport.lastSent());
        assertTrue(response.optBoolean("ok", false));
        assertEquals("r65a", response.optString("reqId"));

        // 换 origin 复用 session：SessionPolicy 仍在链 → E_SESSION_INVALID
        // （通配只豁免对应维度，不影响 session origin 匹配语义）
        contextProvider.setOrigin("https://other.example");
        fixture.transport.deliver(requestJson("r65b", "not.in.whitelist", sessionId, "{}"));
        assertEquals("E_SESSION_INVALID", errorCode(fixture.transport.lastSent()));
    }

    /** 等待越过短 TTL（c56 用，TTL=1ms，等待 10ms 保证过期）。 */
    private static void awaitExpired() {
        try {
            Thread.sleep(10L);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException(e);
        }
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

    private static final class Fixture {
        final FakeBridgeTransport transport = new FakeBridgeTransport();
        final JsBridge bridge;

        Fixture() {
            this(new HashSet<>(Arrays.asList("file://")),
                    new HashSet<>(Arrays.asList(BridgeApiContract.METHOD_HANDSHAKE, "echo", "forbidden")),
                    new ArrayList<>());
        }

        Fixture(
                HashSet<String> allowedOrigins,
                HashSet<String> allowedMethods,
                List<PolicyRule> extraPolicies) {
            this(allowedOrigins, allowedMethods, extraPolicies, new MutableContextProvider("file://", null));
        }

        Fixture(
                HashSet<String> allowedOrigins,
                HashSet<String> allowedMethods,
                List<PolicyRule> extraPolicies,
                PageContextProvider pageContextProvider) {
            JsBridge.SecurityConfig securityConfig = new JsBridge.SecurityConfig()
                    .allowedOrigins(allowedOrigins)
                    .methodWhitelist(allowedMethods)
                    .extraPolicies(extraPolicies);
            bridge = new JsBridge(
                    transport,
                    pageContextProvider,
                    securityConfig);
            bridge.resetTransport();
        }

        String handshake() {
            return BridgeTestSupport.handshakeSessionId(transport);
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
}
