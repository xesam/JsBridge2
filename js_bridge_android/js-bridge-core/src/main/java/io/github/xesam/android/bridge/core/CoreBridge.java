package io.github.xesam.android.bridge.core;

import org.json.JSONObject;

import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.logging.Logger;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.android.bridge.core.handler.SimpleHandler;
import io.github.xesam.android.bridge.core.transport.BridgeTransport;

/**
 * Tier 1 — 核心协议层。
 * 纯消息分发，零 security 依赖。
 * 提供 transport 绑定、handler 注册、dispatch、响应发送、事件推送。
 *
 * <p>Handler 注册表面固定为两态：{@link #registerSimpleHandler}（恰好一帧）与
 * {@link #registerAsyncHandler}（可多帧），二者共用**单一注册表**，同一 method
 * 重复注册时后者覆盖前者（见 docs/09-conformance.md C49）。
 */
public final class CoreBridge {
    private static final Logger LOGGER = Logger.getLogger(CoreBridge.class.getName());

    /** Tier 1 standalone 未叠加 security 层，不存在可信上下文的来源。 */
    private static final TrustedPageContext NO_CONTEXT = new TrustedPageContext("", "");

    private volatile BridgeTransport transport;
    private final Map<String, HandlerEntry> handlers = new ConcurrentHashMap<>();
    private final AtomicInteger sendFailureCount = new AtomicInteger(0);

    public CoreBridge(BridgeTransport transport) {
        this.transport = Objects.requireNonNull(transport, "transport == null");
    }

    public void attachTransport(BridgeTransport transport) {
        this.transport = Objects.requireNonNull(transport, "transport == null");
    }

    /**
     * 绑定 transport，接收消息后自动解析并 dispatch。
     * 用于 CoreBridge 独立使用（Tier 1 standalone）。
     */
    public void bind() {
        transport.bind(this::autoDispatch);
    }

    /**
     * 绑定 transport，消息转发给指定 listener。
     * 用于 JsBridge 拦截入口（Tier 2 叠加）。
     */
    public void bind(BridgeTransport.Listener listener) {
        transport.bind(listener);
    }

    // MARK: - Handler 注册（两态，后注册覆盖先注册）

    /**
     * 注册 Simple Handler: 单返回值，通信在返回时结束（恰好一帧，done 恒为 true）
     */
    public void registerSimpleHandler(String method, SimpleHandler handler) {
        Objects.requireNonNull(handler, "handler == null");
        handlers.put(method, new SimpleEntry(this, handler));
    }

    /**
     * 注册 Async Handler: 带 ResponseEmitter 参数，可在返回后继续推帧
     */
    public void registerAsyncHandler(String method, AsyncHandler handler) {
        Objects.requireNonNull(handler, "handler == null");
        handlers.put(method, new AsyncEntry(this, handler));
    }

    /**
     * 内部分发体——Simple / Async 两态的联合，对外不暴露第三种注册形态。
     */
    private interface HandlerEntry {
        void dispatch(BridgeMessage request, TrustedPageContext context, JSONObject payload);
    }

    private static final class SimpleEntry implements HandlerEntry {
        private final CoreBridge bridge;
        private final SimpleHandler handler;

        SimpleEntry(CoreBridge bridge, SimpleHandler handler) {
            this.bridge = bridge;
            this.handler = handler;
        }

        @Override
        public void dispatch(BridgeMessage request, TrustedPageContext context, JSONObject payload) {
            try {
                bridge.respondSuccess(request, handler.handle(context, payload), true);
            } catch (Throwable throwable) {
                bridge.respondFail(request, BridgeError.normalize(throwable));
            }
        }
    }

    private static final class AsyncEntry implements HandlerEntry {
        private final CoreBridge bridge;
        private final AsyncHandler handler;

        AsyncEntry(CoreBridge bridge, AsyncHandler handler) {
            this.bridge = bridge;
            this.handler = handler;
        }

        @Override
        public void dispatch(BridgeMessage request, TrustedPageContext context, JSONObject payload) {
            ResponseEmitter emitter = new ResponseEmitter() {
                @Override
                public void success(Object payload, boolean done) {
                    bridge.respondSuccess(request, payload, done);
                }

                @Override
                public void fail(BridgeError error) {
                    bridge.respondFail(request, error);
                }
            };
            try {
                handler.handle(context, payload, emitter);
            } catch (Throwable throwable) {
                bridge.respondFail(request, BridgeError.normalize(throwable));
            }
        }
    }

    // MARK: - Dispatch

    /**
     * 分发消息到已注册的 handler。
     * JsBridge 在策略通过后委托此方法，并传入策略求值时使用的可信上下文。
     */
    public void dispatch(BridgeMessage message, TrustedPageContext context) {
        // Tier-1 kind 路由守卫（docs/09 C64 / docs/08 dispatch 契约）：仅 request 信封参与派发。
        // response/event 是 Native→JS 方向（docs/03 §1），standalone 使用 CoreBridge 时按 method
        // 命中同名 handler 属协议路由错误而非"无策略"自由；JsBridge 路径已在策略链
        // RequestShapePolicy 先行拒绝，此处为 belt-and-braces。
        if (!message.isRequest()) {
            LOGGER.warning("bridge_dispatch_dropped reason=non_request_kind method="
                    + message.getMethod() + " reqId=" + message.getId());
            return;
        }
        HandlerEntry handler = handlers.get(message.getMethod());
        if (handler == null) {
            respondFail(message, new BridgeError(
                    BridgeApiContract.ERR_METHOD_NOT_FOUND,
                    "Method not found: " + message.getMethod()));
            return;
        }
        Object rawPayload = message.getPayload();
        JSONObject payload = rawPayload instanceof JSONObject ? (JSONObject) rawPayload : new JSONObject();
        TrustedPageContext effectiveContext = context == null ? NO_CONTEXT : context;
        try {
            handler.dispatch(message, effectiveContext, payload);
        } catch (Throwable throwable) {
            respondFail(message, BridgeError.normalize(throwable));
        }
    }

    public boolean postEvent(String method, Object payload) {
        try {
            BridgeTransport t = transport;
            if (t == null) {
                sendFailureCount.incrementAndGet();
                return false;
            }
            boolean sent = t.send(BridgeMessage.createEvent(method, payload).toJsonString());
            if (!sent) {
                sendFailureCount.incrementAndGet();
                LOGGER.warning("bridge_send_failed kind=event method=" + method);
            }
            return sent;
        } catch (Throwable throwable) {
            // 发送链异常闭环：序列化（toJsonString 可把 JSONException 包成 RuntimeException）
            // 与传输异常吞掉，永不向调用方抛——否则 LifecycleExtension 等宿主侧调用链被穿透
            sendFailureCount.incrementAndGet();
            LOGGER.warning("bridge_send_failed kind=event method=" + method + " throwable=" + throwable);
            return false;
        }
    }

    public void destroy() {
        BridgeTransport t = transport;
        if (t != null) {
            t.close();
        }
    }

    // ── 响应发送：JsBridge 策略层和 handler 回调均通过此方法发送响应 ──
    // 发送链异常闭环：整体包 try/catch（Throwable），失败计入 sendFailureCount 并告警，
    // 永不向调用方抛——否则 Simple/Async/dispatch 三层 catch 会连环调用 respondFail
    // 造成异常穿透到 WebView 回调线程（docs/03 §3.4 发送闭环 / conformance C17）

    public void respondSuccess(BridgeMessage request, Object payload, boolean done) {
        try {
            BridgeTransport t = transport;
            if (t == null) {
                sendFailureCount.incrementAndGet();
                LOGGER.warning("bridge_send_failed kind=response method=" + request.getMethod()
                        + " reqId=" + request.getId() + " ok=true transport=null");
                return;
            }
            BridgeMessage response = BridgeMessage.createSuccessResponse(request, payload, done);
            if (!t.send(response.toJsonString())) {
                sendFailureCount.incrementAndGet();
                LOGGER.warning("bridge_send_failed kind=response method=" + request.getMethod()
                        + " reqId=" + request.getId() + " ok=true");
            }
        } catch (Throwable throwable) {
            sendFailureCount.incrementAndGet();
            LOGGER.warning("bridge_send_failed kind=response reqId="
                    + (request == null ? "null" : request.getId())
                    + " ok=true throwable=" + throwable);
        }
    }

    public void respondFail(BridgeMessage request, BridgeError bridgeError) {
        try {
            // 与下方 catch 分支的 null 防御对称：request 为 null 时不得裸调 getMethod()/getId()
            if (request == null) {
                sendFailureCount.incrementAndGet();
                LOGGER.warning("bridge_send_failed kind=response reqId=null ok=false request=null");
                return;
            }
            BridgeTransport t = transport;
            if (t == null) {
                sendFailureCount.incrementAndGet();
                LOGGER.warning("bridge_send_failed kind=response method=" + request.getMethod()
                        + " reqId=" + request.getId() + " ok=false transport=null");
                return;
            }
            BridgeMessage response = BridgeMessage.createFailResponse(request, bridgeError);
            if (!t.send(response.toJsonString())) {
                sendFailureCount.incrementAndGet();
                LOGGER.warning("bridge_send_failed kind=response method=" + request.getMethod()
                        + " reqId=" + request.getId() + " ok=false");
            }
        } catch (Throwable throwable) {
            sendFailureCount.incrementAndGet();
            LOGGER.warning("bridge_send_failed kind=response reqId="
                    + (request == null ? "null" : request.getId())
                    + " ok=false throwable=" + throwable);
        }
    }

    private void autoDispatch(String messageJson) {
        BridgeMessage message = BridgeMessage.fromJson(messageJson);
        if (message != null) {
            dispatch(message, NO_CONTEXT);
        }
    }
}
