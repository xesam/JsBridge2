package io.github.xesam.android.bridge.extensions.registry;

import androidx.annotation.Nullable;

import java.util.UUID;

/**
 * single-occupy 在途 launch 登记（launchForResult 的一次一单约束）：
 * 同一时刻至多一单在途，在途期间新 {@code start} 立即以 busy 回执拒绝——
 * 不排队、不共享结果（docs/02 §5.1；行为是单占用互斥而非去重共享，
 * 故名 single-occupy 而非 single-flight）。
 *
 * <p>线程模型（C47 评审遗留修复）：{@code start} 可能来自任意 handler 线程
 * （async handler 后台 worker 调 launchForResult 是合法用法），{@code consume}
 * 来自 Activity 结果回调（主线程），{@code clear} 来自宿主任意线程。
 * 全部状态由实例 monitor 保护；busy 回调在锁外交付——宿主回调可能重入
 * {@code start}/{@code clear}，持锁回调会自锁活锁路径。</p>
 */
final class SingleOccupyingLaunches {
    static final class PendingLaunch {
        final String launchId;
        final BridgeResultCallback callback;

        PendingLaunch(String launchId, BridgeResultCallback callback) {
            this.launchId = launchId;
            this.callback = callback;
        }
    }

    @Nullable
    private PendingLaunch pendingLaunch; // guarded by this

    String start(BridgeResultCallback callback) {
        final String launchId = UUID.randomUUID().toString();
        final boolean accepted;
        synchronized (this) {
            accepted = pendingLaunch == null;
            if (accepted) {
                pendingLaunch = new PendingLaunch(launchId, callback);
            }
        }
        if (!accepted) {
            callback.onResult(BridgeLaunchResult.busy());
            return "";
        }
        return launchId;
    }

    @Nullable
    PendingLaunch consume() {
        synchronized (this) {
            PendingLaunch current = pendingLaunch;
            pendingLaunch = null;
            return current;
        }
    }

    void clear() {
        synchronized (this) {
            pendingLaunch = null;
        }
    }
}
