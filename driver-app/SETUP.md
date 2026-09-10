# Driver App Setup

Android app that RS Pet Stop delivery drivers install on their phone. There is no "Start
Tracking" button - tracking begins automatically the moment the app opens with a saved login
(a normal open, a resume, or the app auto-relaunching itself after the phone restarts - see
`BootReceiver.java` and `startTracking()`/`init()` in `src/main.js`), and keeps sending GPS pings
to Supabase even while backgrounded (e.g. the driver switched to Waze, or the screen is locked).
The only way to turn it off is "Log Out" in the app. See
[supabase_driver_locations_table.sql](../sql/supabase_driver_locations_table.sql) and the driver
pin plotted on the portal's Delivery page (`docs/delivery.html`).

**Worth knowing before rolling this out**: because tracking auto-resumes after every phone
restart with no login step required, it runs continuously any time the phone is on - including
outside delivery hours, weekends, or personal use of the phone - until a driver explicitly logs
out. Make sure drivers understand this (and are comfortable with it) before installing the app,
since it's a real difference from "only tracked while working."

## 1. One-time machine setup

- Install [Node.js LTS](https://nodejs.org).
- Install [Android Studio](https://developer.android.com/studio), open it once, and let it install
  the Android SDK (accept the first-run setup wizard's defaults, or Settings ->
  Languages & Frameworks -> Android SDK).

Two things in `capacitor.config.json` are already set correctly in this repo and don't need
touching, but are worth knowing about since they're easy to accidentally undo:
- `android.useLegacyBridge: true` - without this, `@capacitor-community/background-geolocation`
  stops delivering updates after ~5 minutes backgrounded (see the plugin's own README).
- `plugins.CapacitorHttp.enabled: true` - routes network requests (including every
  `driver_update_location` call to Supabase) through native code instead of the WebView. Without
  it, Android throttles WebView-originated HTTP requests after ~5 minutes backgrounded, so
  location pings would silently stop reaching the server even though the GPS watcher itself is
  still running - this is the single most important setting for this app's entire purpose.

## 2. Build the web assets and Android project

From this `driver-app/` folder:

```
npm install
npm run build
npx cap add android
npx cap sync android
```

`npx cap add android` only needs to run once - it generates the `android/` folder. Every time you
change anything under `src/`, re-run `npm run sync` (build + `cap sync`) before reopening Android
Studio.

## 3. Android permissions - no manual manifest edits needed

Checked directly in `node_modules/@capacitor-community/background-geolocation/android/src/main/AndroidManifest.xml`
and `node_modules/@capacitor/local-notifications/android/src/main/AndroidManifest.xml`: both
plugins already declare everything they need (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`,
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`, plus a couple
notification-scheduling permissions) in their own bundled manifests. Gradle's manifest merger
pulls all of this into the app automatically at build time - `android/app/src/main/AndroidManifest.xml`
does not need to be hand-edited for permissions.

Notably, neither plugin declares `ACCESS_BACKGROUND_LOCATION`. That's deliberate, not missing:
the plugin runs a foreground service with a visible notification (`foregroundServiceType="location"`),
and Android grants a foreground service the same location access as an app in active use, without
needing that separate (and more sensitive/scrutinized) permission. Practically, this means the
driver will only see "While using the app" as a location option, not "Allow all the time" - that's
expected, and is sufficient as long as the "tracking active" notification stays visible (i.e. the
driver doesn't force-stop the app).

If you ever change which background-geolocation plugin/version this app uses, re-check its bundled
manifest the same way before assuming any permission is missing.

## 4. Build and install on a driver's phone

- Open `android/` in Android Studio.
- Test first on a **physical phone**, not an emulator - background GPS behaves unreliably in
  emulators.
- Build -> Generate Signed Bundle / APK... to produce a signed release `.apk`.
- Upload the `.apk` somewhere the driver's phone can download it (e.g. a Google Drive link).
- On the phone: open that link, tap Download, then Install. Android will prompt to allow installs
  from that source the first time - the driver approves it once.
- On first launch, log in with a `DeliveryTeam` account (a Super User account also works, for
  testing). Grant location when prompted ("While using the app" is the only option offered, and
  is sufficient - see the permissions note in step 3) and allow notifications when prompted (this
  is what shows the persistent "tracking active" notification that keeps location updates flowing
  in the background).
- Go to phone Settings -> Apps -> RS Pet Stop Driver -> Battery, and set it to **Unrestricted** so
  Android doesn't kill the background service to save power.
- **Enable "autostart" for the app.** `BootReceiver.java` relaunches the app after the phone
  restarts, but most phone brands sold in the Philippines block third-party apps from
  auto-starting after boot by default, regardless of any code-level fix - this is a manufacturer
  restriction, not a bug in this app. The driver needs to manually whitelist the app once, in
  whichever menu their phone brand uses:
  - **Xiaomi/Redmi/POCO (MIUI/HyperOS)**: Settings -> Apps -> Manage apps -> RS Pet Stop Driver ->
    Autostart -> enable.
  - **Realme/Oppo (ColorOS)**: Settings -> Battery -> App Battery Management -> RS Pet Stop Driver
    -> allow background activity / disable "sleep" for the app.
  - **Vivo (FunTouch/OriginOS)**: Settings -> Battery -> Background power consumption management
    -> allow the app to run in the background.
  - **Samsung (One UI)**: Settings -> Apps -> RS Pet Stop Driver -> Battery -> Unrestricted (same
    setting as above already covers this on Samsung).
  - Menu names/locations vary by Android version even within the same brand - if unsure, search
    "[phone brand] autostart permission" for that specific model.

## 5. End-to-end test

1. Log in on the phone - tracking starts immediately, no button to tap.
2. Open `delivery.html` on the portal for today's date (Driver Route View, or the admin calendar's
   day detail panel for today) and confirm the driver's pin (the company logo, or a truck icon if
   no logo is set - see `plotDriverMarkers` in `js/delivery.js`) appears on the map alongside
   today's stops.
3. Lock the phone screen (or open Waze/Google Maps and start navigating) and move around -
   confirm the pin keeps updating on the portal.
4. **Restart the phone** (without opening the app manually afterward) and confirm the app
   auto-relaunches and the pin resumes updating on the portal within a minute or two - this is the
   part most likely to need the manufacturer-specific autostart toggle above.
5. Tap "Log Out" on the phone and confirm the pin dims to reflect the stopped state, and that
   restarting the phone again does *not* bring tracking back (since there's no session saved
   anymore).
