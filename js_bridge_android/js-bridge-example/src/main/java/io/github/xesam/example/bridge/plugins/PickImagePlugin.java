package io.github.xesam.example.bridge.plugins;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.provider.MediaStore;

import androidx.appcompat.app.AlertDialog;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.android.bridge.extensions.registry.BridgeLaunchResult;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultCallback;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultRegistry;
import io.github.xesam.example.bridge.JsonPayloadParser;

public class PickImagePlugin implements AsyncHandler {

    private final Context context;
    private final BridgeResultRegistry mBridgeResultRegistry;

    public PickImagePlugin(Context context, BridgeResultRegistry launcher) {
        this.context = context;
        this.mBridgeResultRegistry = launcher;
    }

    @Override
    public void handle(
            TrustedPageContext trustedPageContext,
            JSONObject payload,
            ResponseEmitter emitter) {
        MessageData messageData = new PickImagePayloadParser().getPayload(payload.toString());
        String type = messageData == null || messageData.type == null || messageData.type.length() == 0
                ? "image/*"
                : messageData.type;
        Intent intent = new Intent(Intent.ACTION_PICK);
        intent.setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, type);
        mBridgeResultRegistry.launchForResult(intent, new BridgeResultCallback() {
            @Override
            public void onResult(BridgeLaunchResult result) {
                if (result.isSuccess()) {
                    Uri imageUri = result.getIntent() == null ? null : result.getIntent().getData();
                    if (imageUri == null) {
                        emitter.fail(new BridgeError("E_RESULT_EMPTY", "empty launch result"));
                        return;
                    }
                    JSONObject res = new JSONObject();
                    try {
                        res.put("uri", imageUri.toString());
                        res.put("type", type);
                        res.put("source", "photo-library");
                        res.put("native", true);
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

    public static class PickImagePayloadParser extends JsonPayloadParser<MessageData> {

        @Override
        protected Class<PickImagePlugin.MessageData> getValueType() {
            return PickImagePlugin.MessageData.class;
        }
    }

    public static final class MessageData {
        public String type;
    }
}
