package io.github.xesam.android.bridge.extensions.registry;

import android.content.Intent;

public interface BridgeResultRegistry {
    String launchForResult(Intent intent, BridgeResultCallback callback);

    void destroy();
}
