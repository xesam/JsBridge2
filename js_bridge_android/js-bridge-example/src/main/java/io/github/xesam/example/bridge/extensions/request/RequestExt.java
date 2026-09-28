package io.github.xesam.example.bridge.extensions.request;

import android.util.Log;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.example.bridge.JsonPayloadParser;
import okhttp3.Call;
import okhttp3.OkHttpClient;
import okhttp3.Response;

import java.util.concurrent.atomic.AtomicBoolean;

public class RequestExt implements AsyncHandler {

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
            TrustedPageContext context,
            JSONObject payload,
            ResponseEmitter emitter) {
        Payload requestData = new RequestPayloadParser().getPayload(payload.toString());
        Log.d("request#url", requestData.url);
        AtomicBoolean responded = new AtomicBoolean(false);
        new Thread(() -> {
            Call call = new OkHttpClient().newCall(new okhttp3.Request.Builder().url(requestData.url).build());
            try (Response response = call.execute()) {
                JSONObject jsonObject = new JSONObject();
                jsonObject.put("code", response.code());
                jsonObject.put("body", response.body() == null ? "" : response.body().string());
                if (responded.compareAndSet(false, true)) {
                    emitter.success(jsonObject, true);
                }
            } catch (Exception e) {
                e.printStackTrace();
                if (responded.compareAndSet(false, true)) {
                    emitter.fail(new BridgeError(
                            "E_REQUEST_FAILED",
                            e.getMessage() == null ? "request failed" : e.getMessage()));
                }
            }

        }).start();
    }
}
