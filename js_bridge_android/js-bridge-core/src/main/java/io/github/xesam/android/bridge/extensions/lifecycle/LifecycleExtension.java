package io.github.xesam.android.bridge.extensions.lifecycle;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.JsBridge;

public final class LifecycleExtension {
    private final JsBridge bridge;
    // 并发安全（C28/C29/C30）：offer 发生在宿主线程（onHostEvent），
    // flushPending 由 addReadyListener 触发、跑在 transport 入站（握手）线程——
    // 必须 ConcurrentLinkedQueue，普通 LinkedList 并发 offer/poll 会损坏内部链表
    private final Queue<JSONObject> pendingEvents = new ConcurrentLinkedQueue<>();
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
