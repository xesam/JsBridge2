package io.github.xesam.android.bridge.security.policy;

import java.util.Set;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;

public final class MethodGatePolicy implements PolicyRule {
    private final Set<String> methodWhitelist;

    public MethodGatePolicy(Set<String> methodWhitelist) {
        this.methodWhitelist = methodWhitelist;
    }

    @Override
    public PolicyDecision evaluate(PolicyInput input) {
        String method = input.getMessage().getMethod();
        if (!methodWhitelist.contains(method)) {
            return PolicyDecision.deny(name(), new BridgeError(BridgeApiContract.ERR_METHOD_NOT_ALLOWED, "method not allowed: " + method));
        }
        return PolicyDecision.allow();
    }

    @Override
    public String name() {
        return "MethodGatePolicy";
    }
}
