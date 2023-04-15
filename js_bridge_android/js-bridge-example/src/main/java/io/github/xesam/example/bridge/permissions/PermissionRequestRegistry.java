package io.github.xesam.example.bridge.permissions;

import androidx.annotation.NonNull;

public interface PermissionRequestRegistry {
    boolean requestPermissions(String[] permissions, PermissionResultCallback callback);

    boolean dispatchResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults);

    void destroy();
}
