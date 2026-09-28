package io.github.xesam.android.bridge.extensions.system;

import android.webkit.JavascriptInterface;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONObject;

import java.util.Objects;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.LongSupplier;

/**
 * 通道建立哑入口（v1 裁决，docs/04 §3.1 通道建立入口契约 / docs/06 信道建立机制）。
 *
 * pull 模型的 transport 控制面原语：JS 主动发起 {@code __jsbridge2__.requestBridgeChannel(opts)}，
 * Native 收到后建 WebMessageChannel 并以 {@code bridge:channel} 信封投递页面半端口。
 *
 * 契约要点：
 * - 只做一件事（触发建通道），不承载数据、不暴露能力——真正的信任边界仍是握手门控；
 * - 收可选 JSON 参数，忽略未知字段（reqId 为第一个正式字段，由 JS transport 生成）；
 * - ack 四态禁止静默：匹配回显 reqId / rate_limited / 入口不存在（老宿主）/ malformed；
 * - 限频数值由宿主/transport 自定（docs/04 §3.1：资源守卫，数值归实现层）。
 *
 * 限频语义（防一次性额度烧毁 DoS）：{@code addJavascriptInterface} 注入对象对页面内
 * **所有 frame 可见**（跨域 iframe 与主 frame 共享同一哑入口与额度，Android 平台层无
 * frame 归因能力——对照 iOS C58 的 WKScriptMessageHandler frame 信息）。因此额度除
 * per-bind 轮换外追加**空闲复充**：距上次请求超过 {@code windowMs} 即视为新一轮、
 * 额度归位。恶意 iframe 一次性烧光 MAX 后只能造成 windowMs 级的暂时不可用（此前为
 * "直到下次导航"整页 bridge 不可用）；持续洪泛期间的受限为已登记平台限制
 * （docs/09-conformance.md §4）。
 */
final class ChannelRequestJavascriptInterface {
    /** 默认空闲复充窗口：一轮额度耗尽后，静默期超过该时长即可重新建通道。 */
    static final long DEFAULT_WINDOW_MS = 30_000L;

    interface Callback {
        /** 在任意线程回调；实现方自行负责 hop 到 UI 线程执行 WebView 操作。 */
        void onChannelRequested(@NonNull String reqId);
    }

    private final Callback callback;
    private final int maxRequests;
    private final long windowMs;
    private final LongSupplier timeSource;
    private final AtomicInteger requestCount = new AtomicInteger();
    /** 上次请求时间戳（timeSource 单位）；构造期锚定窗口起点，由 monitor 保护（requestCount 靠 AtomicInteger 自身原子性）。 */
    private long lastRequestAt;

    ChannelRequestJavascriptInterface(@NonNull Callback callback, int maxRequests) {
        this(callback, maxRequests, DEFAULT_WINDOW_MS, System::nanoTime);
    }

    ChannelRequestJavascriptInterface(
            @NonNull Callback callback,
            int maxRequests,
            long windowMs,
            @NonNull LongSupplier timeSource) {
        this.callback = Objects.requireNonNull(callback, "callback == null");
        this.maxRequests = maxRequests;
        this.windowMs = Math.max(1L, windowMs);
        this.timeSource = Objects.requireNonNull(timeSource, "timeSource == null");
        // 构造期锚定空闲窗口起点：避免以 0 为"未初始化"哨兵——注入时钟（含 nanoTime
        // 恰为 0）会与哨兵语义冲突，导致每个 t=0 请求都被误判为新窗口
        this.lastRequestAt = timeSource.getAsLong();
    }

    @JavascriptInterface
    public String requestBridgeChannel(String optsJson) {
        final String reqId = extractReqId(optsJson);
        if (reqId == null) {
            // ack 四态之"请求畸形"
            return errorAck("malformed");
        }
        if (!tryAcquire()) {
            // ack 四态之"限频"——JS 侧应退避后换新 reqId 重试；
            // 空闲复充窗口过后额度自动归位，无需等待下一次导航 bind
            return errorAck("rate_limited");
        }
        callback.onChannelRequested(reqId);
        try {
            JSONObject ack = new JSONObject();
            ack.put("ok", true);
            ack.put("reqId", reqId);
            return ack.toString();
        } catch (Exception e) {
            return errorAck("malformed");
        }
    }

    /** bind 轮换时重置限频计数（兑现 maxRequests 的 per-bind 语义：每个绑定周期独立额度）。 */
    void resetForNewBind() {
        requestCount.set(0);
    }

    /**
     * 带空闲复充的额度判定：距上次请求超过 windowMs → 额度归位后重新计数；
     * 否则 per-bind 计数累加，超过 maxRequests 返回 false（rate_limited）。
     */
    private synchronized boolean tryAcquire() {
        final long now = timeSource.getAsLong();
        // 构造期已锚定 lastRequestAt（见构造器）：此处只需空闲判定，无哨兵特判。
        // 差值比较对 nanoTime 任意起点（含负值/0）均安全；窗口起点由构造期锚定。
        if (now - lastRequestAt > windowMs * 1_000_000L) {
            requestCount.set(0);
        }
        lastRequestAt = now;
        return requestCount.incrementAndGet() <= maxRequests;
    }

    /** 忽略未知字段，仅提取 reqId；非法 JSON / 缺失 reqId / 非字符串 → null。 */
    @Nullable
    private static String extractReqId(@Nullable String optsJson) {
        if (optsJson == null) {
            return null;
        }
        try {
            JSONObject opts = new JSONObject(optsJson);
            String reqId = opts.optString("reqId", "");
            return reqId.isEmpty() ? null : reqId;
        } catch (Exception e) {
            return null;
        }
    }

    private static String errorAck(String error) {
        try {
            JSONObject ack = new JSONObject();
            ack.put("error", error);
            return ack.toString();
        } catch (Exception e) {
            // JSONObject.put 理论不可达异常；退化仍保证非静默
            return "{\"error\":\"internal\"}";
        }
    }
}
