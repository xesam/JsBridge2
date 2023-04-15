package io.github.xesam.example.bridge.permissions;

public interface PermissionResultCallback {
    void onResult(boolean granted, boolean permanentlyDenied);
}
