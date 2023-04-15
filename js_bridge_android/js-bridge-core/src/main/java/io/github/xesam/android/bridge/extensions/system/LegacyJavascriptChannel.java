package io.github.xesam.android.bridge.extensions.system;

import android.os.Build;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebView;

import androidx.annotation.Nullable;

import org.json.JSONObject;

public final class LegacyJavascriptChannel implements MessageChannel {
    private static final String NATIVE_PROXY = "$__native__";

    private final WebView webView;
    private final InboundBridgeInterface inboundBridgeInterface;

    @Nullable
    private Listener listener;

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
        String payload = JSONObject.quote(messageJson);
        String js = "window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative(" + payload + ");";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            webView.evaluateJavascript(js, (ValueCallback<String>) null);
            return;
        }
        webView.loadUrl("javascript:" + js);
    }

    @Override
    public void close() {
        listener = null;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.HONEYCOMB) {
            webView.removeJavascriptInterface(NATIVE_PROXY);
        }
    }

    private final class InboundBridgeInterface {
        @JavascriptInterface
        public void callNativeApi(String messageJson) {
            if (listener == null) {
                return;
            }
            listener.onMessage(messageJson);
        }
    }
}
