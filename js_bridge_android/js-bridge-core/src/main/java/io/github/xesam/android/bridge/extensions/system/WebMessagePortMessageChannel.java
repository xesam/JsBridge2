package io.github.xesam.android.bridge.extensions.system;

import android.webkit.WebMessage;
import android.webkit.WebMessagePort;

import androidx.annotation.Nullable;

public final class WebMessagePortMessageChannel implements MessageChannel {
    private final WebMessagePort port;

    /** 跨线程可见：UI 线程写（setListener）、Chromium 回调线程读（onMessage）。 */
    @Nullable
    private volatile Listener listener;

    public WebMessagePortMessageChannel(WebMessagePort port) {
        this.port = port;
    }

    @Override
    public void setListener(Listener listener) {
        this.listener = listener;
        port.setWebMessageCallback(new WebMessagePort.WebMessageCallback() {
            @Override
            public void onMessage(WebMessagePort port, WebMessage message) {
                if (WebMessagePortMessageChannel.this.listener == null) {
                    return;
                }
                WebMessagePortMessageChannel.this.listener.onMessage(message.getData());
            }
        });
    }

    @Override
    public void send(String messageJson) {
        port.postMessage(new WebMessage(messageJson));
    }

    @Override
    public void close() {
        port.close();
    }
}
