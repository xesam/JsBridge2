package io.github.xesam.android.bridge.extensions.registry;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

public class SingleFlightPendingLaunchesTest {

    @Test
    public void start_returnsLaunchId_andConsumeReturnsPending() {
        SingleFlightPendingLaunches launches = new SingleFlightPendingLaunches();
        BridgeResultCallback callback = result -> {
        };

        String launchId = launches.start(callback);
        assertFalse(launchId.isEmpty());

        SingleFlightPendingLaunches.PendingLaunch pendingLaunch = launches.consume();
        assertNotNull(pendingLaunch);
        assertEquals(launchId, pendingLaunch.launchId);
        assertTrue(pendingLaunch.callback == callback);
    }

    @Test
    public void start_whenBusy_returnsEmpty_andCallbackGetsBusyResult() {
        SingleFlightPendingLaunches launches = new SingleFlightPendingLaunches();
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
        SingleFlightPendingLaunches launches = new SingleFlightPendingLaunches();
        launches.start(result -> {
        });

        launches.clear();

        assertTrue(launches.consume() == null);
    }
}
