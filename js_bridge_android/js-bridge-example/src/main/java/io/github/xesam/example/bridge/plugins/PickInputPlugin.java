package io.github.xesam.example.bridge.plugins;

import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.android.bridge.extensions.registry.BridgeLaunchResult;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultCallback;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultRegistry;
import io.github.xesam.example.bridge.PickInputActivity;

public class PickInputPlugin implements SimpleNativeMessageHandler {
    private final Context context;
    private final BridgeResultRegistry mBridgeResultRegistry;

    public PickInputPlugin(Context context, BridgeResultRegistry launcher) {
        this.context = context;
        this.mBridgeResultRegistry = launcher;
    }

    @Override
    public void handle(
            Object data,
            MessageHandlerCallback callback) {
        Intent intent = new Intent(context, PickInputActivity.class);
        mBridgeResultRegistry.launchForResult(intent, new BridgeResultCallback() {
            @Override
            public void onResult(BridgeLaunchResult result) {
                if (result.isSuccess()) {
                    String name = result.getIntent().getStringExtra("name");
                    int age = result.getIntent().getIntExtra("age", -1);
                    new AlertDialog.Builder(context)
                            .setMessage(name + ":" + age)
                            .show();
                    JSONObject res = new JSONObject();
                    try {
                        res.put("name", name);
                        res.put("age", age);
                    } catch (Exception e) {
                        e.printStackTrace();
                    }
                    callback.success(res);
                } else {
                    callback.fail(toBridgeError(result));
                }
            }
        });
    }

    private static BridgeError toBridgeError(BridgeLaunchResult result) {
        String error = result.getError();
        if (BridgeLaunchResult.ERROR_BUSY.equals(error)) {
            return new BridgeError("E_BUSY", "launch is already in progress");
        }
        if (BridgeLaunchResult.ERROR_CANCELED.equals(error)) {
            return new BridgeError("E_CANCELED", "launch canceled");
        }
        if (BridgeLaunchResult.ERROR_EMPTY_RESULT.equals(error)) {
            return new BridgeError("E_RESULT_EMPTY", "empty launch result");
        }
        return new BridgeError("E_LAUNCH_FAILED", error == null ? "launch failed" : error);
    }
}
