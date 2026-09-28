package io.github.xesam.android.bridge.extensions.system;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

/**
 * conformance C47：bind 前到达的通道请求被暂存而非丢弃。
 *
 * 背景：页面脚本解析期（早于 onPageFinished）JS 就发起 requestBridgeChannel，
 * 此时 AndroidWebViewBridgeTransport.pendingListener 仍为 null。原实现直接丢弃，
 * 迫使 JS 侧等 channelTimeoutMs（2000ms）+ retryBackoffMs（500ms）重试——真机
 * 实测首轮握手推迟约 2.5s。本用例断言暂存队列的语义。
 *
 * 补投语义（latest-wins）：bind 时只补投最新的一个 reqId——被取代的旧 reqId
 * 不投（其端口 JS 侧因 reqId 不匹配不采纳，投递只会造成"建新对、关闭旧对"
 * 的端口空转，docs/06 §4.1/§4.3）。
 */
public class PendingChannelRequestsTest {

    @Test
    public void c47_offerBeforeBind_isRetainedNotDropped() {
        PendingChannelRequests queue = new PendingChannelRequests(64);

        queue.offer("r-1-abc");

        assertEquals(1, queue.size());
        assertFalse(queue.isEmpty());
    }

    @Test
    public void c47_pollLatestDeliversNewestAndDropsSuperseded() {
        PendingChannelRequests queue = new PendingChannelRequests(64);
        queue.offer("r-1");
        queue.offer("r-2");
        queue.offer("r-3");

        assertEquals("r-3", queue.pollLatest());
        assertTrue(queue.isEmpty());
        assertNull(queue.pollLatest());
    }

    @Test
    public void c47_closeClearsQueue() {
        PendingChannelRequests queue = new PendingChannelRequests(64);
        queue.offer("r-1-stale");

        queue.clear();

        assertTrue(queue.isEmpty());
        assertNull(queue.pollLatest());
    }

    @Test
    public void c47_overflowDropsOldest_latestStillSurvives() {
        PendingChannelRequests queue = new PendingChannelRequests(2);
        queue.offer("r-1");
        queue.offer("r-2");
        queue.offer("r-3");

        assertEquals("r-3", queue.pollLatest());
        assertNull(queue.pollLatest());
    }

    @Test
    public void c47_duplicateReqIdIsIdempotent() {
        PendingChannelRequests queue = new PendingChannelRequests(64);
        queue.offer("r-1");
        queue.offer("r-1");

        assertEquals(1, queue.size());
        assertEquals("r-1", queue.pollLatest());
    }

    @Test
    public void c47_sizeIsClampedToAtLeastOne() {
        PendingChannelRequests queue = new PendingChannelRequests(0);
        queue.offer("r-1");
        queue.offer("r-2");

        assertEquals("r-2", queue.pollLatest());
    }
}
