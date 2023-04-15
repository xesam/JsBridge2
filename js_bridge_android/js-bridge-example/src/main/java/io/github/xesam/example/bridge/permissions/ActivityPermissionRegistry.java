package io.github.xesam.example.bridge.permissions;

import android.app.Activity;
import android.content.pm.PackageManager;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;

public final class ActivityPermissionRegistry implements PermissionRequestRegistry {
    private static final int REQUEST_CODE = 0x4A38;

    private final Activity activity;
    private PermissionResultCallback callback;
    private String[] pendingPermissions;

    public ActivityPermissionRegistry(Activity activity) {
        this.activity = activity;
    }

    @Override
    public synchronized boolean requestPermissions(String[] permissions, PermissionResultCallback callback) {
        if (this.callback != null) {
            return false;
        }
        this.callback = callback;
        this.pendingPermissions = permissions;
        ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE);
        return true;
    }

    @Override
    public synchronized boolean dispatchResult(
            int requestCode,
            @NonNull String[] permissions,
            @NonNull int[] grantResults) {
        if (requestCode != REQUEST_CODE || callback == null) {
            return false;
        }
        PermissionResultCallback currentCallback = callback;
        callback = null;

        boolean granted = true;
        for (int result : grantResults) {
            if (result != PackageManager.PERMISSION_GRANTED) {
                granted = false;
                break;
            }
        }

        boolean permanentlyDenied = false;
        if (!granted && pendingPermissions != null) {
            for (String permission : pendingPermissions) {
                if (!ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)) {
                    permanentlyDenied = true;
                    break;
                }
            }
        }
        pendingPermissions = null;
        currentCallback.onResult(granted, permanentlyDenied);
        return true;
    }

    @Override
    public synchronized void destroy() {
        callback = null;
        pendingPermissions = null;
    }
}
