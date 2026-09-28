package io.github.xesam.android.bridge.extensions.system;

import android.os.Build;
import android.util.Log;
import android.webkit.WebView;

import androidx.annotation.Nullable;

import java.util.Objects;
import java.util.concurrent.atomic.AtomicInteger;

import io.github.xesam.android.bridge.core.transport.BridgeTransport;

/**
 * v1 裁决（docs/06 信道建立机制 / docs/04 §3.1 通道建立入口契约）：现代路径（API ≥ M）为
 * pull 模型——bind() 不再主动投递端口，只轮换绑定周期；通道由 JS 发起
 * {@code __jsbridge2__.requestBridgeChannel(opts)} 按需建立。
 *
 * 哑入口注入时机（关键）：随**构造**注入（宿主创建 transport 早于 loadUrl），
 * 而非随 bind 注入——页面脚本执行早于 onPageFinished，若入口在 onPageFinished
 * 才注入，页面起手请求必然扑空；且活页中反复 remove/addJavascriptInterface
 * 在部分 WebView 版本上不可靠。入口跨 bind 轮换存活，陈旧请求由 epoch 与
 * JS 侧 reqId 相关性双重防呆。
 *
 * 宿主 invalidate 语义（docs/04 §3.1 宿主 invalidate 职责）：每次 bind()（导航时宿主调用 resetTransport()）
 * 轮换 epoch 并关闭旧通道；"忘记 invalidate"由 conformance 桩断言（docs/04 C42）
 * 与 JS 侧 reqId 超时自愈兜底。
 */
public final class AndroidWebViewBridgeTransport implements BridgeTransport {
    static final String JS_PROXY = "__jsbridge2__";
    static final int MAX_CHANNEL_REQUESTS_PER_BIND = 64;
    /** bind 前暂存队列容量（conformance C47）。页面脚本解析期通常只发 1 个请求；
     * 与限频上限保持一致，超限丢最旧。 */
    static final int MAX_PENDING_CHANNEL_REQUESTS = MAX_CHANNEL_REQUESTS_PER_BIND;
    private static final String TAG = "JsBridgeChannel";

    private final WebView webView;
    private final PendingChannelRequests pendingRequests = new PendingChannelRequests(MAX_PENDING_CHANNEL_REQUESTS);

    // bind 发布监听器/补投 与 哑入口回调 入队/投递 的互斥锁：
    // 关闭"回调读到旧 listener 判 null → offer 却落在 bind 已 drain 之后 → 请求滞留至下次 bind"
    // 的丢失窗口（conformance C47 语义闭环）。锁内只做纯逻辑（入队/post runnable），无 WebView 操作。
    private final Object bindGate = new Object();

    // 跨线程可见性：channel/pendingListener/epoch 由宿主线程（bind/close/UI runnable）写、
    // JS bridge 线程（requestBridgeChannel 回调）与发送方线程读，需 volatile/原子可见；
    // epoch 递增只发生在宿主线程串行的 bind()，AtomicInteger 保证即可
    @Nullable
    private volatile MessageChannel channel;
    @Nullable
    private volatile Listener pendingListener;
    @Nullable
    private final ChannelRequestJavascriptInterface requestInterface;
    private final AtomicInteger epoch = new AtomicInteger(0);

    public AndroidWebViewBridgeTransport(WebView webView) {
        this.webView = Objects.requireNonNull(webView, "webView == null");
        ChannelRequestJavascriptInterface injected = null;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // 哑入口随构造注入（早于 loadUrl），跨 bind 轮换存活
            injected = new ChannelRequestJavascriptInterface(
                    this::onChannelRequested,
                    MAX_CHANNEL_REQUESTS_PER_BIND);
            webView.addJavascriptInterface(injected, JS_PROXY);
        }
        this.requestInterface = injected;
    }

    @Override
    public void bind(Listener listener) {
        Objects.requireNonNull(listener, "listener == null");
        closeChannel();
        pendingListener = null;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            // legacy 路径（API < M）：无 postWebMessage 能力，维持既有 pull 形态（直调通道）
            LegacyJavascriptChannel legacy = new LegacyJavascriptChannel(webView);
            legacy.setListener(listener::onMessage);
            channel = legacy;
            return;
        }
        // 现代路径（pull）：轮换绑定周期；通道由 requestBridgeChannel 按需建立
        epoch.incrementAndGet();
        // 兑现 per-bind 限频语义：bind 轮换重置哑入口的请求计数，
        // 每个绑定周期重新拥有 MAX_CHANNEL_REQUESTS_PER_BIND 的额度
        if (requestInterface != null) {
            requestInterface.resetForNewBind();
        }
        // 监听器发布与补投同锁（bindGate）：与 onChannelRequested 的"读 listener→入队/投递"
        // 互斥，杜绝"offer 落在本轮 flush 之后"的丢失窗口。bind 前到达的请求此刻补投
        // （conformance C47）——latest-wins：只补投最新 reqId，被取代的旧请求不补投
        // （旧 reqId 端口 JS 侧不采纳，补投只会造成端口空转，docs/06 §5.3）
        final String latestPending;
        synchronized (bindGate) {
            pendingListener = listener;
            latestPending = pendingRequests.pollLatest();
        }
        if (latestPending != null) {
            Log.d(TAG, "flush pending channel request reqId=" + latestPending);
            deliverOnUiThread(latestPending, epoch.get(), listener);
        }
    }

    /** 哑入口回调（JS bridge 线程）→ 与 bind 发布互斥；WebView 操作 hop 到 UI 线程执行。 */
    private void onChannelRequested(final String reqId) {
        final Listener listener;
        final int bindEpoch;
        synchronized (bindGate) {
            listener = pendingListener;
            if (listener == null) {
                // bind 前到达（页面脚本解析早于 onPageFinished）：暂存待补投，不丢弃。
                // 丢弃会迫使 JS 侧等 channelTimeoutMs 超时 + 退避重试（实测约 2.5s）。
                pendingRequests.offer(reqId);
                Log.d(TAG, "queue channel request reqId=" + reqId + " pending=" + pendingRequests.size());
                return;
            }
            bindEpoch = epoch.get();
        }
        deliverOnUiThread(reqId, bindEpoch, listener);
    }

    /** 跳 UI 线程建通道投递；epoch 已轮换则丢弃陈旧请求。 */
    private void deliverOnUiThread(final String reqId, final int bindEpoch, final Listener listener) {
        webView.post(() -> {
            Log.d(TAG, "UI runnable run reqId=" + reqId + " bindEpoch=" + bindEpoch + " currentEpoch=" + epoch);
            if (bindEpoch != epoch.get()) {
                Log.w(TAG, "drop stale channel request reqId=" + reqId + " (epoch rotated)");
                return;
            }
            // 轮换粗语义：每请求建新对、旧对关闭（docs/06 §4.1/§4.3，in-flight 丢弃由上层超时恢复）
            closeChannel();
            MessageChannel newChannel =
                    new WebMessageChannelBootstrapper().deliverChannelForRequest(webView, listener::onMessage, reqId);
            Log.d(TAG, "deliverChannelForRequest reqId=" + reqId + " -> " + (newChannel != null ? "delivered" : "null"));
            if (newChannel != null) {
                channel = newChannel;
            }
        });
    }

    @Override
    public boolean send(String messageJson) {
        final MessageChannel current = channel;
        if (current == null) {
            return false;
        }
        try {
            current.send(messageJson);
        } catch (Exception e) {
            // 发送链异常闭环：WebView 异常（端口已失效 / WebView 已销毁等）
            // 不得穿透给 CoreBridge / 回调线程——吞异常返回 false，
            // 由 CoreBridge 计入 sendFailureCount 并告警（docs/03 发送闭环）
            Log.w(TAG, "channel send failed: " + e);
            return false;
        }
        return true;
    }

    @Override
    public void close() {
        synchronized (bindGate) {
            pendingListener = null;
            pendingRequests.clear();
        }
        closeChannel();
        // 哑入口不移除：close 同时服务于 bind 轮换与 destroy，活页中 removeJavascriptInterface
        // 不可靠；WebView 销毁时随 WebView 回收（陈旧请求由 epoch 防呆）
    }

    private void closeChannel() {
        final MessageChannel current = channel;
        channel = null;
        if (current != null) {
            current.close();
        }
    }
}
