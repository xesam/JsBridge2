package io.github.xesam.example.bridge.plugins;

import android.content.Context;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.android.bridge.extensions.registry.BridgeLaunchResult;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultCallback;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultRegistry;
import io.github.xesam.example.bridge.PickInputActivity;

import android.app.AlertDialog;
import android.content.Intent;

import io.github.xesam.android.bridge.api.model.BridgeError;

public class PickInputPlugin implements AsyncHandler {
    private final Context context;
    private final BridgeResultRegistry mBridgeResultRegistry;

    public PickInputPlugin(Context context, BridgeResultRegistry launcher) {
        this.context = context;
        this.mBridgeResultRegistry = launcher;
    }

    @Override
    public void handle(
            TrustedPageContext trustedPageContext,
            JSONObject payload,
            ResponseEmitter emitter) {
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
                    emitter.success(res, true);
                } else {
                    emitter.fail(toBridgeError(result));
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
            return new BridgeError("E_INTERNAL", "launch canceled");  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
        }
        if (BridgeLaunchResult.ERROR_EMPTY_RESULT.equals(error)) {
            return new BridgeError("E_RESULT_EMPTY", "empty launch result");
        }
        return new BridgeError("E_LAUNCH_FAILED", error == null ? "launch failed" : error);
    }
}
