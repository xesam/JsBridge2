package io.github.xesam.example.bridge.plugins;

import android.app.AlertDialog;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.SimpleHandler;
import io.github.xesam.example.bridge.JsonPayloadParser;

/**
 * Simple Handler 示例：同步弹出 loading 并在返回时结束通信（恰好一帧）。
 * 对话框的延时关闭是 fire-and-forget，不参与响应路径。
 */
public final class LoadingPlugin implements SimpleHandler {
    private final Context context;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private AlertDialog currentDialog;

    public LoadingPlugin(Context context) {
        this.context = context;
    }

    @Override
    public Object handle(
            TrustedPageContext trustedPageContext,
            JSONObject payload) {
        MessageData messageData = new DialogPayloadParser().getPayload(payload.toString());
        String title = messageData.title == null || messageData.title.isEmpty() ? "Loading" : messageData.title;
        String content = messageData.content == null || messageData.content.isEmpty() ? "Please wait..." : messageData.content;
        long durationMs = messageData.durationMs > 0 ? messageData.durationMs : 1200L;

        if (currentDialog != null && currentDialog.isShowing()) {
            currentDialog.dismiss();
        }

        AlertDialog dialog = new AlertDialog.Builder(context)
                .setTitle(title)
                .setMessage(content + "\nLoading...")
                .setCancelable(false)
                .create();
        dialog.show();
        currentDialog = dialog;

        mainHandler.postDelayed(() -> {
            if (dialog.isShowing()) {
                dialog.dismiss();
            }
        }, Math.max(300, durationMs));

        JSONObject result = new JSONObject();
        try {
            result.put("status", "shown");
            result.put("native", true);
            result.put("durationMs", durationMs);
        } catch (Exception ignored) {
        }
        return result;
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
        public long durationMs;
    }
}
