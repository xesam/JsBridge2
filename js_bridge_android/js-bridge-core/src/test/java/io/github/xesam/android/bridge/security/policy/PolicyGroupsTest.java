package io.github.xesam.android.bridge.security.policy;

import org.junit.Test;

import java.lang.reflect.Field;
import java.util.Arrays;
import java.util.HashSet;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.security.session.SessionRecord;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class PolicyGroupsTest {

    @Test
    public void requestShape_rejectsNonRequest() {
        PolicyDecision decision = new RequestShapePolicy().evaluate(new PolicyInput(
                eventMessage("timerLog"),
                context("file://"),
                false,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_INVALID_MESSAGE", errorCode(decision));
    }

    @Test
    public void handshakeGate_rejectsCallBeforeHandshake() {
        PolicyDecision decision = new HandshakeGatePolicy().evaluate(new PolicyInput(
                requestMessage("getUser", "s1"),
                context("file://"),
                false,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_POLICY_DENY", errorCode(decision));
    }

    @Test
    public void accessControl_rejectsOriginAndMethod() {
        AccessControlPolicy policy = new AccessControlPolicy(
                new HashSet<>(Arrays.asList("https://trusted.example")),
                new HashSet<>(Arrays.asList("bridge.handshake", "getUser")));

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("timerLog", "s1"),
                context("file://"),
                true,
                null));

        assertFalse(decision.isAllowed());
        assertEquals("E_ORIGIN_DENY", errorCode(decision));
    }

    @Test
    public void accessControl_rejectsSessionMismatch() {
        AccessControlPolicy policy = new AccessControlPolicy(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList("bridge.handshake", "getUser")));

        SessionRecord sessionRecord = new SessionRecord(
                "s1",
                "file://",
                "page-a",
                new HashSet<>(Arrays.asList("getUser")),
                System.currentTimeMillis() + 60_000L);

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("getUser", "s1"),
                new TrustedPageContext("file://", "page-b"),
                true,
                sessionRecord));

        assertFalse(decision.isAllowed());
        assertEquals("E_SESSION_INVALID", errorCode(decision));
    }

    @Test
    public void accessControl_rejectsCapabilityDenied() {
        AccessControlPolicy policy = new AccessControlPolicy(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList("bridge.handshake", "timerLog")));

        SessionRecord sessionRecord = new SessionRecord(
                "s1",
                "file://",
                "page-a",
                new HashSet<>(Arrays.asList("getUser")),
                System.currentTimeMillis() + 60_000L);

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("timerLog", "s1"),
                new TrustedPageContext("file://", "page-a"),
                true,
                sessionRecord));

        assertFalse(decision.isAllowed());
        assertEquals("E_CAPABILITY_DENY", errorCode(decision));
    }

    @Test
    public void accessControl_allowsValidRequest() {
        AccessControlPolicy policy = new AccessControlPolicy(
                new HashSet<>(Arrays.asList("file://")),
                new HashSet<>(Arrays.asList("bridge.handshake", "getUser")));

        SessionRecord sessionRecord = new SessionRecord(
                "s1",
                "file://",
                "page-a",
                new HashSet<>(Arrays.asList("getUser")),
                System.currentTimeMillis() + 60_000L);

        PolicyDecision decision = policy.evaluate(new PolicyInput(
                requestMessage("getUser", "s1"),
                new TrustedPageContext("file://", "page-a"),
                true,
                sessionRecord));

        assertTrue(decision.isAllowed());
    }

    private static BridgeMessage requestMessage(String method, String sessionId) {
        return message("request", method, sessionId);
    }

    private static BridgeMessage eventMessage(String method) {
        return message("event", method, "");
    }

    private static TrustedPageContext context(String origin) {
        return new TrustedPageContext(origin, "page-a");
    }

    private static BridgeMessage message(String kind, String method, String sessionId) {
        try {
            BridgeMessage message = new BridgeMessage();
            setField(message, "id", "r1");
            setField(message, "kind", kind);
            setField(message, "method", method);
            setField(message, "sessionId", sessionId);
            return message;
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static void setField(BridgeMessage message, String name, Object value) throws Exception {
        Field field = BridgeMessage.class.getDeclaredField(name);
        field.setAccessible(true);
        field.set(message, value);
    }

    private static String errorCode(PolicyDecision decision) {
        try {
            BridgeError error = decision.getError();
            Field code = BridgeError.class.getDeclaredField("code");
            code.setAccessible(true);
            return (String) code.get(error);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
