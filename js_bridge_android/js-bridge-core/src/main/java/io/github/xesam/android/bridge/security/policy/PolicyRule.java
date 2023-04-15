package io.github.xesam.android.bridge.security.policy;

public interface PolicyRule {
    PolicyDecision evaluate(PolicyInput input);

    String name();
}
