package io.github.xesam.example.bridge.plugins;

import android.app.AlertDialog;
import android.content.Context;

import org.json.JSONObject;

import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.example.bridge.JsonPayloadParser;

public final class LoadingPlugin implements SimpleNativeMessageHandler {
    private final Context context;

    public LoadingPlugin(Context context) {
        this.context = context;
    }

    @Override
    public void handle(
            Object data,
            MessageHandlerCallback callback) {
        MessageData messageData = new DialogPayloadParser().getPayload(data.toString());

        new AlertDialog.Builder(context)
                .setTitle(messageData.title)
                .setMessage(messageData.content + ":Loading...")
                .show();
        JSONObject payload = new JSONObject();
        try {
            payload.put("status", "shown");
            payload.put("native", true);
        } catch (Exception ignored) {
        }
        callback.success(payload);
    }

    public static class DialogPayloadParser extends JsonPayloadParser<MessageData> {

        @Override
        protected Class<LoadingPlugin.MessageData> getValueType() {
            return LoadingPlugin.MessageData.class;
        }
    }

    public static final class MessageData {
        public String title;
        public String content;
    }
}
