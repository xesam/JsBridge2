package io.github.xesam.example.bridge.extensions.timer;

import org.json.JSONObject;

import java.util.Random;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.example.bridge.JsonPayloadParser;

public class TimerExt implements SimpleNativeMessageHandler {
    private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
    private final Random random = new Random();
    private ScheduledFuture<?> timerFuture;
    private MessageHandlerCallback streamCallback;
    private boolean running;
    private int seq;

    @Override
    public void handle(
            Object data,
            MessageHandlerCallback callback) {
        Payload payload = new TimerPayloadParser().getPayload(data.toString());
        String action = payload == null || payload.action == null ? "start" : payload.action;
        if ("start".equals(action)) {
            startTimer(callback);
            return;
        }
        if ("stop".equals(action)) {
            stopTimer(callback);
            return;
        }
        callback.fail(new BridgeError("E_INVALID_PAYLOAD", "Timer action must be start or stop."));
    }

    private synchronized void startTimer(MessageHandlerCallback callback) {
        if (running) {
            callback.fail(new BridgeError("E_INVALID_PAYLOAD", "Timer is already running."));
            return;
        }
        running = true;
        streamCallback = callback;
        timerFuture = scheduler.scheduleAtFixedRate(() -> {
            MessageHandlerCallback currentCallback;
            synchronized (TimerExt.this) {
                if (!running || streamCallback == null) {
                    return;
                }
                currentCallback = streamCallback;
            }
            JSONObject tick = new JSONObject();
            try {
                tick.put("event", "tick");
                tick.put("value", random.nextInt(100));
                tick.put("seq", ++seq);
                tick.put("running", true);
            } catch (Exception e) {
                currentCallback.fail(new BridgeError("E_INTERNAL", "Failed to build timer payload."));
                return;
            }
            currentCallback.success(tick, false);
        }, 3, 3, TimeUnit.SECONDS);
    }

    private synchronized void stopTimer(MessageHandlerCallback callback) {
        if (!running) {
            JSONObject payload = new JSONObject();
            try {
                payload.put("event", "stopped");
                payload.put("running", false);
            } catch (Exception ignored) {
            }
            callback.success(payload);
            return;
        }

        running = false;
        if (timerFuture != null) {
            timerFuture.cancel(false);
            timerFuture = null;
        }
        MessageHandlerCallback previousStreamCallback = streamCallback;
        streamCallback = null;

        JSONObject stopEvent = new JSONObject();
        try {
            stopEvent.put("event", "stopped");
            stopEvent.put("running", false);
        } catch (Exception ignored) {
        }
        if (previousStreamCallback != null) {
            previousStreamCallback.success(stopEvent, true);
        }
        callback.success(stopEvent);
    }

    public static class TimerPayloadParser extends JsonPayloadParser<Payload> {
        @Override
        protected Class<Payload> getValueType() {
            return Payload.class;
        }
    }

    public static final class Payload {
        public String action;
    }
}
