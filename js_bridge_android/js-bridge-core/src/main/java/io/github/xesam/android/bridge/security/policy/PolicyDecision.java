package io.github.xesam.android.bridge.security.policy;


import io.github.xesam.android.bridge.api.model.BridgeError;

public final class PolicyDecision {
    private static final PolicyDecision ALLOW = new PolicyDecision(true, null, "ALLOW");

    private final boolean allowed;
    private final BridgeError error;
    private final String rule;

    private PolicyDecision(boolean allowed, BridgeError error, String rule) {
        this.allowed = allowed;
        this.error = error;
        this.rule = rule;
    }

    public static PolicyDecision allow() {
        return ALLOW;
    }

    public static PolicyDecision deny(String rule, BridgeError error) {
        return new PolicyDecision(false, error, rule);
    }

    public boolean isAllowed() {
        return allowed;
    }

        public BridgeError getError() {
        return error;
    }

    public String getRule() {
        return rule;
    }
}
