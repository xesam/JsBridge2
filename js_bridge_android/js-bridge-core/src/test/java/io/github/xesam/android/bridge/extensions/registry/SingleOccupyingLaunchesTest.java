package io.github.xesam.android.bridge.extensions.registry;

import org.junit.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.TimeUnit;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

public class SingleOccupyingLaunchesTest {

    @Test
    public void start_returnsLaunchId_andConsumeReturnsPending() {
        SingleOccupyingLaunches launches = new SingleOccupyingLaunches();
        BridgeResultCallback callback = result -> {
        };

        String launchId = launches.start(callback);
        assertFalse(launchId.isEmpty());

        SingleOccupyingLaunches.PendingLaunch pendingLaunch = launches.consume();
        assertNotNull(pendingLaunch);
        assertEquals(launchId, pendingLaunch.launchId);
        assertTrue(pendingLaunch.callback == callback);
    }

    @Test
    public void start_whenBusy_returnsEmpty_andCallbackGetsBusyResult() {
        SingleOccupyingLaunches launches = new SingleOccupyingLaunches();
        launches.start(result -> {
        });

        final BridgeLaunchResult[] busyResult = new BridgeLaunchResult[1];
        String launchId = launches.start(result -> busyResult[0] = result);

        assertEquals("", launchId);
        assertNotNull(busyResult[0]);
        assertFalse(busyResult[0].isSuccess());
        assertEquals(BridgeLaunchResult.ERROR_BUSY, busyResult[0].getError());
    }

    @Test
    public void clear_dropsPendingLaunch() {
        SingleOccupyingLaunches launches = new SingleOccupyingLaunches();
        launches.start(result -> {
        });

        launches.clear();

        assertTrue(launches.consume() == null);
    }

    @Test
    public void start_concurrentCalls_exactlyOneAccepted() throws Exception {
        // start 检查-接纳必须原子：并发 start 只能有一单在途（busy-check-then-act
        // 若有窗口会双双通过、互相覆盖登记，其一回调悬挂——対齐 C47 评审修复的回归锚点）
        for (int round = 0; round < 200; round++) {
            final SingleOccupyingLaunches launches = new SingleOccupyingLaunches();
            final CyclicBarrier barrier = new CyclicBarrier(2);
            final String[] results = new String[2];
            final CountDownLatch done = new CountDownLatch(2);
            for (int i = 0; i < 2; i++) {
                final int index = i;
                Thread worker = new Thread(() -> {
                    try {
                        barrier.await();
                    } catch (Exception ignored) {
                        // barrier 破损不影响断言（另侧线程必然也异常返回）
                    }
                    results[index] = launches.start(result -> {
                    });
                    done.countDown();
                });
                worker.start();
            }
            assertTrue(done.await(2, TimeUnit.SECONDS));

            int accepted = 0;
            for (String launchId : results) {
                if (launchId != null && !launchId.isEmpty()) {
                    accepted++;
                }
            }
            assertEquals("round " + round + ": 并发 start 必须恰有一单在途", 1, accepted);
        }
    }
}
