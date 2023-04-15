package io.github.xesam.example.bridge.extensions.request;

import android.util.Log;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.example.bridge.JsonPayloadParser;
import okhttp3.Call;
import okhttp3.OkHttpClient;
import okhttp3.Response;

import java.util.concurrent.atomic.AtomicBoolean;

public class RequestExt implements SimpleNativeMessageHandler {

    public static final class Payload {
        public String url;
    }

    public static final class RequestPayloadParser extends JsonPayloadParser<Payload> {

        @Override
        protected Class<Payload> getValueType() {
            return Payload.class;
        }
    }

    @Override
    public void handle(
            Object data,
            MessageHandlerCallback callback) {
        Payload requestData = new RequestPayloadParser().getPayload(data.toString());
        Log.d("request#url", requestData.url);
        AtomicBoolean responded = new AtomicBoolean(false);
        new Thread(() -> {
            Call call = new OkHttpClient().newCall(new okhttp3.Request.Builder().url(requestData.url).build());
            try (Response response = call.execute()) {
                JSONObject jsonObject = new JSONObject();
                jsonObject.put("code", response.code());
                jsonObject.put("body", response.body() == null ? "" : response.body().string());
                if (responded.compareAndSet(false, true)) {
                    callback.success(jsonObject);
                }
            } catch (Exception e) {
                e.printStackTrace();
                if (responded.compareAndSet(false, true)) {
                    callback.fail(new BridgeError(
                            "E_REQUEST_FAILED",
                            e.getMessage() == null ? "request failed" : e.getMessage()));
                }
            }

        }).start();
    }
}
