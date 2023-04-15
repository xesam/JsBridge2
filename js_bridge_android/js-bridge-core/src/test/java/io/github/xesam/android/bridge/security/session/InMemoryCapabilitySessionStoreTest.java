package io.github.xesam.android.bridge.security.session;

import org.junit.Test;

import java.util.Arrays;
import java.util.HashSet;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

public class InMemoryCapabilitySessionStoreTest {

    @Test
    public void clearByPageInstance_removesOnlyMatchingPage() {
        InMemoryCapabilitySessionStore store = new InMemoryCapabilitySessionStore();

        SessionRecord pageA = store.create("file://", "page-a", new HashSet<>(Arrays.asList("echo")), 60_000L);
        SessionRecord pageB = store.create("file://", "page-b", new HashSet<>(Arrays.asList("echo")), 60_000L);

        store.clearByPageInstance("page-a");

        assertNull(store.find(pageA.getSessionId()));
        assertNotNull(store.find(pageB.getSessionId()));
    }

    @Test
    public void find_expiredSession_returnsNull() {
        InMemoryCapabilitySessionStore store = new InMemoryCapabilitySessionStore();
        SessionRecord expired = store.create("file://", "page-a", new HashSet<>(Arrays.asList("echo")), 0L);

        assertNull(store.find(expired.getSessionId()));
    }
}
