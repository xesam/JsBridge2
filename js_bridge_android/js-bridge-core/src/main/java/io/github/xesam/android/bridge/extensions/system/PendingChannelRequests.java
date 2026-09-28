package io.github.xesam.android.bridge.extensions.system;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Objects;

/**
 * bind 前到达的通道请求暂存队列（conformance C47）。
 *
 * 因果序问题：页面脚本解析期（`navigationStart` 后约百余毫秒）JS 就已发起
 * `requestBridgeChannel`，而宿主的 `bind()` 要等到 `onPageFinished` 才执行。
 * 这一窗口内的请求若被丢弃，JS 侧只能等 `channelTimeoutMs`（默认 2000ms）
 * 超时、再退避 `retryBackoffMs`（默认 500ms）重试——真机实测首轮握手因此
 * 推迟约 2.5s（docs/06 §5.3）。
 *
 * 本类把"丢弃"改为"暂存 + bind 时补投"：请求按到达顺序保留，`pollLatest()` 按
 * latest-wins 取最新一个交付（被取代的旧请求不补投，同时排空队列）——陈旧请求
 * 不会跨绑定周期存活（bind 轮换即排空）；`clear()` 仅在 close（destroy 路径）时
 * 兜底清空。容量超限丢最旧，与 LifecycleExtension 的 pending 队列语义一致。
 *
 * 纯逻辑，无 Android 依赖——决策可在 JVM 单测中直接断言。
 *
 * 线程安全：`offer()` 在 JS bridge 线程执行（`requestBridgeChannel` 回调），
 * `pollLatest()`/`clear()` 在 UI 线程执行（`bind()`/`close()`）。所有方法加锁，
 * 跨线程交接不会丢失或重复请求。
 */
final class PendingChannelRequests {
    private final int maxSize;
    private final Deque<String> reqIds = new ArrayDeque<>();

    PendingChannelRequests(int maxSize) {
        this.maxSize = Math.max(1, maxSize);
    }

    /** 暂存一个 bind 前到达的请求；超限丢最旧。重复 reqId 幂等忽略。 */
    synchronized void offer(String reqId) {
        Objects.requireNonNull(reqId, "reqId == null");
        if (reqIds.contains(reqId)) {
            return;
        }
        while (reqIds.size() >= maxSize) {
            reqIds.pollFirst();
        }
        reqIds.addLast(reqId);
    }

    /**
     * 取出**最新的一个**暂存请求并清空队列（bind 补投：latest-wins）。
     *
     * 被取代的旧请求不补投：旧 reqId 的端口即便送达，JS 侧也因 reqId 不匹配不会采纳
     * （端口采纳来源校验），补投旧请求只会造成"建新对、关闭旧对"的端口空转——
     * 每投一个 reqId 就关掉上一个刚建好的端口，除最新外全部建成即死（docs/06 §5.3）。
     */
    synchronized String pollLatest() {
        String latest = reqIds.pollLast();
        reqIds.clear();
        return latest;
    }

    /** 清空队列（仅 close——destroy 路径——调用；bind 轮换由 pollLatest() 排空）。 */
    synchronized void clear() {
        reqIds.clear();
    }

    synchronized int size() {
        return reqIds.size();
    }

    synchronized boolean isEmpty() {
        return reqIds.isEmpty();
    }
}
