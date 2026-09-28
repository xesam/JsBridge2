package io.github.xesam.android.bridge.conformance;

import org.json.JSONObject;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.BridgeTestSupport.FakeBridgeTransport;
import io.github.xesam.android.bridge.security.context.PageContextProvider;

import io.github.xesam.android.bridge.BridgeTestSupport;
import static io.github.xesam.android.bridge.BridgeTestSupport.jsonOf;
import static io.github.xesam.android.bridge.BridgeTestSupport.parse;
import static io.github.xesam.android.bridge.BridgeTestSupport.requestJson;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

/**
 * 验证统一 Handler API (v1.0) 在 Android 上的行为：
 * registerSimpleHandler / registerAsyncHandler / ResponseEmitter。
 *
 * 重要说明：Android 的 AsyncHandler 在 dispatch() 内同步执行。
 * ResponseEmitter 回调在 handler.handle() 返回之前触发，
 * 与 iOS/Flutter（dispatch 立即返回 []，帧稍后异步到达 transport）不同。
 * 这是 Android 的实现特性，不是缺陷：ResponseEmitter 天然支持
 * 同步多帧响应（持有 emitter 并在后台线程上调用）。
 *
 * 下面的测试精确记录了实际行为。
 */
public class UnifiedHandlerApiTest {

    // ── C43: Async handler 经 emitter 推送多帧 ────────────────────────────────

    /**
     * C43 — Async handler 经 emitter 推送多帧响应。
     *
     * 与 iOS `testC43_asyncHandler_multipleResponsesViaEmitter`、Flutter
     * `C43_asyncHandler_multipleResponsesViaEmitter` 同一验收点。
     * 平台差异：Android 在 dispatch() 内同步执行 handler，帧在 deliver() 返回前
     * 即到达 transport；iOS/Flutter 需等待异步回调。断言的**帧序列与 done 语义**
     * 四端一致——这是跨端契约，执行时机差异不属于协议。
     */
    @Test
    public void c43_asyncHandler_multipleResponsesViaEmitter() throws Exception {
        Fixture fixture = new Fixture();
        fixture.bridge.registerAsyncHandler("multi", (ctx, payload, emitter) -> {
            emitter.success(jsonOf("frame", 1), false);
            emitter.success(jsonOf("frame", 2), false);
            emitter.success(jsonOf("frame", 3), true);
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r43", "multi", sessionId, "{}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r43");
        assertEquals(3, frames.size());
        // 前两帧 done=false
        assertFalse(frames.get(0).optBoolean("done"));
        assertEquals(1, frames.get(0).optJSONObject("payload").optInt("frame"));
        assertFalse(frames.get(1).optBoolean("done"));
        assertEquals(2, frames.get(1).optJSONObject("payload").optInt("frame"));
        // 末帧 done=true
        assertTrue(frames.get(2).optBoolean("done"));
        assertEquals(3, frames.get(2).optJSONObject("payload").optInt("frame"));
    }

    // ── SimpleHandler ─────────────────────────────────────────────────────────

    @Test
    public void simpleHandler_success_singleFrame_doneTrue() throws Exception {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("greet", (ctx, payload) -> {
            JSONObject result = new JSONObject();
            result.put("hello", "world");
            return result;
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "greet", sessionId, "{}"));

        // 正好一帧，reqId 匹配，ok=true，done=true
        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(1, frames.size());
        JSONObject frame = frames.get(0);
        assertTrue(frame.optBoolean("ok"));
        assertTrue(frame.optBoolean("done"));
        assertEquals("world", frame.optJSONObject("payload").optString("hello"));
    }

    @Test
    public void simpleHandler_throwsException_normalizedToInternal() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("boom", (ctx, payload) -> {
            throw new RuntimeException("intentional");
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "boom", sessionId, "{}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(1, frames.size());
        assertFalse(frames.get(0).optBoolean("ok"));
        JSONObject error = frames.get(0).optJSONObject("error");
        assertNotNull(error);
        assertEquals(BridgeApiContract.ERR_INTERNAL, error.optString("code"));
    }

    @Test
    public void simpleHandler_payloadEchoed() throws Exception {
        Fixture fixture = new Fixture();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> payload);
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{\"x\":42}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(1, frames.size());
        assertTrue(frames.get(0).optBoolean("ok"));
        assertEquals(42, frames.get(0).optJSONObject("payload").optInt("x"));
    }

    @Test
    public void simpleHandler_receivesTrustedPageContext() {
        Fixture fixture = new Fixture();
        List<TrustedPageContext> seen = new ArrayList<>();
        fixture.bridge.registerSimpleHandler("echo", (ctx, payload) -> {
            seen.add(ctx);
            return payload;
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "echo", sessionId, "{}"));

        // Simple 路径同样传入选中的可信上下文（context 不再是独立注册口的特权）
        assertEquals(1, seen.size());
        assertEquals("file://", seen.get(0).getOrigin());
    }

    // ── AsyncHandler — synchronous multi-frame (Android's native pattern) ─────

    @Test
    public void asyncHandler_synchronousEmit_multipleFramesArriveBeforeReturn() throws Exception {
        Fixture fixture = new Fixture();
        // Android AsyncHandler fires emitter synchronously inside handle().
        // All frames are in transport.sentMessages before deliver() returns.
        fixture.bridge.registerAsyncHandler("multi", (ctx, payload, emitter) -> {
            emitter.success(jsonOf("seq", 1), false);
            emitter.success(jsonOf("seq", 2), false);
            emitter.success(jsonOf("seq", 3), true);
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "multi", sessionId, "{}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(3, frames.size());
        // 前两帧 done=false
        assertFalse(frames.get(0).optBoolean("done"));
        assertEquals(1, frames.get(0).optJSONObject("payload").optInt("seq"));
        assertFalse(frames.get(1).optBoolean("done"));
        assertEquals(2, frames.get(1).optJSONObject("payload").optInt("seq"));
        // 最后一帧 done=true
        assertTrue(frames.get(2).optBoolean("done"));
        assertEquals(3, frames.get(2).optJSONObject("payload").optInt("seq"));
    }

    @Test
    public void asyncHandler_emitError_sendsFailureFrame() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerAsyncHandler("failing", (ctx, payload, emitter) ->
                emitter.fail(new BridgeError("E_CUSTOM", "custom error")));
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "failing", sessionId, "{}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(1, frames.size());
        assertFalse(frames.get(0).optBoolean("ok"));
        JSONObject error = frames.get(0).optJSONObject("error");
        assertNotNull(error);
        assertEquals("E_CUSTOM", error.optString("code"));
        assertEquals("custom error", error.optString("message"));
    }

    @Test
    public void asyncHandler_throwsException_normalizedToInternal() {
        Fixture fixture = new Fixture();
        fixture.bridge.registerAsyncHandler("throws", (ctx, payload, emitter) -> {
            throw new IllegalStateException("handler exploded");
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "throws", sessionId, "{}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(1, frames.size());
        assertFalse(frames.get(0).optBoolean("ok"));
        assertEquals(BridgeApiContract.ERR_INTERNAL,
                frames.get(0).optJSONObject("error").optString("code"));
    }

    @Test
    public void asyncHandler_receivesTrustedPageContext() {
        Fixture fixture = new Fixture();
        List<TrustedPageContext> seen = new ArrayList<>();
        fixture.bridge.registerAsyncHandler("multi", (ctx, payload, emitter) -> {
            seen.add(ctx);
            emitter.success(jsonOf("ok", true), true);
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "multi", sessionId, "{}"));

        assertEquals(1, seen.size());
        assertEquals("file://", seen.get(0).getOrigin());
    }

    // ── AsyncHandler — background thread emit (true async on Android) ─────────

    @Test
    public void asyncHandler_backgroundThread_framesArrive() throws Exception {
        // 验证 Android 真正的后台推送场景：持有 emitter 并从另一个线程调用
        Fixture fixture = new Fixture();
        CountDownLatch done = new CountDownLatch(1);

        fixture.bridge.registerAsyncHandler("bg", (ctx, payload, emitter) -> {
            ScheduledExecutorService exec = Executors.newSingleThreadScheduledExecutor();
            // 首帧立即同步
            emitter.success(jsonOf("seq", 0), false);
            // 后续帧来自后台线程
            exec.schedule(() -> {
                emitter.success(jsonOf("seq", 1), false);
                emitter.success(jsonOf("seq", 2), true);
                exec.shutdown();
                done.countDown();
            }, 20, TimeUnit.MILLISECONDS);
        });

        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "bg", sessionId, "{}"));

        // 等待后台线程完成
        assertTrue("background frames did not arrive in time", done.await(2, TimeUnit.SECONDS));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(3, frames.size());
        assertFalse(frames.get(0).optBoolean("done"));
        assertFalse(frames.get(1).optBoolean("done"));
        assertTrue(frames.get(2).optBoolean("done"));
        assertEquals(2, frames.get(2).optJSONObject("payload").optInt("seq"));
    }

    // ── ResponseEmitter — reqId links all frames to the original request ───────

    @Test
    public void allFrames_carryReqIdOfOriginalRequest() throws Exception {
        Fixture fixture = new Fixture();
        fixture.bridge.registerAsyncHandler("multi", (ctx, payload, emitter) -> {
            emitter.success(jsonOf("n", 1), false);
            emitter.success(jsonOf("n", 2), true);
        });
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("myReqId", "multi", sessionId, "{}"));

        // 每帧的 reqId 必须等于请求的 id
        List<JSONObject> frames = fixture.transport.framesForReqId("myReqId");
        assertEquals(2, frames.size());
        for (JSONObject frame : frames) {
            assertEquals("myReqId", frame.optString("reqId"));
            assertEquals("response", frame.optString("kind"));
        }
    }

    @Test
    public void allFrames_carryMethodOfOriginalRequest() throws Exception {
        Fixture fixture = new Fixture();
        fixture.bridge.registerAsyncHandler("myMethod", (ctx, payload, emitter) ->
                emitter.success(jsonOf("x", 1), true));
        fixture.bridge.resetPageInstance();
        fixture.bridge.resetTransport();
        String sessionId = handshake(fixture);

        fixture.transport.deliver(requestJson("r1", "myMethod", sessionId, "{}"));

        List<JSONObject> frames = fixture.transport.framesForReqId("r1");
        assertEquals(1, frames.size());
        assertEquals("myMethod", frames.get(0).optString("method"));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private static String handshake(Fixture fixture) {
        return BridgeTestSupport.handshakeSessionId(fixture.transport);
    }

    private static final class Fixture {
        final FakeBridgeTransport transport = new FakeBridgeTransport();
        final JsBridge bridge;

        Fixture() {
            JsBridge.SecurityConfig securityConfig = new JsBridge.SecurityConfig()
                    .allowedOrigins(new HashSet<>(Arrays.asList("file://")))
                    .methodWhitelist(new HashSet<>(Arrays.asList(
                            BridgeApiContract.METHOD_HANDSHAKE,
                            "greet", "echo", "boom", "multi", "failing", "throws", "bg", "myMethod")));
            bridge = new JsBridge(
                    transport,
                    new FixedContextProvider("file://"),
                    securityConfig);
        }
    }

    private static final class FixedContextProvider implements PageContextProvider {
        private final String origin;

        FixedContextProvider(String origin) {
            this.origin = origin;
        }

        @Override
        public TrustedPageContext createContext(
                io.github.xesam.android.bridge.api.model.BridgeMessage message,
                String pageInstanceId) {
            return new TrustedPageContext(origin, pageInstanceId);
        }
    }
}
