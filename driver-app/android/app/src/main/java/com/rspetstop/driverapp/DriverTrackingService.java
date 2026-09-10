package com.rspetstop.driverapp;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.os.Build;
import android.os.HandlerThread;
import android.os.IBinder;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;

import com.google.android.gms.location.FusedLocationProviderClient;
import com.google.android.gms.location.LocationAvailability;
import com.google.android.gms.location.LocationCallback;
import com.google.android.gms.location.LocationRequest;
import com.google.android.gms.location.LocationResult;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.location.Priority;

import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

// Standalone, start-only (never bound) foreground Service that owns GPS watching + HTTP reporting
// completely independently of MainActivity/the WebView, specifically to survive the user swiping
// the app away from Recents. @capacitor-community/background-geolocation's
// BackgroundGeolocationService.onUnbind() deliberately called removeLocationUpdates()+stopSelf()
// the moment its one-and-only binder (the Activity) disconnected - which is exactly what happens
// on swipe-away (that plugin's own GitHub issue #59 explains why: a location callback firing after
// the app process is torn down mid-flight can crash with "Handler sending message to a dead
// thread"). This class sidesteps that whole failure family by never being bound to anything in the
// first place (onBind returns null), and by owning a Looper/HandlerThread that lives and dies with
// the Service itself, never with the Activity.
public class DriverTrackingService extends Service {
    private static final String TAG = "DriverTrackingService";
    static final String PREFS_NAME = "driver_tracking_prefs";
    static final String PREF_USERNAME = "username";
    static final String PREF_PASSWORD = "password";

    // Duplicated from src/config.js - native code can't import the JS module. If the Supabase
    // project/anon key ever changes, update both places.
    private static final String SUPABASE_URL = "https://hymcmesqgpliyyeghpgq.supabase.co";
    private static final String SUPABASE_ANON_KEY = "sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz";

    private static final String CHANNEL_ID = "driver_tracking";
    private static final int NOTIFICATION_ID = 4821;
    private static final float DISTANCE_FILTER_METERS = 30f;
    private static final long INTERVAL_MS = 15000; // also fires periodically even when stationary

    private static volatile boolean running = false;
    static boolean isRunning() { return running; }

    private HandlerThread handlerThread;
    private ExecutorService httpExecutor;
    private FusedLocationProviderClient fusedLocationClient;
    private LocationCallback locationCallback;
    private boolean requestingLocationUpdates = false;

    @Override
    public IBinder onBind(Intent intent) {
        // Deliberately start-only. Returning null means nothing can ever bind, so there is no
        // bind/unbind lifecycle for this service to react to - this is the actual fix.
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        handlerThread = new HandlerThread("DriverTrackingLocationThread");
        handlerThread.start();
        httpExecutor = Executors.newSingleThreadExecutor();
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(getApplicationContext());
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Credentials always come from SharedPreferences, never from Intent extras - onStartCommand
        // can be re-invoked by Android with a null/empty Intent (START_STICKY restart,
        // onTaskRemoved's defensive restart, BootReceiver), so every restart path must resolve
        // identically without depending on how it was triggered.
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String username = prefs.getString(PREF_USERNAME, null);
        String password = prefs.getString(PREF_PASSWORD, null);

        if (username == null || password == null) {
            stopSelf();
            return START_NOT_STICKY;
        }

        startForegroundCompat();

        if (!requestingLocationUpdates) {
            startLocationUpdates(username, password);
        }

        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        super.onTaskRemoved(rootIntent);
        // Task removed (app swiped away) while already a running foreground service - on
        // stock/most Android that alone is enough to keep running (see class header). This restart
        // is a defensive safety net for OEMs (MIUI/ColorOS/etc) that kill the whole process on
        // swipe despite the foreground service + battery-unrestricted setting; the primary defense
        // against those remains the manufacturer autostart/battery whitelist in SETUP.md, not this
        // call. Safe to call from here (in-process, on an app that currently owns a foreground
        // service) unlike starting one from a cold background broadcast.
        Intent restartIntent = new Intent(getApplicationContext(), DriverTrackingService.class);
        try {
            ContextCompat.startForegroundService(getApplicationContext(), restartIntent);
        } catch (Exception e) {
            Log.e(TAG, "Defensive restart from onTaskRemoved failed", e);
        }
    }

    @Override
    public void onDestroy() {
        requestingLocationUpdates = false;
        running = false;
        if (fusedLocationClient != null && locationCallback != null) {
            fusedLocationClient.removeLocationUpdates(locationCallback);
        }
        if (httpExecutor != null) {
            httpExecutor.shutdownNow();
        }
        if (handlerThread != null) {
            handlerThread.quitSafely();
        }
        super.onDestroy();
    }

    private void startLocationUpdates(final String username, final String password) {
        LocationRequest locationRequest = new LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_MS)
                .setMinUpdateDistanceMeters(DISTANCE_FILTER_METERS)
                .setWaitForAccurateLocation(false)
                .build();

        locationCallback = new LocationCallback() {
            @Override
            public void onLocationResult(LocationResult locationResult) {
                Location location = locationResult.getLastLocation();
                if (location != null) {
                    reportLocation(username, password, location);
                }
            }

            @Override
            public void onLocationAvailability(LocationAvailability availability) {
                if (!availability.isLocationAvailable()) {
                    Log.w(TAG, "Location temporarily unavailable.");
                }
            }
        };

        try {
            // Explicit Looper owned by (and torn down with) this Service - never the Activity/UI
            // thread - is the crash-safety fix for issue #59.
            fusedLocationClient.requestLocationUpdates(locationRequest, locationCallback, handlerThread.getLooper());
            requestingLocationUpdates = true;
            running = true;
        } catch (SecurityException e) {
            Log.e(TAG, "Location permission missing when starting updates.", e);
            stopSelf();
        }
    }

    private void reportLocation(final String username, final String password, final Location location) {
        // Offloaded to a dedicated single-thread executor, not the location-callback thread
        // itself, so a slow/blocked HTTP call never delays delivery of the next location fix.
        httpExecutor.execute(() -> {
            try {
                sendLocationUpdate(username, password, location);
            } catch (Exception e) {
                // Best-effort, no retry queue - the next fix (within ~INTERVAL_MS or
                // DISTANCE_FILTER_METERS) simply tries again; stale coordinates aren't worth
                // re-sending.
                Log.w(TAG, "driver_update_location failed, will retry on next fix.", e);
            }
        });
    }

    private void sendLocationUpdate(String username, String password, Location location) throws Exception {
        JSONObject body = new JSONObject();
        body.put("p_username", username);
        body.put("p_password", password);
        body.put("p_latitude", location.getLatitude());
        body.put("p_longitude", location.getLongitude());
        body.put("p_recorded_at_utc", Instant.ofEpochMilli(location.getTime()).toString());

        URL url = new URL(SUPABASE_URL + "/rest/v1/rpc/driver_update_location");
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        try {
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setRequestProperty("apikey", SUPABASE_ANON_KEY);
            conn.setRequestProperty("Authorization", "Bearer " + SUPABASE_ANON_KEY);

            try (OutputStream os = conn.getOutputStream()) {
                os.write(body.toString().getBytes(StandardCharsets.UTF_8));
            }

            int status = conn.getResponseCode();
            if (status < 200 || status >= 300) {
                Log.w(TAG, "driver_update_location returned HTTP " + status);
            }
        } finally {
            conn.disconnect();
        }
    }

    private void startForegroundCompat() {
        Notification notification = buildNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    private Notification buildNotification() {
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent contentIntent = null;
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
            contentIntent = PendingIntent.getActivity(this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE);
        }

        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("RS Pet Stop Driver")
                .setContentText("Sharing your location for today's deliveries.")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setContentIntent(contentIntent)
                .build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Background Tracking", NotificationManager.IMPORTANCE_LOW);
            channel.setSound(null, null);
            channel.enableVibration(false);
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) manager.createNotificationChannel(channel);
        }
    }
}
