package io.github.xesam.android.bridge.core.message;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;

public interface NativeMessageHandler {
    void handle(
            TrustedPageContext trustedPageContext,
            Object data,
            MessageHandlerCallback callback);
}
