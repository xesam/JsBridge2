package io.github.xesam.example.bridge;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.JsBridge;

final class BridgePolicyConfig {
    private BridgePolicyConfig() {
    }

    static JsBridge.KernelConfig createKernelConfig() {
        return new JsBridge.KernelConfig()
                .maxReadyListeners(16);
    }

    static JsBridge.SecurityConfig createSecurityConfig() {
        return JsBridge.SecurityConfig.secure()
                .allowedOrigins(new HashSet<>(Arrays.asList("file://", "https://example.com")))
                .methodWhitelist(allowedMethods())
                .defaultCapabilities(capabilities());
    }

    private static Set<String> allowedMethods() {
        return new HashSet<>(Arrays.asList(
                BridgeApiContract.METHOD_HANDSHAKE,
                "getUser",
                "getCurrentLocation",
                "request",
                "timerLog",
                "showLoading",
                "pickImage",
                "pickInput"));
    }

    private static Set<String> capabilities() {
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
