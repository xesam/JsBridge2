package io.github.xesam.android.bridge.extensions.system;

import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebView;

import androidx.annotation.Nullable;

import org.json.JSONObject;

/**
 * legacy 路径（API &lt; M）的 pull 形态直调通道：{@code addJavascriptInterface} 注入
 * {@code __jsbridge2__}，JS 经 {@code callNativeApi} 直调入站，Native 经
 * {@code evaluateJavascript} 直调出站。
 *
 * WebView 线程纪律（docs/07 transport 边界）：{@code evaluateJavascript} /
 * {@code removeJavascriptInterface} 必须在 WebView 构建线程（主线程）执行——
 * 入站回调运行在 WebView 的 JavaBridge 后台线程、handler 后台线程也会直接
 * {@code send()}，非主线程的出站与清理一律 post 到主线程；入站消息同样 hop 到
 * 主线程再派发（provider 的 {@code webView.getUrl()} 与分发逻辑由此与
 * WebMessageListener 现代路径的线程模型对齐）。JVM 单测无 Looper 环境时
 * 退化为直调，保持 Mock 可测（Looper.getMainLooper() == null 分支）。
 */
public final class LegacyJavascriptChannel implements MessageChannel {
    private static final String NATIVE_PROXY = "__jsbridge2__";

    private final WebView webView;
    private final InboundBridgeInterface inboundBridgeInterface;

    /** 跨线程可见：UI 线程写（setListener/close）、JavaBridge 后台线程读（callNativeApi）。 */
    @Nullable
    private volatile Listener listener;

    public LegacyJavascriptChannel(WebView webView) {
        this.webView = webView;
        this.inboundBridgeInterface = new InboundBridgeInterface();
        this.webView.addJavascriptInterface(inboundBridgeInterface, NATIVE_PROXY);
    }

    @Override
    public void setListener(Listener listener) {
        this.listener = listener;
    }

    @Override
    public void send(String messageJson) {
        final String payload = JSONObject.quote(messageJson);
        final String js = "window.__jsbridge2__ && window.__jsbridge2__.receive && "
                + "window.__jsbridge2__.receive(" + payload + ");";
        runOnWebViewThread(() -> evaluateIntoPage(js));
    }

    @Override
    public void close() {
        listener = null;
        runOnWebViewThread(() -> webView.removeJavascriptInterface(NATIVE_PROXY));
    }

    private void evaluateIntoPage(String js) {
        // minSdk 21 ≥ KITKAT(19)：evaluateJavascript 恒可用，无需 loadUrl("javascript:") 回退
        webView.evaluateJavascript(js, (ValueCallback<String>) null);
    }

    /** 非主线程一律 post 到主线程；JVM 单测无 Looper 环境退化为直调（Mock 可测）。 */
    private void runOnWebViewThread(Runnable action) {
        if (Looper.getMainLooper() != null && Looper.myLooper() != Looper.getMainLooper()) {
            webView.post(action);
        } else {
            action.run();
        }
    }

    private final class InboundBridgeInterface {
        @JavascriptInterface
        public void callNativeApi(String messageJson) {
            final Listener current = listener;
            if (current == null) {
                return;
            }
            // 入站 hop 到主线程：provider.createContext（webView.getUrl()）与分发
            // 线程要求对齐现代路径；close() 后到达的迟入站消息由 volatile 读再次防御
            runOnWebViewThread(() -> {
                final Listener listenerAtDelivery = LegacyJavascriptChannel.this.listener;
                if (listenerAtDelivery != null) {
                    listenerAtDelivery.onMessage(messageJson);
                }
            });
        }
    }
}
