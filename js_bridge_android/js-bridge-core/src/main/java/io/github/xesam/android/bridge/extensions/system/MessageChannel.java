package io.github.xesam.android.bridge.extensions.system;

public interface MessageChannel {
    interface Listener {
        void onMessage(String messageJson);
    }

    void setListener(Listener listener);

    void send(String messageJson);

    void close();
}
