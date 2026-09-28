package io.github.xesam.android.bridge.security.policy;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.security.session.SessionRecord;

public final class SessionPolicy implements PolicyRule {

    @Override
    public PolicyDecision evaluate(PolicyInput input) {
        if (BridgeApiContract.METHOD_HANDSHAKE.equals(input.getMessage().getMethod())) {
            return PolicyDecision.allow();
        }
        SessionRecord sessionRecord = input.getSessionRecord();
        String origin = input.getTrustedPageContext().getOrigin();
        String pageInstanceId = input.getTrustedPageContext().getPageInstanceId();
        if (sessionRecord == null) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, "session is required"));
        }
        if (!sessionRecord.getOrigin().equals(origin)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, "session origin mismatch"));
        }
        if (!sessionRecord.getPageInstanceId().equals(pageInstanceId)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, "session page mismatch"));
        }
        return PolicyDecision.allow();
    }

    @Override
    public String name() {
        return "SessionPolicy";
    }
}
