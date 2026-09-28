package io.github.xesam.example.bridge.extensions.user;

import android.util.Log;

import androidx.annotation.NonNull;

import org.json.JSONException;
import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.example.bridge.JsonPayloadParser;

public class UserExt implements AsyncHandler {
    @Override
    public void handle(
            TrustedPageContext context,
            JSONObject payload,
            ResponseEmitter emitter) {
        Payload userPayload = new UserPayloadParser().getPayload(payload.toString());
        new MockUserService().getUser(userPayload.userId, new MockUserService.UserServiceCallback() {
            @Override
            public void onSuccess(MockUserService.User user) {
                Log.d("getUser#onSuccess", user.toString());
                JSONObject userJson = new JSONObject();
                try {
                    userJson.put("name", user.getName());
                } catch (JSONException e) {
                    throw new RuntimeException(e);
                }
                emitter.success(userJson, true);
            }

            @Override
            public void onFail(@NonNull Error error) {
                Log.d("getUser#onFail", error.getMessage());
                JSONObject details = new JSONObject();
                try {
                    details.put("userId", userPayload.userId);
                } catch (JSONException ignored) {
                }
                emitter.fail(new BridgeError("E_NOT_FOUND", "user not found", false, details));
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
