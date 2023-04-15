package io.github.xesam.android.bridge.security.policy;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.contract.BridgeApiContract;

public final class HandshakeGatePolicy implements PolicyRule {
    @Override
    public PolicyDecision evaluate(PolicyInput input) {
        String method = input.getMessage().getMethod();
        if (BridgeApiContract.METHOD_HANDSHAKE.equals(method)) {
            return PolicyDecision.allow();
        }
        if (!input.isReady()) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_POLICY_DENY, "bridge handshake required"));
        }
        return PolicyDecision.allow();
    }

    @Override
    public String name() {
        return "HandshakeGatePolicy";
    }
}
