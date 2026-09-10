package com.rspetstop.driverapp;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;

import androidx.core.content.ContextCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

// JS-facing bridge for DriverTrackingService. Does no location work itself - only (a) requests the
// runtime permissions that require a live Activity, and (b) hands credentials + start/stop signals
// to the service, which then runs fully independently of this Activity/WebView. Replaces
// @capacitor-community/background-geolocation + @capacitor/local-notifications entirely - see
// C:\Users\roies\.claude\plans\immutable-exploring-moore.md for why both were dropped.
@CapacitorPlugin(
    name = "DriverTracking",
    permissions = {
        @Permission(strings = { Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION }, alias = "location"),
        @Permission(strings = { Manifest.permission.POST_NOTIFICATIONS }, alias = "notifications")
    }
)
public class DriverTrackingPlugin extends Plugin {

    @PluginMethod
    public void startTracking(PluginCall call) {
        String username = call.getString("username");
        String password = call.getString("password");
        if (username == null || password == null) {
            call.reject("username and password are required.");
            return;
        }

        saveCredentials(username, password);

        if (getPermissionState("location") != PermissionState.GRANTED) {
            requestPermissionForAlias("location", call, "locationPermissionCallback");
            return;
        }
        proceedAfterLocationPermission(call);
    }

    @PermissionCallback
    private void locationPermissionCallback(PluginCall call) {
        if (getPermissionState("location") != PermissionState.GRANTED) {
            call.reject("Location permission denied.", "NOT_AUTHORIZED");
            return;
        }
        proceedAfterLocationPermission(call);
    }

    // Notification permission (Android 13+) is best-effort and never blocks tracking - without it
    // the foreground service still runs and still gets location updates, only the persistent
    // notification is hidden (see SETUP.md).
    private void proceedAfterLocationPermission(PluginCall call) {
        if (Build.VERSION.SDK_INT >= 33 && getPermissionState("notifications") != PermissionState.GRANTED) {
            requestPermissionForAlias("notifications", call, "notificationPermissionCallback");
            return;
        }
        startService(call);
    }

    @PermissionCallback
    private void notificationPermissionCallback(PluginCall call) {
        startService(call);
    }

    private void startService(PluginCall call) {
        Intent intent = new Intent(getContext(), DriverTrackingService.class);
        ContextCompat.startForegroundService(getContext(), intent);
        call.resolve();
    }

    @PluginMethod
    public void stopTracking(PluginCall call) {
        clearCredentials();
        getContext().stopService(new Intent(getContext(), DriverTrackingService.class));
        call.resolve();
    }

    @PluginMethod
    public void isTracking(PluginCall call) {
        JSObject result = new JSObject();
        result.put("tracking", DriverTrackingService.isRunning());
        call.resolve(result);
    }

    private void saveCredentials(String username, String password) {
        prefs().edit()
                .putString(DriverTrackingService.PREF_USERNAME, username)
                .putString(DriverTrackingService.PREF_PASSWORD, password)
                .apply();
    }

    private void clearCredentials() {
        prefs().edit().clear().apply();
    }

    private SharedPreferences prefs() {
        return getContext().getSharedPreferences(DriverTrackingService.PREFS_NAME, Context.MODE_PRIVATE);
    }
}
