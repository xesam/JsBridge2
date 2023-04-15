package io.github.xesam.android.bridge.api.model;

/**
 * 页面可信上下文——跨层共享的纯数据模型。
 * 由 {@code PageContextProvider}（security 层 SPI）创建，
 * 被 core（handler 参数）、security（策略求值）、extensions（WebView 适配）共同使用。
 */
public final class TrustedPageContext {
    private final String origin;
    private final String pageInstanceId;

    public TrustedPageContext(String origin, String pageInstanceId) {
        this.origin = origin == null ? "" : origin;
        this.pageInstanceId = pageInstanceId == null ? "" : pageInstanceId;
    }

    public String getOrigin() {
        return origin;
    }

    public String getPageInstanceId() {
        return pageInstanceId;
    }
}
