package io.github.xesam.android.bridge.extensions.registry;

import android.app.Activity;
import android.content.Intent;

import androidx.annotation.Nullable;

public class CompatBridgeResultRegistry implements BridgeResultRegistry, BridgeResultDispatcher {
    private static final int BRIDGE_REQUEST_CODE = 0x4A42;
    private final Activity mActivity;
    private final SingleFlightPendingLaunches pendingLaunches = new SingleFlightPendingLaunches();

    public CompatBridgeResultRegistry(Activity activity) {
        mActivity = activity;
    }

    @Override
    public String launchForResult(Intent intent, BridgeResultCallback callback) {
        String launchId = pendingLaunches.start(callback);
        if (launchId.isEmpty()) {
            return "";
        }
        mActivity.startActivityForResult(intent, BRIDGE_REQUEST_CODE);
        return launchId;
    }

    @Override
    public boolean dispatchResult(int requestCode, int resultCode, @Nullable Intent data) {
        if (requestCode != BRIDGE_REQUEST_CODE) {
            return false;
        }
        SingleFlightPendingLaunches.PendingLaunch pendingLaunch = pendingLaunches.consume();
        if (pendingLaunch == null) {
            return true;
        }
        pendingLaunch.callback.onResult(BridgeLaunchResult.parseResult(pendingLaunch.launchId, resultCode, data));
        return true;
    }

    @Override
    public void destroy() {
        pendingLaunches.clear();
    }
}
