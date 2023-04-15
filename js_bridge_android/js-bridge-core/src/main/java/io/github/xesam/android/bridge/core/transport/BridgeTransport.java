package io.github.xesam.android.bridge.core.transport;

public interface BridgeTransport {
    interface Listener {
        void onMessage(String messageJson);
    }

    void bind(Listener listener);

    boolean send(String messageJson);

    void close();
}
