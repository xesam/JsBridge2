package io.github.xesam.android.bridge.extensions.registry;

import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.Nullable;

/**
 * launchForResult 的默认结果登记。
 *
 * <p>线程模型：async handler 后台线程调 launchForResult 是合法用法，而
 * {@code ActivityResultLauncher.launch} 受 androidx 线程约束（主线程）——
 * launch 一律 hop 到主线程执行（同 transport 层的 WebView 线程纪律，docs/07 §3）。
 * 若 launch 在主线程仍抛出（activity finishing 等），登记即被消费并经
 * callback 以 {@code error="launch_failed"} 失败回执——不产生悬挂单。</p>
 */
public class DefaultBridgeResultRegistry implements BridgeResultRegistry {

    private static final String ERROR_LAUNCH_FAILED = "launch_failed";

    private final SingleOccupyingLaunches pendingLaunches = new SingleOccupyingLaunches();
    private final ActivityResultLauncher<Intent> mBridgeResultLauncher;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    public DefaultBridgeResultRegistry(ComponentActivity activity) {
        mBridgeResultLauncher = activity.registerForActivityResult(
                new ActivityResultContracts.StartActivityForResult(),
                result -> completePending(result.getResultCode(), result.getData()));
    }

    @Override
    public String launchForResult(Intent intent, BridgeResultCallback callback) {
        String launchId = pendingLaunches.start(callback);
        if (launchId.isEmpty()) {
            return "";
        }
        // launch 须在主线程（androidx 约束）；start 已同步完成 → 返回 launchId 不变。
        // 失败闭环：launch 异常时消费本单并立即回执失败，避免悬挂到 busy/超时。
        mainHandler.post(() -> {
            try {
                mBridgeResultLauncher.launch(intent);
            } catch (RuntimeException e) {
                SingleOccupyingLaunches.PendingLaunch failed = pendingLaunches.consume();
                if (failed != null) {
                    failed.callback.onResult(new BridgeLaunchResult(
                            failed.launchId, intent, false, ERROR_LAUNCH_FAILED));
                }
            }
        });
        return launchId;
    }

    @Override
    public void destroy() {
        mainHandler.post(() -> mBridgeResultLauncher.unregister());
        pendingLaunches.clear();
    }

    private void completePending(int resultCode, @Nullable Intent data) {
        SingleOccupyingLaunches.PendingLaunch pendingLaunch = pendingLaunches.consume();
        if (pendingLaunch == null) {
            return;
        }
        pendingLaunch.callback.onResult(BridgeLaunchResult.parseResult(pendingLaunch.launchId, resultCode, data));
    }
}
