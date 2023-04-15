package io.github.xesam.android.bridge.extensions.registry;

import android.content.Intent;

import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.Nullable;

public class DefaultBridgeResultRegistry implements BridgeResultRegistry {
    private final SingleFlightPendingLaunches pendingLaunches = new SingleFlightPendingLaunches();
    private final ActivityResultLauncher<Intent> mBridgeResultLauncher;

    public DefaultBridgeResultRegistry(ComponentActivity activity) {
        mBridgeResultLauncher = activity.registerForActivityResult(
                new ActivityResultContracts.StartActivityForResult(),
                result -> completePending(result.getResultCode(), result.getData()));
    }

    @Override
    public String launchForResult(Intent intent, BridgeResultCallback callback) {
        String launchId = pendingLaunches.start(callback);
        if (launchId.isEmpty()) {
            return "";
        }
        mBridgeResultLauncher.launch(intent);
        return launchId;
    }

    @Override
    public void destroy() {
        mBridgeResultLauncher.unregister();
        pendingLaunches.clear();
    }

    private void completePending(int resultCode, @Nullable Intent data) {
        SingleFlightPendingLaunches.PendingLaunch pendingLaunch = pendingLaunches.consume();
        if (pendingLaunch == null) {
            return;
        }
        pendingLaunch.callback.onResult(BridgeLaunchResult.parseResult(pendingLaunch.launchId, resultCode, data));
    }
}
