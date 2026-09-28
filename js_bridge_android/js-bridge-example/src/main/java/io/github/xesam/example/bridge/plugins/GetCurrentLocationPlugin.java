package io.github.xesam.example.bridge.plugins;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.concurrent.atomic.AtomicBoolean;

import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.handler.AsyncHandler;
import io.github.xesam.android.bridge.core.handler.ResponseEmitter;
import io.github.xesam.example.bridge.JsonPayloadParser;
import io.github.xesam.example.bridge.permissions.PermissionRequestRegistry;
import io.github.xesam.example.bridge.permissions.PermissionResultCallback;

public final class GetCurrentLocationPlugin implements AsyncHandler {
    private static final long DEFAULT_TIMEOUT_MS = 10_000L;

    private final Context context;
    private final PermissionRequestRegistry permissionRequestRegistry;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final AtomicBoolean requesting = new AtomicBoolean(false);

    public GetCurrentLocationPlugin(Context context, PermissionRequestRegistry permissionRequestRegistry) {
        this.context = context;
        this.permissionRequestRegistry = permissionRequestRegistry;
    }

    @Override
    public void handle(
            TrustedPageContext trustedPageContext,
            JSONObject payload,
            ResponseEmitter emitter) {
        Payload locationPayload = new LocationPayloadParser().getPayload(payload == null ? "" : payload.toString());
        boolean fine = locationPayload != null && "fine".equalsIgnoreCase(locationPayload.accuracy);
        long timeoutMs = locationPayload == null || locationPayload.timeoutMs <= 0 ? DEFAULT_TIMEOUT_MS : locationPayload.timeoutMs;

        if (!requesting.compareAndSet(false, true)) {
            emitter.fail(new BridgeError("E_BUSY", "location request is already in progress"));
            return;
        }
        ensurePermissionAndLoadLocation(fine, timeoutMs, emitter);
    }

    private void ensurePermissionAndLoadLocation(boolean fine, long timeoutMs, ResponseEmitter emitter) {
        String permission = requiredPermission(fine);
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            loadLocation(fine, timeoutMs, emitter);
            return;
        }
        boolean started = permissionRequestRegistry.requestPermissions(new String[]{permission}, new PermissionResultCallback() {
            @Override
            public void onResult(boolean granted, boolean permanentlyDenied) {
                if (granted) {
                    loadLocation(fine, timeoutMs, emitter);
                    return;
                }
                requesting.set(false);
                if (permanentlyDenied) {
                    JSONObject details = new JSONObject();
                    try {
                        details.put("canOpenSettings", true);
                    } catch (JSONException ignored) {
                    }
                    emitter.fail(new BridgeError(
                            "E_PERMISSION_PERMANENTLY_DENIED",
                            "Location permission permanently denied",
                            false,
                            details));
                    return;
                }
                emitter.fail(new BridgeError("E_PERMISSION_DENIED", "Location permission denied"));
            }
        });
        if (!started) {
            requesting.set(false);
            emitter.fail(new BridgeError("E_BUSY", "permission request is already in progress"));
        }
    }

    private void loadLocation(boolean fine, long timeoutMs, ResponseEmitter emitter) {
        LocationManager locationManager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
        if (locationManager == null) {
            requesting.set(false);
            emitter.fail(new BridgeError("E_LOCATION_UNAVAILABLE", "Location manager unavailable"));
            return;
        }
        String provider = chooseProvider(locationManager, fine);
        if (provider == null) {
            requesting.set(false);
            emitter.fail(new BridgeError("E_LOCATION_UNAVAILABLE", "No enabled location provider"));
            return;
        }

        Location last = findLastKnownLocation(locationManager, fine);
        if (last != null) {
            requesting.set(false);
            emitter.success(toPayload(last), true);
            return;
        }

        requestSingleLocation(locationManager, provider, timeoutMs, emitter);
    }

    @SuppressWarnings("MissingPermission")
    private void requestSingleLocation(
            LocationManager locationManager,
            String provider,
            long timeoutMs,
            ResponseEmitter emitter) {
        AtomicBoolean settled = new AtomicBoolean(false);
        final LocationListener[] listenerHolder = new LocationListener[1];
        Runnable timeoutTask = () -> {
            if (!settled.compareAndSet(false, true)) {
                return;
            }
            if (listenerHolder[0] != null) {
                locationManager.removeUpdates(listenerHolder[0]);
            }
            requesting.set(false);
            emitter.fail(new BridgeError("E_INTERNAL", "Location request timeout"));  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
        };
        mainHandler.postDelayed(timeoutTask, timeoutMs);

        LocationListener listener = new LocationListener() {
            @Override
            public void onLocationChanged(@NonNull Location location) {
                if (!settled.compareAndSet(false, true)) {
                    return;
                }
                mainHandler.removeCallbacks(timeoutTask);
                locationManager.removeUpdates(this);
                requesting.set(false);
                emitter.success(toPayload(location), true);
            }

            @Override
            public void onProviderDisabled(@NonNull String provider) {
                if (!settled.compareAndSet(false, true)) {
                    return;
                }
                mainHandler.removeCallbacks(timeoutTask);
                locationManager.removeUpdates(this);
                requesting.set(false);
                emitter.fail(new BridgeError("E_LOCATION_UNAVAILABLE", "Location provider disabled"));
            }

            @Override
            public void onStatusChanged(String provider, int status, Bundle extras) {
                // no-op
            }
        };
        listenerHolder[0] = listener;
        locationManager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper());
    }

    @SuppressWarnings("MissingPermission")
    private Location findLastKnownLocation(LocationManager locationManager, boolean fine) {
        if (fine) {
            Location gps = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER);
            if (gps != null) {
                return gps;
            }
        }
        Location network = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER);
        if (network != null) {
            return network;
        }
        return locationManager.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER);
    }

    private String chooseProvider(LocationManager locationManager, boolean fine) {
        if (fine && locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            return LocationManager.GPS_PROVIDER;
        }
        if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
            return LocationManager.NETWORK_PROVIDER;
        }
        if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            return LocationManager.GPS_PROVIDER;
        }
        return null;
    }

    private String requiredPermission(boolean fine) {
        if (fine) {
            return Manifest.permission.ACCESS_FINE_LOCATION;
        }
        return Manifest.permission.ACCESS_COARSE_LOCATION;
    }

    private JSONObject toPayload(Location location) {
        JSONObject jsonObject = new JSONObject();
        try {
            jsonObject.put("lat", location.getLatitude());
            jsonObject.put("lng", location.getLongitude());
            jsonObject.put("accuracy", location.getAccuracy());
            jsonObject.put("provider", location.getProvider());
            jsonObject.put("timestamp", location.getTime());
        } catch (Exception ignored) {
        }
        return jsonObject;
    }

    public static class LocationPayloadParser extends JsonPayloadParser<Payload> {
        @Override
        protected Class<Payload> getValueType() {
            return Payload.class;
        }
    }

    public static final class Payload {
        public String accuracy;
        public long timeoutMs;
    }
}
