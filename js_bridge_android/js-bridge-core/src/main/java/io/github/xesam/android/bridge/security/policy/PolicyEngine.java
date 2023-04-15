package io.github.xesam.android.bridge.security.policy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class PolicyEngine {
    private final List<PolicyRule> rules;

    public PolicyEngine(List<PolicyRule> rules) {
        this.rules = Collections.unmodifiableList(new ArrayList<>(rules));
    }

    public PolicyDecision evaluate(PolicyInput input) {
        for (PolicyRule rule : rules) {
            PolicyDecision decision = rule.evaluate(input);
            if (!decision.isAllowed()) {
                return decision;
            }
        }
        return PolicyDecision.allow();
    }
}
