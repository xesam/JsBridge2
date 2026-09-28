package io.github.xesam.android.bridge.security.session;

import org.junit.Test;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

public class InMemorySessionStoreTest {

    @Test
    public void clearByPageInstance_removesOnlyMatchingPage() {
        InMemorySessionStore store = new InMemorySessionStore();

        SessionRecord pageA = store.create("file://", "page-a", 60_000L);
        SessionRecord pageB = store.create("file://", "page-b", 60_000L);

        store.clearByPageInstance("page-a");

        assertNull(store.find(pageA.getSessionId()));
        assertNotNull(store.find(pageB.getSessionId()));
    }

    @Test
    public void find_expiredSession_returnsNull() {
        InMemorySessionStore store = new InMemorySessionStore();
        // docs/03 §10 三态（C60）：ttl=0 为"永不过期"，过期驱动改用负 TTL（立即过期）
        SessionRecord expired = store.create("file://", "page-a", -1L);

        assertNull(store.find(expired.getSessionId()));
    }
}
