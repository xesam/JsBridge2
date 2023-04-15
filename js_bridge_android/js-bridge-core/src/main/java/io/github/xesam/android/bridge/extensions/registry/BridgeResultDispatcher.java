package io.github.xesam.android.bridge.extensions.registry;

import android.content.Intent;

import androidx.annotation.Nullable;

public interface BridgeResultDispatcher {
    boolean dispatchResult(int requestCode, int resultCode, @Nullable Intent data);
}
