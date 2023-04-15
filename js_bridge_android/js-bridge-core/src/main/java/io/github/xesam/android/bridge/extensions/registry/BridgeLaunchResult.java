package io.github.xesam.android.bridge.extensions.registry;

import android.content.Intent;

public class BridgeLaunchResult {
    public static final String ERROR_BUSY = "busy";
    public static final String ERROR_CANCELED = "canceled";
    public static final String ERROR_EMPTY_RESULT = "nothing";

    static BridgeLaunchResult parseResult(String launchId, int resultCode, Intent intent) {
        if (resultCode != android.app.Activity.RESULT_OK) {
            return new BridgeLaunchResult(launchId, null, false, ERROR_CANCELED);
        }

        if (intent == null) {
            return new BridgeLaunchResult(launchId, null, false, ERROR_EMPTY_RESULT);
        }
        return new BridgeLaunchResult(launchId, intent, true, null);
    }

    static BridgeLaunchResult busy() {
        return new BridgeLaunchResult("", null, false, ERROR_BUSY);
    }

    private final String launchId;
    private final Intent intent;
    private final boolean success;
    private final String error;

    public BridgeLaunchResult(String launchId, Intent intent, boolean success, String error) {
        this.launchId = launchId;
        this.intent = intent;
        this.success = success;
        this.error = error;
    }

    public String getLaunchId() {
        return launchId;
    }

    public boolean isSuccess() {
        return success;
    }

    public Intent getIntent() {
        return intent;
    }

    public String getError() {
        return error;
    }
}
