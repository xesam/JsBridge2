package io.github.xesam.android.bridge.extensions.system;

import android.webkit.WebView;

import java.util.Objects;

import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.security.context.PageContextProvider;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;

public final class AndroidWebViewPageContextProvider implements PageContextProvider {
    private final WebView webView;
    private final AndroidWebViewTrustedContextFactory trustedContextFactory = new AndroidWebViewTrustedContextFactory();

    public AndroidWebViewPageContextProvider(WebView webView) {
        this.webView = Objects.requireNonNull(webView, "webView == null");
    }

    @Override
    public TrustedPageContext createContext(BridgeMessage bridgeMessage, String pageInstanceId) {
        return trustedContextFactory.create(webView, pageInstanceId);
    }
}
