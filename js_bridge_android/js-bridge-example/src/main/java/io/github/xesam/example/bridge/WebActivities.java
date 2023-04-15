package io.github.xesam.example.bridge;

import android.content.Context;

import io.github.xesam.android.bridge.extensions.registry.BridgeResultRegistry;
import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.example.bridge.permissions.PermissionRequestRegistry;
import io.github.xesam.example.bridge.extensions.request.RequestExt;
import io.github.xesam.example.bridge.extensions.timer.TimerExt;
import io.github.xesam.example.bridge.extensions.user.UserExt;
import io.github.xesam.example.bridge.plugins.GetCurrentLocationPlugin;
import io.github.xesam.example.bridge.plugins.LoadingPlugin;
import io.github.xesam.example.bridge.plugins.PickImagePlugin;
import io.github.xesam.example.bridge.plugins.PickInputPlugin;

public final class WebActivities {
    static void setupBridge(
            JsBridge bridge,
            Context context,
            BridgeResultRegistry bridgeResultRegistry,
            PermissionRequestRegistry permissionRequestRegistry) {
        bridge.registerNativeHandler("getUser", new UserExt());
        bridge.registerNativeHandler("getCurrentLocation", new GetCurrentLocationPlugin(context, permissionRequestRegistry));
        bridge.registerNativeHandler("request", new RequestExt());
        bridge.registerNativeHandler("timerLog", new TimerExt());
        bridge.registerNativeHandler("showLoading", new LoadingPlugin(context));
        bridge.registerNativeHandler("pickImage", new PickImagePlugin(context, bridgeResultRegistry));
        bridge.registerNativeHandler("pickInput", new PickInputPlugin(context, bridgeResultRegistry));
    }
}
