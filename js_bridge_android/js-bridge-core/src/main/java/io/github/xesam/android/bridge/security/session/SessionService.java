package io.github.xesam.android.bridge.security.session;


import io.github.xesam.android.bridge.api.model.TrustedPageContext;

public interface SessionService {
        SessionRecord find(String sessionId);

    HandshakeResult issueHandshake(TrustedPageContext trustedPageContext);

    void clearByPageInstance(String pageInstanceId);

    void clearAll();
}
