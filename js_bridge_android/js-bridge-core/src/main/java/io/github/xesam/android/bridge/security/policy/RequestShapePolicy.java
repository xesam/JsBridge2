package io.github.xesam.android.bridge.security.policy;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;

public final class RequestShapePolicy implements PolicyRule {
    @Override
    public PolicyDecision evaluate(PolicyInput input) {
        String method = input.getMessage().getMethod();
        if (method == null || method.trim().isEmpty()) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_INVALID_MESSAGE, "method is required"));
        }
        if (!input.getMessage().isRequest()) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_INVALID_MESSAGE, "only request messages are accepted"));
        }
        return PolicyDecision.allow();
    }

    @Override
    public String name() {
        return "RequestShapePolicy";
    }
}
