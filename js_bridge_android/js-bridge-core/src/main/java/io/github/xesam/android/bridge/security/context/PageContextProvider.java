package io.github.xesam.android.bridge.security.context;

import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;

public interface PageContextProvider {
    TrustedPageContext createContext(BridgeMessage bridgeMessage, String pageInstanceId);
}
