package io.github.xesam.example.bridge.extensions.user;

import android.util.Log;

import androidx.annotation.NonNull;

import org.json.JSONException;
import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.example.bridge.JsonPayloadParser;

public class UserExt implements SimpleNativeMessageHandler {
    @Override
    public void handle(
            Object data,
            MessageHandlerCallback callback) {
        Payload payload = new UserPayloadParser().getPayload(data.toString());
        new MockUserService().getUser(payload.userId, new MockUserService.UserServiceCallback() {
            @Override
            public void onSuccess(MockUserService.User user) {
                Log.d("getUser#onSuccess", user.toString());
                JSONObject userJson = new JSONObject();
                try {
                    userJson.put("name", user.getName());
                } catch (JSONException e) {
                    throw new RuntimeException(e);
                }
                callback.success(userJson);
            }

            @Override
            public void onFail(@NonNull Error error) {
                Log.d("getUser#onFail", error.getMessage());
                JSONObject details = new JSONObject();
                try {
                    details.put("userId", payload.userId);
                } catch (JSONException ignored) {
                }
                callback.fail(new BridgeError("E_NOT_FOUND", "user not found", false, details));
            }
        });
    }

    public static class UserPayloadParser extends JsonPayloadParser<Payload> {

        @Override
        protected Class<UserExt.Payload> getValueType() {
            return UserExt.Payload.class;
        }
    }

    public static final class Payload {
        public String userId;
    }
}
