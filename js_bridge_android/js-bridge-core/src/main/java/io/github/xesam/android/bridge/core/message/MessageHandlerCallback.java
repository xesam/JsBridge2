package io.github.xesam.android.bridge.core.message;

public interface MessageHandlerCallback {
    void success(Object res);

    default void success(Object res, boolean done) {
        success(res);
    }

    void fail(Object error);
}
