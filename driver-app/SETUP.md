# Driver App Setup

Android app that RS Pet Stop delivery drivers install on their phone. There is no "Start
Tracking" button - tracking begins automatically the moment the app opens with a saved login
(a normal open or a resume), and it runs in a standalone native Android service
(`DriverTrackingService.java`) that's independent of the app's WebView/JS - it keeps sending GPS
pings straight to Supabase even while backgrounded (Waze open, screen locked), after the phone
restarts (`BootReceiver.java` starts the service directly, no UI needed), and even if the driver
swipes the app away from the recent-apps switcher. The only way to turn it off is "Log Out" in the
app. See [supabase_driver_locations_table.sql](../sql/supabase_driver_locations_table.sql) and the
driver pin plotted on the portal's Delivery page (`docs/delivery.html`).

**Why a custom native service instead of a plugin**: this app originally used
`@capacitor-community/background-geolocation`, but that plugin deliberately stops tracking the
instant the app is swiped away (its own GitHub issue #59 explains why - a location callback firing
after the app process is torn down can crash Google Play Services, so the plugin's fix is to
self-terminate on unbind rather than risk it). `DriverTrackingService` avoids that whole problem
by never binding to the Activity in the first place and owning its own location callback thread
and HTTP reporting, completely independent of the WebView being alive.

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

`capacitor.config.json`'s `plugins.CapacitorHttp.enabled: true` setting is no longer load-bearing
for tracking itself (`DriverTrackingService` makes its own native HTTP calls, bypassing the
WebView entirely) but is still harmless to leave in place - `verify_login`/`driver_stop_tracking`
still legitimately run through the WebView while it's confirmed to be open and foregrounded.

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
Studio. `cap sync` does **not** touch hand-written native files (`DriverTrackingService.java`,
`DriverTrackingPlugin.java`, `BootReceiver.java`, `MainActivity.java`) or manual
`AndroidManifest.xml`/`build.gradle`/`variables.gradle` edits - those are safe to keep across syncs.

## 3. Android permissions - hand-declared in AndroidManifest.xml

Unlike before (when `@capacitor-community/background-geolocation` and `@capacitor/local-notifications`
bundled their own manifests that Gradle merged in automatically), permissions are now explicitly
declared in `android/app/src/main/AndroidManifest.xml` since those plugins were removed:
`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`. If you ever add a plugin back or change this
service's permission needs, this file needs a matching manual edit now - nothing auto-merges them
in anymore.

`ACCESS_BACKGROUND_LOCATION` is still deliberately absent. `DriverTrackingService` runs as a
foreground service with a visible notification (`foregroundServiceType="location"`), and Android
grants a foreground service the same location access as an app in active use, without needing that
separate (and more sensitive/scrutinized) permission. Practically, this means the driver will only
see "While using the app" as a location option, not "Allow all the time" - that's expected, and is
sufficient as long as the "tracking active" notification stays visible.

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
- **Enable "autostart" for the app.** `BootReceiver.java` starts `DriverTrackingService` directly
  after the phone restarts, but most phone brands sold in the Philippines block third-party apps
  from auto-starting after boot by default, regardless of any code-level fix - this is a
  manufacturer restriction, not a bug in this app, and it's a separate concern from swipe-away
  survival (which `DriverTrackingService`'s design handles on its own - see below). The driver
  needs to manually whitelist the app once, in whichever menu their phone brand uses:
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
4. **Swipe the app away from Recents entirely** (this is the main point of the native rewrite) and
   confirm the pin *keeps updating* on the portal for several minutes with the app fully closed,
   not just backgrounded. If this doesn't hold on a particular phone, it's almost certainly the
   OEM autostart/battery whitelist step above not being enabled on that device - test on more than
   one phone brand if possible, since aggressive OEMs (Xiaomi/MIUI especially) can still kill the
   whole app process on swipe-away despite everything above, in which case only the boot-restart
   or a manual reopen recovers it.
5. **Restart the phone** (without opening the app manually afterward) and confirm the pin resumes
   updating on the portal within a minute or two - same OEM caveat as step 4 applies here too.
6. Tap "Log Out" on the phone and confirm the pin dims to reflect the stopped state, and that
   restarting the phone again does *not* bring tracking back (since there's no session saved
   anymore).
