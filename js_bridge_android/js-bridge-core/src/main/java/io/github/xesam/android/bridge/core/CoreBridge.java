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
import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.android.bridge.core.transport.BridgeTransport;

/**
 * Tier 1 — 核心协议层。
 * 纯消息分发，零 security 依赖。
 * 提供 transport 绑定、handler 注册、dispatch、响应发送、事件推送。
 */
public final class CoreBridge {
    private static final Logger LOGGER = Logger.getLogger(CoreBridge.class.getName());

    private volatile BridgeTransport transport;
    private final Map<String, SimpleNativeMessageHandler> handlers = new ConcurrentHashMap<>();
    private final AtomicInteger sendFailureCount = new AtomicInteger(0);

    public CoreBridge(BridgeTransport transport) {
        this.transport = Objects.requireNonNull(transport, "transport == null");
    }

    public void attachTransport(BridgeTransport transport) {
        this.transport = Objects.requireNonNull(transport, "transport == null");
    }

    public int getSendFailureCount() {
        return sendFailureCount.get();
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

    public void registerHandler(String method, SimpleNativeMessageHandler handler) {
        Objects.requireNonNull(handler, "handler == null");
        handlers.put(method, handler);
    }

    /**
     * 分发消息到已注册的 SimpleNativeMessageHandler。
     * JsBridge 在策略通过后委托此方法。
     */
    public void dispatch(BridgeMessage message) {
        SimpleNativeMessageHandler handler = handlers.get(message.getMethod());
        if (handler == null) {
            respondFail(message, new BridgeError(
                    BridgeApiContract.ERR_METHOD_NOT_FOUND,
                    "Method not found: " + message.getMethod()));
            return;
        }
        try {
            handler.handle(
                    message.getPayload() == null ? new JSONObject() : message.getPayload(),
                    new MessageHandlerCallback() {
                        @Override
                        public void success(Object res) {
                            respondSuccess(message, res, true);
                        }

                        @Override
                        public void success(Object res, boolean done) {
                            respondSuccess(message, res, done);
                        }

                        @Override
                        public void fail(Object error) {
                            respondFail(message, BridgeError.normalize(error));
                        }
                    });
        } catch (Throwable throwable) {
            respondFail(message, BridgeError.normalize(throwable));
        }
    }

    public boolean postEvent(String method, Object payload) {
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
    }

    public void destroy() {
        BridgeTransport t = transport;
        if (t != null) {
            t.close();
        }
    }

    // ── 响应发送：JsBridge 策略层和 handler 回调均通过此方法发送响应 ──

    public void respondSuccess(BridgeMessage request, Object payload, boolean done) {
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
    }

    public void respondFail(BridgeMessage request, BridgeError bridgeError) {
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
    }

    private void autoDispatch(String messageJson) {
        BridgeMessage message = BridgeMessage.fromJson(messageJson);
        if (message != null) {
            dispatch(message);
        }
    }
}
