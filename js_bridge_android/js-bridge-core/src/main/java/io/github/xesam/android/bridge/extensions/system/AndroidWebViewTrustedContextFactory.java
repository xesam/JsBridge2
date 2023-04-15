package io.github.xesam.android.bridge.extensions.system;

import android.net.Uri;
import android.webkit.WebView;

import java.util.Objects;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;

final class AndroidWebViewTrustedContextFactory {

    TrustedPageContext create(WebView webView, String pageInstanceId) {
        Objects.requireNonNull(webView, "webView == null");
        String topUrl = safe(webView.getUrl());
        Uri uri = topUrl.isEmpty() ? Uri.EMPTY : Uri.parse(topUrl);
        String origin = buildOrigin(uri);
        return new TrustedPageContext(origin, safe(pageInstanceId));
    }

    private static String buildOrigin(Uri uri) {
        if (uri == null || Uri.EMPTY.equals(uri)) {
            return "";
        }
        String scheme = safe(uri.getScheme()).toLowerCase();
        if (scheme.isEmpty()) {
            return "";
        }
        if ("file".equals(scheme)) {
            return "file://";
        }
        String host = safe(uri.getHost()).toLowerCase();
        int port = uri.getPort();
        if (host.isEmpty()) {
            return "";
        }
        if (port <= 0) {
            return scheme + "://" + host;
        }
        return scheme + "://" + host + ":" + port;
    }

    private static String safe(String raw) {
        return raw == null ? "" : raw;
    }
}
