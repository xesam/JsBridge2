package io.github.xesam.android.bridge.extensions.system;

import android.net.Uri;
import android.os.Build;
import android.webkit.WebMessage;
import android.webkit.WebMessagePort;
import android.webkit.WebView;

import androidx.annotation.NonNull;

import java.util.Objects;

public final class WebMessageChannelBootstrapper {
    private static final Uri TARGET_ANY = Uri.parse("*");

    public MessageChannel bootstrap(@NonNull WebView webView) {
        Objects.requireNonNull(webView, "webView == null");
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return new LegacyJavascriptChannel(webView);
        }
        WebMessagePort[] ports = webView.createWebMessageChannel();
        WebMessagePort nativePort = ports[0];
        WebMessagePort pagePort = ports[1];
        webView.postWebMessage(new WebMessage("bridge:init", new WebMessagePort[]{pagePort}), TARGET_ANY);
        return new WebMessagePortMessageChannel(nativePort);
    }
}
