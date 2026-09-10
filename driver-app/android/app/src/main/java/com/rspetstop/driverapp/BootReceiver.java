package com.rspetstop.driverapp;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// Relaunches MainActivity right after the phone finishes booting, so a driver never has to open
// the app themselves for tracking to resume - src/main.js's own init() decides whether to
// actually start tracking (only if a session is already saved from a previous login), so this
// receiver doesn't need to know or care about login/tracking state itself.
//
// Best-effort, not guaranteed: many phone brands sold in the Philippines (Xiaomi/Redmi's MIUI,
// Realme/Oppo's ColorOS, Vivo's FunTouch, Samsung's One UI, etc.) block third-party apps from
// auto-starting after boot unless the user manually whitelists the app in that brand's battery/
// autostart settings - this is a manufacturer-level restriction with no code-level workaround, see
// SETUP.md for the manual toggle each brand uses.
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            Intent launchIntent = new Intent(context, MainActivity.class);
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            context.startActivity(launchIntent);
        }
    }
}
