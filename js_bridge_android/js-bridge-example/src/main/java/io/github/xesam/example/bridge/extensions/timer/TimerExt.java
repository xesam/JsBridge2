package io.github.xesam.example.bridge.extensions.timer;

import org.json.JSONObject;

import java.util.Random;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.example.bridge.JsonPayloadParser;

public class TimerExt implements AsyncHandler {
    private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
    private final Random random = new Random();
    private ScheduledFuture<?> timerFuture;
    private ResponseEmitter streamEmitter;
    private boolean running;
    private int seq;

    @Override
    public void handle(
            TrustedPageContext context,
            JSONObject payload,
            ResponseEmitter emitter) {
        Payload parsed = new TimerPayloadParser().getPayload(payload.toString());
        String action = parsed == null || parsed.action == null ? "start" : parsed.action;
        if ("start".equals(action)) {
            startTimer(emitter);
            return;
        }
        if ("stop".equals(action)) {
            stopTimer(emitter);
            return;
        }
        emitter.fail(new BridgeError("E_INVALID_PAYLOAD", "Timer action must be start or stop."));
    }

    private synchronized void startTimer(ResponseEmitter emitter) {
        if (running) {
            emitter.fail(new BridgeError("E_INVALID_PAYLOAD", "Timer is already running."));
            return;
        }
        running = true;
        streamEmitter = emitter;
        timerFuture = scheduler.scheduleAtFixedRate(() -> {
            ResponseEmitter currentEmitter;
            synchronized (TimerExt.this) {
                if (!running || streamEmitter == null) {
                    return;
                }
                currentEmitter = streamEmitter;
            }
            JSONObject tick = new JSONObject();
            try {
                tick.put("event", "tick");
                tick.put("value", random.nextInt(100));
                tick.put("seq", ++seq);
                tick.put("running", true);
            } catch (Exception e) {
                currentEmitter.fail(new BridgeError("E_INTERNAL", "Failed to build timer payload."));
                return;
            }
            currentEmitter.success(tick, false);
        }, 0, 1, TimeUnit.SECONDS);
    }

    private synchronized void stopTimer(ResponseEmitter emitter) {
        if (!running) {
            JSONObject payload = new JSONObject();
            try {
                payload.put("event", "stopped");
                payload.put("running", false);
            } catch (Exception ignored) {
            }
            emitter.success(payload, true);
            return;
        }

        running = false;
        if (timerFuture != null) {
            timerFuture.cancel(false);
            timerFuture = null;
        }
        ResponseEmitter previousStreamEmitter = streamEmitter;
        streamEmitter = null;

        JSONObject stopEvent = new JSONObject();
        try {
            stopEvent.put("event", "stopped");
            stopEvent.put("running", false);
        } catch (Exception ignored) {
        }
        if (previousStreamEmitter != null) {
            previousStreamEmitter.success(stopEvent, true);
        }
        emitter.success(stopEvent, true);
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
