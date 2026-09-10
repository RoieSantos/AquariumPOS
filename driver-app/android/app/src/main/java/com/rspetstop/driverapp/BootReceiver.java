package com.rspetstop.driverapp;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

import androidx.core.content.ContextCompat;

// Starts DriverTrackingService directly (not MainActivity) if a session was saved from a previous
// login - no UI needs to open for tracking to resume. Starting a foreground service from a
// BOOT_COMPLETED receiver is a documented Android exemption from the foreground-service launch
// restrictions, and is more reliable on modern Android than launching an Activity from a
// background broadcast (which is far more restricted).
//
// Best-effort, not guaranteed: most phone brands sold in the Philippines (Xiaomi/Redmi's MIUI,
// Realme/Oppo's ColorOS, Vivo's FunTouch, Samsung's One UI, etc.) block third-party apps from
// auto-starting after boot unless the user manually whitelists the app in that brand's battery/
// autostart settings - this is a manufacturer-level restriction with no code-level workaround, see
// SETUP.md for the manual toggle each brand uses.
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;

        SharedPreferences prefs = context.getSharedPreferences(
                DriverTrackingService.PREFS_NAME, Context.MODE_PRIVATE);
        boolean hasSession = prefs.getString(DriverTrackingService.PREF_USERNAME, null) != null
                && prefs.getString(DriverTrackingService.PREF_PASSWORD, null) != null;

        if (hasSession) {
            ContextCompat.startForegroundService(context,
                    new Intent(context, DriverTrackingService.class));
        }
    }
}
