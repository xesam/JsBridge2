package io.github.xesam.android.bridge.security.policy;

import java.util.Set;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.security.session.SessionRecord;

public final class AccessControlPolicy implements PolicyRule {
    private final Set<String> allowedOrigins;
    private final Set<String> allowedMethods;

    public AccessControlPolicy(Set<String> allowedOrigins, Set<String> allowedMethods) {
        this.allowedOrigins = allowedOrigins;
        this.allowedMethods = allowedMethods;
    }

    @Override
    public PolicyDecision evaluate(PolicyInput input) {
        String method = input.getMessage().getMethod();
        String origin = input.getTrustedPageContext().getOrigin();

        if (!allowedOrigins.contains("*") && !allowedOrigins.contains(origin)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_ORIGIN_DENY, "origin not allowed: " + origin));
        }

        if (!allowedMethods.contains(method)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_METHOD_NOT_ALLOWED, "method not allowed: " + method));
        }

        if (BridgeApiContract.METHOD_HANDSHAKE.equals(method)) {
            return PolicyDecision.allow();
        }

        SessionRecord sessionRecord = input.getSessionRecord();
        if (sessionRecord == null) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, "session is required"));
        }
        if (!sessionRecord.getOrigin().equals(origin)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, "session origin mismatch"));
        }
        if (!sessionRecord.getPageInstanceId().equals(input.getTrustedPageContext().getPageInstanceId())) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, "session page mismatch"));
        }
        if (!sessionRecord.getCapabilities().contains(method)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_CAPABILITY_DENY, "capability denied: " + method));
        }
        return PolicyDecision.allow();
    }

    @Override
    public String name() {
        return "AccessControlPolicy";
    }
}
