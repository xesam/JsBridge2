package io.github.xesam.android.bridge.extensions.lifecycle;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.LinkedList;
import java.util.Queue;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.JsBridge;

public final class LifecycleExtension {
    private final JsBridge bridge;
    private final Queue<JSONObject> pendingEvents = new LinkedList<>();
    private final int maxPendingEvents;
    private int seq;

    public LifecycleExtension(JsBridge bridge) {
        this(bridge, 32);
    }

    public LifecycleExtension(JsBridge bridge, int maxPendingEvents) {
        this.bridge = bridge;
        this.maxPendingEvents = Math.max(1, maxPendingEvents);
        this.bridge.addReadyListener(this::flushPending);
    }

    public void onHostEvent(String state) {
        JSONObject payload = new JSONObject();
        try {
            payload.put("state", state);
            payload.put("seq", ++seq);
        } catch (JSONException ignored) {
        }
        if (bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, payload)) {
            return;
        }
        pendingEvents.offer(payload);
        if (pendingEvents.size() > maxPendingEvents) {
            pendingEvents.poll();
        }
    }

    private void flushPending() {
        while (!pendingEvents.isEmpty()) {
            JSONObject event = pendingEvents.poll();
            if (!bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, event)) {
                pendingEvents.offer(event);
                return;
            }
        }
    }
}
