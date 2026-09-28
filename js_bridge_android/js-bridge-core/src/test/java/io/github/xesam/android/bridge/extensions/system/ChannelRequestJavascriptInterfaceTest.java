package io.github.xesam.android.bridge.extensions.system;

import org.json.JSONObject;
import org.junit.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

/**
 * 通道建立哑入口的限频语义（docs/03 §3.1 资源守卫 / docs/09-conformance.md §4
 * Android frame 归因限制的缓解措施）：
 *
 * - 额度 per-bind（{@code resetForNewBind}）+ 空闲复充：距上次请求超过 windowMs
 *   即额度归位——恶意 iframe 一次性烧光 MAX 后只能造成 windowMs 级的暂时
 *   rate_limited，而非"直到下次导航"整页 bridge 不可用；
 * - ack 四态禁止静默：成功回显 reqId；畸形请求返回 {@code malformed}；
 *   超额返回 {@code rate_limited}。
 */
public class ChannelRequestJavascriptInterfaceTest {

    private static final class RecordingCallback implements ChannelRequestJavascriptInterface.Callback {
        final List<String> requested = new ArrayList<>();

        @Override
        public void onChannelRequested(String reqId) {
            requested.add(reqId);
        }
    }

    private static String ackError(String ack) throws Exception {
        return new JSONObject(ack).optString("error", "");
    }

    @Test
    public void rateLimit_perBindQuotaExhausted_rateLimitedAck() throws Exception {
        RecordingCallback callback = new RecordingCallback();
        // 可注入时钟：手动推进
        AtomicLong now = new AtomicLong(0L);
        ChannelRequestJavascriptInterface entry =
                new ChannelRequestJavascriptInterface(callback, 2, 30_000L, now::get);

        assertEquals("", ackError(entry.requestBridgeChannel("{\"reqId\":\"r1\"}")));
        assertEquals("", ackError(entry.requestBridgeChannel("{\"reqId\":\"r2\"}")));
        assertEquals("rate_limited", ackError(entry.requestBridgeChannel("{\"reqId\":\"r3\"}")));
        assertEquals(2, callback.requested.size()); // 超额请求不建通道

        // bind 轮换：额度归位（per-bind 语义）
        entry.resetForNewBind();
        assertEquals("", ackError(entry.requestBridgeChannel("{\"reqId\":\"r4\"}")));
        assertEquals(3, callback.requested.size());
    }

    @Test
    public void rateLimit_idleWindowRefillsQuota_noPermanentDenial() throws Exception {
        RecordingCallback callback = new RecordingCallback();
        AtomicLong now = new AtomicLong(0L);
        ChannelRequestJavascriptInterface entry =
                new ChannelRequestJavascriptInterface(callback, 2, 30_000L, now::get);

        // 模拟恶意 iframe 一次性烧光额度
        entry.requestBridgeChannel("{\"reqId\":\"flood-1\"}");
        entry.requestBridgeChannel("{\"reqId\":\"flood-2\"}");
        assertEquals("rate_limited", ackError(entry.requestBridgeChannel("{\"reqId\":\"legit\"}")));

        // 时间推进越过空闲窗口：额度复充，主 frame 的请求无需等下一次导航 bind
        now.set(31_000L * 1_000_000L);
        assertEquals("", ackError(entry.requestBridgeChannel("{\"reqId\":\"legit\"}")));
        assertEquals("legit", callback.requested.get(callback.requested.size() - 1));
    }

    @Test
    public void ack_successEchoesReqId_malformedOnBadInput() throws Exception {
        RecordingCallback callback = new RecordingCallback();
        ChannelRequestJavascriptInterface entry =
                new ChannelRequestJavascriptInterface(callback, 64);

        JSONObject ack = new JSONObject(entry.requestBridgeChannel("{\"reqId\":\"r-1\"}"));
        assertTrue(ack.optBoolean("ok"));
        assertEquals("r-1", ack.optString("reqId"));

        // 非法 JSON / 缺 reqId / 非 JSON 参数 → malformed（ack 禁止静默）
        assertEquals("malformed", ackError(entry.requestBridgeChannel("not-json")));
        assertEquals("malformed", ackError(entry.requestBridgeChannel("{}")));
        assertEquals("malformed", ackError(entry.requestBridgeChannel(null)));
    }
}
