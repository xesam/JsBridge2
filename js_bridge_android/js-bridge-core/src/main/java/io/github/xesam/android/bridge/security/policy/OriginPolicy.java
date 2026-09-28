package io.github.xesam.android.bridge.security.policy;

import java.util.Set;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;

public final class OriginPolicy implements PolicyRule {
    private final Set<String> allowedOrigins;

    public OriginPolicy(Set<String> allowedOrigins) {
        this.allowedOrigins = allowedOrigins;
    }

    @Override
    public PolicyDecision evaluate(PolicyInput input) {
        String origin = input.getTrustedPageContext().getOrigin();
        if (!allowedOrigins.contains(origin)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_ORIGIN_DENY, "origin not allowed: " + origin));
        }
        return PolicyDecision.allow();
    }

    @Override
    public String name() {
        return "OriginPolicy";
    }
}
