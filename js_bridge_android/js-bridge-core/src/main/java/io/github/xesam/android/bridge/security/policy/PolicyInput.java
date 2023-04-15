package io.github.xesam.android.bridge.security.policy;


import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.security.session.SessionRecord;

public final class PolicyInput {
    private final BridgeMessage message;
    private final TrustedPageContext trustedPageContext;
    private final boolean ready;
        private final SessionRecord sessionRecord;

    public PolicyInput(BridgeMessage message, TrustedPageContext trustedPageContext, boolean ready, SessionRecord sessionRecord) {
        this.message = message;
        this.trustedPageContext = trustedPageContext;
        this.ready = ready;
        this.sessionRecord = sessionRecord;
    }

    public BridgeMessage getMessage() {
        return message;
    }

    public TrustedPageContext getTrustedPageContext() {
        return trustedPageContext;
    }

    public boolean isReady() {
        return ready;
    }

        public SessionRecord getSessionRecord() {
        return sessionRecord;
    }
}
