package io.github.xesam.android.bridge.extensions.system;

import android.webkit.WebView;

import java.util.Objects;

import io.github.xesam.android.bridge.api.OriginNormalizer;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;

final class AndroidWebViewTrustedContextFactory {

    TrustedPageContext create(WebView webView, String pageInstanceId) {
        Objects.requireNonNull(webView, "webView == null");
        // origin 归一化契约（docs/03 §9 细则 5 / conformance C54）：URL 缺失 → 空串，
        // 默认端口（443/80）省略、非默认保留、scheme/host 小写——统一走 api 层纯工具实现
        String origin = OriginNormalizer.normalize(safe(webView.getUrl()));
        return new TrustedPageContext(origin, safe(pageInstanceId));
    }

    private static String safe(String raw) {
        return raw == null ? "" : raw;
    }
}
