package io.github.xesam.android.bridge.extensions.registry;

import androidx.annotation.Nullable;

import java.util.UUID;

final class SingleFlightPendingLaunches {
    static final class PendingLaunch {
        final String launchId;
        final BridgeResultCallback callback;

        PendingLaunch(String launchId, BridgeResultCallback callback) {
            this.launchId = launchId;
            this.callback = callback;
        }
    }

    @Nullable
    private PendingLaunch pendingLaunch;

    String start(BridgeResultCallback callback) {
        if (pendingLaunch != null) {
            callback.onResult(BridgeLaunchResult.busy());
            return "";
        }
        String launchId = UUID.randomUUID().toString();
        pendingLaunch = new PendingLaunch(launchId, callback);
        return launchId;
    }

    @Nullable
    PendingLaunch consume() {
        PendingLaunch current = pendingLaunch;
        pendingLaunch = null;
        return current;
    }

    void clear() {
        pendingLaunch = null;
    }
}
