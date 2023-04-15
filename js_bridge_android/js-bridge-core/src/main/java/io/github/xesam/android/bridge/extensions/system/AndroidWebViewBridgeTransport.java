package io.github.xesam.android.bridge.extensions.system;

import android.webkit.WebView;

import androidx.annotation.Nullable;

import java.util.Objects;

import io.github.xesam.android.bridge.core.transport.BridgeTransport;

public final class AndroidWebViewBridgeTransport implements BridgeTransport {
    private final WebView webView;

    @Nullable
    private MessageChannel channel;

    public AndroidWebViewBridgeTransport(WebView webView) {
        this.webView = Objects.requireNonNull(webView, "webView == null");
    }

    @Override
    public void bind(Listener listener) {
        close();
        channel = new WebMessageChannelBootstrapper().bootstrap(webView);
        channel.setListener(listener::onMessage);
    }

    @Override
    public boolean send(String messageJson) {
        if (channel == null) {
            return false;
        }
        channel.send(messageJson);
        return true;
    }

    @Override
    public void close() {
        if (channel != null) {
            channel.close();
            channel = null;
        }
    }
}
