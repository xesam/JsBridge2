package io.github.xesam.android.bridge.core.message;

/**
 * 与 Page 解耦的业务 handler：只关心 payload，不感知 TrustedPageContext。
 * 用于不需要页面上下文的常见场景；需要上下文时改用 {@link NativeMessageHandler}。
 */
public interface SimpleNativeMessageHandler {
    void handle(Object data, MessageHandlerCallback callback);
}
