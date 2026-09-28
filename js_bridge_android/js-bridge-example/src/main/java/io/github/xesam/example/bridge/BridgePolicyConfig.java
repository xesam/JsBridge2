package io.github.xesam.example.bridge;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

import io.github.xesam.android.bridge.JsBridge;

final class BridgePolicyConfig {
    private BridgePolicyConfig() {
    }

    static JsBridge.SecurityConfig createSecurityConfig() {
        return new JsBridge.SecurityConfig()
                .allowedOrigins(new HashSet<>(Arrays.asList("file://", "https://example.com")))
                .methodWhitelist(allowedMethods());
    }

    private static Set<String> allowedMethods() {
        // methodWhitelist 语义为业务方法白名单，协议方法（bridge.handshake 等）由框架自动放行
        return new HashSet<>(Arrays.asList(
                "getUser",
                "getCurrentLocation",
                "request",
                "timerLog",
                "showLoading",
                "pickImage",
                "pickInput"));
    }
}
