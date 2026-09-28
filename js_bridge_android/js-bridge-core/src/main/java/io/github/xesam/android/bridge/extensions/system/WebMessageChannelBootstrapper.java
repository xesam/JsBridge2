package io.github.xesam.android.bridge.extensions.system;

import android.net.Uri;
import android.util.Log;
import android.os.Build;
import android.webkit.WebMessage;
import android.webkit.WebMessagePort;
import android.webkit.WebView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONObject;

import java.util.Objects;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;

/**
 * v1 裁决（docs/06 §1）：信道建立从 push（onPageFinished 一次性投递）改为 pull
 * （JS 主动 requestBridgeChannel）。因果序：JS 挂监听 →causes→ JS 发请求 →causes→
 * Native 建通道投递——消除"投递早于监听挂载则端口永久丢失"的跨进程时序依赖
 * （docs/01 §4.1）。
 *
 * <p>push bootstrap 形态已随 v1 移除——禁止再次引入"onPageFinished 一次性投递"
 * 形态（会重新引入时序竞态），页面对通道的获取一律经
 * {@link #deliverChannelForRequest} 的 pull 路径。</p>
 */
public final class WebMessageChannelBootstrapper {
    private static final Uri TARGET_ANY = Uri.parse("*");

    /**
     * pull：为一次 requestBridgeChannel(reqId) 建新端口对，并把页面半端口以
     * {@code bridge:channel} 信封投递给页面。须在 UI 线程调用。
     *
     * 轮换粗语义（docs/06 §4.1/§4.3）：每请求建新对、旧对关闭——旧端口上 in-flight
     * 下行消息被丢弃，上层超时负责恢复（写入契约的丢弃语义）。
     *
     * @return Native 半端口包装的 channel；投递失败时关闭两个 port 并返回 null（JS 侧靠 reqId 超时重试自愈）
     */
    @Nullable
    public WebMessagePortMessageChannel deliverChannelForRequest(
            @NonNull WebView webView, @NonNull MessageChannel.Listener listener, @NonNull String reqId) {
        Objects.requireNonNull(webView, "webView == null");
        Objects.requireNonNull(listener, "listener == null");
        Objects.requireNonNull(reqId, "reqId == null");
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null;
        }
        WebMessagePort[] ports = webView.createWebMessageChannel();
        WebMessagePort nativePort = ports[0];
        WebMessagePort pagePort = ports[1];
        try {
            WebMessagePortMessageChannel channel = new WebMessagePortMessageChannel(nativePort);
            // 在 postWebMessage 前设置 callback，避免竞态条件导致早期消息丢失（Native 半端口对称保护）
            channel.setListener(listener);
            JSONObject envelope = new JSONObject();
            envelope.put("type", BridgeApiContract.CHANNEL_EVENT_TYPE);
            envelope.put("reqId", reqId);
            webView.postWebMessage(new WebMessage(envelope.toString(), new WebMessagePort[]{pagePort}), TARGET_ANY);
            Log.d("JsBridgeChannel", "postWebMessage envelope=" + envelope + " (page port delivered)");
            return channel;
        } catch (Exception e) {
            Log.w("JsBridgeChannel", "deliverChannelForRequest failed", e);
            // 投递失败需清理两个 port 避免泄漏；JS 侧在 T 内无匹配投递会换新 reqId 重试（自愈）
            nativePort.close();
            pagePort.close();
            return null;
        }
    }
}
