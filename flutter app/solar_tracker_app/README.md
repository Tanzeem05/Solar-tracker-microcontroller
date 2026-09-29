# Solar Tracker

An offline Android dashboard for an ATmega32 solar tracker connected through an
already-paired HC-05 Bluetooth Classic SPP module. Version 1.1 supports the
latest supplied dual-INA219 firmware and remains compatible with the original
solar-only protocol in `../context.md`.

## Version 1.1: dual sensors and alerts

- **Overview:** compact Solar input and Load / battery modules, each with live
  voltage, current and power; temperature with Normal/High status; rain status.
- **Controls:** Auto/Manual and the D-pad. Changing tabs cancels held movement.
- **Monitor:** bounded serial log, kept out of the Overview to reduce scrolling.
- Load measurements map exactly to the firmware's `Battery Voltage/Current/Power`
  lines. `INA219 #1` and `INA219 #2` errors affect only the corresponding sensor.
- Tap **Enable alerts** and allow notifications. A temperature strictly above
  40°C triggers a phone notification once per hot episode. Returning to 40°C or
  below rearms it. Repeated `Excessive heat detected` lines do not spam alerts.
- Notifications require the app to remain open and connected. The existing
  background/screen-lock Auto attempt and disconnect behavior is retained.
  Previously posted notifications remain in the notification shade.
- Notifications use Android's local notification channel and runtime permission;
  no Internet service or extra package is used. If disabled, the dashboard still
  shows the sensor status and provides App Settings guidance. Android may suppress
  sound or banners according to notification-channel and Do Not Disturb settings.

**Rain needs a firmware update.** The supplied flashed code reads the rain pin
for Auto protection but never sends rain status over Bluetooth. Therefore this
APK shows **Unknown / Not reported by firmware** with that code; it cannot infer
rain or confirm that tracking stopped from voltage/current/power.
The root [`../main.c`](../main.c) is now updated from the supplied dual-sensor
firmware and includes rain reports at startup, on changes, and periodically.
The compiled ATmega32 / 1 MHz HEX is [`../firmware-build/main.hex`](../firmware-build/main.hex).
An identical source copy is in `firmware/main_with_rain_telemetry.c`; the previous
workspace source is backed up in `firmware/backup/main_before_rain_update.c`.
See [the firmware notes](firmware/README.md) before flashing it.
With those reports, the app shows Dry/Raining and notifies once per wet episode.
It says tracking stopped only for the explicit Auto rain-protection report;
Manual rain reports warn that a stop is not confirmed. Rain readings become
stale after three seconds. Firmware compilation passed; flashing and hardware
testing remain pending. The app now shows Waiting until its first report and
specific firmware-update guidance after ten seconds without any rain report.

The app version is `1.1.1+3`, signed with the same local demonstration key, so it
can update the previous installation on an ARM64 Android phone.

## Development setup

Install Flutter stable 3.44 or newer (Dart 3.12+), JDK 17, Android command-line
tools, platform-tools, Android platform 36, build-tools 36.0.0, and NDK
28.2.13676358 (required by the generated Flutter 3.47.5 build).
Android Studio and an emulator are not required. Use VS Code's Flutter
extension, which includes Dart support.

This workspace's setup scripts target `D:\Development\flutter`,
`D:\Development\jdk-17`, and `D:\Development\android-sdk`.
Restart VS Code and terminals after changing the user PATH.

```powershell
flutter config --jdk-dir D:\Development\jdk-17 --android-sdk D:\Development\android-sdk
flutter doctor --android-licenses
flutter doctor -v
cd solar_tracker_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

The installed 2026 Android command-line tools use the new Android CLI. To add
SDK packages directly, run:

```powershell
D:\Development\android-sdk\cmdline-tools\latest\bin\android.exe --no-metrics --sdk=D:\Development\android-sdk sdk install platform-tools platforms/android-36 build-tools/36.0.0 ndk/28.2.13676358
```

`--no-metrics` disables optional CLI telemetry. It also avoids a Windows
Application Control failure in the bundled runtime's metrics component on this
machine; no Windows security policy needs changing. Installing the NDK directly
also avoids the legacy `sdkmanager.bat` wrapper splitting its package ID during
Gradle's automatic installation. Older tools still support
`sdkmanager` with semicolon-separated package names.

`pubspec.lock` records resolved dependencies. The Android app uses the generated
Gradle wrapper; do not install a separate global Gradle distribution.
The plugin requires Windows Developer Mode if Flutter reports that plugin
symlink creation is unavailable; enable it in Windows Settings if prompted.

## Connect a phone and tracker

1. Enable Developer options and USB debugging on the Android phone (Android 7+).
2. Connect a data-capable USB cable and accept the phone's debugging prompt.
3. Verify with `adb devices` and `flutter devices`; install the manufacturer's
   USB driver if the phone is not detected.
4. Pair HC-05 in Android Bluetooth Settings, using PIN `1234` or `0000`.
5. Run `flutter run`, or install the APK with `adb install -r <apk-path>`.
6. Tap **Connect HC-05**, allow Nearby devices, and choose its MAC address.

The app lists bonded devices; it does not scan or pair devices itself. It uses
SPP UUID `00001101-0000-1000-8000-00805F9B34FB`. HC-05's UART must already match
the firmware's 9600 baud. The phone cannot configure that UART baud rate.

## Behavior

- Every connection attaches input/state listeners before sending exactly `A`.
  The app shows Auto after the write succeeds. There are no firmware ACKs.
- Solar and load voltage (V), current (mA), power (mW), and temperature (°C) preserve received
  decimal text. Temperature can appear later because of sensor conversion.
- Each reading becomes stale after three seconds without an update. Disconnect
  preserves values with disconnected labels; a new socket starts with empty
  readings so old-session values cannot appear live.
- A sensor error affects only that sensor group. Malformed lines stay in the
  log and do not replace measurements with zero.
- Manual sends `M`; directions send `U/D/L/R` as single bytes. A held button
  sends immediately, repeats after 400 ms, then every 250 ms. Pending writes
  suppress repeats rather than queueing motion.
- Release, pointer cancellation, mode changes, navigation, app inactivity, and
  disconnect cancel hold timers. Only one direction can be held at a time.
- On backgrounding or screen lock, controls disable immediately. The app gives
  a pending write and a best-effort `A` a shared 500 ms deadline, then closes.
  A failed write, lost radio link, or process kill can leave firmware in Manual;
  the app cannot confirm Auto was applied. Reconnect requests Auto again.
- Connection attempts have a native 15-second timeout. Retry is manual and
  targets the previous MAC address. A cancelled attempt must settle before a
  second attempt can begin. The selected MAC is not saved across app restarts.
- A firmware startup banner resets readings and the app-inferred mode to Auto.
- The serial monitor keeps 200 completed lines/diagnostic entries in memory.
  It follows new entries only when already near the bottom. Incomplete lines
  are bounded to 1024 bytes and cleared between connections.

## Architecture and dependency patch

`BluetoothGateway` and `SerialConnection` isolate platform I/O. The production
adapter uses `flutter_classic_bluetooth` 1.5.0; tests use an in-memory fake.
`SerialLineFramer` reconstructs ASCII lines; `TelemetryParser` recognizes the
firmware grammar. `TrackerController` owns state, timers, command gating,
freshness, and cleanup. Flutter widgets only render state and forward intent.

The package is vendored under `vendor/flutter_classic_bluetooth` with its MIT
license. A local dependency override fixes Android CONNECT-only compatibility,
native connect timeout cleanup, and closed-connection state snapshots. See
`vendor/flutter_classic_bluetooth/PATCHES.md` before upgrading it.

The release manifest retains CONNECT, legacy Bluetooth, and POST_NOTIFICATIONS permissions, removes
SCAN/ADVERTISE/location permissions, and does not include INTERNET. Debug/profile
builds may use INTERNET for Flutter's development service.

## APKs and signing

Build outputs are placed in `build/app/outputs/flutter-apk/`:

- `app-debug.apk`: ARM64 development build for ARM64 phones. Omit
  `--target-platform android-arm64` to build debug for all supported CPUs.
- `app-release.apk`: ARM64 release-mode build, signed with the local Android
  debug key for demonstration only. It is not configured for store publication.

The planned universal release build is blocked on this machine because Windows
Application Control denies Flutter's ARM32 `gen_snapshot.exe`. No Windows
security settings were changed. See BUILD_REPORT.md for the exact executable.
After the policy owner approves the required official compiler, run
`flutter build apk --release` (or `./build-apks.ps1 -UniversalRelease`) to produce
the universal ARM32/ARM64/x86-64 APK. The default script builds ARM64 APKs.

For smaller individual APKs, use `flutter build apk --release --split-per-abi`.
Before distribution, configure a private production signing key, change the
application ID if required, and keep keystores/passwords out of source control.

## Troubleshooting

| Symptom | Check |
|---|---|
| No paired device | Pair HC-05 in Android Settings; no app discovery is performed |
| Permission denied | App Settings → Nearby devices; enable permission and retry |
| Timeout/busy | Tracker power, distance, and whether another phone owns HC-05 |
| Connected but no readings | HC-05 TX → PD0/RXD, common ground, UART 9600, flashed firmware |
| Readings work but movement does not | Select Manual; check RX path and firmware |
| INA219 error | Sensor power, I²C address 0x40, SDA/SCL, and ground |
| Temperature error | DS18B20 data pin, pull-up resistor, power, and ground |
| Reversed movement | Correct firmware/mechanical direction; labels follow the protocol |

## Acceptance on real hardware — pending

Automated tests cannot validate the radio, sensors, or servo mechanics. When
hardware is available, record Android version, phone model, and each result:

- Fresh permission grant, denial, permanent denial, and recovery from Settings.
- Unpaired device guidance, pairing, connection, and initial Auto request.
- All seven readings, delayed temperature, independent INA219 #1/#2 errors, and stale indications.
- Grant/deny notification permission; verify one heat alert above 40°C, no alert
  at exactly 40°C, and rearming after cooling. Verify repeated heat lines do not spam.
- With rain-reporting firmware: dry/wet transitions, Auto rain-stow notification,
  Manual rain warning, stale rain state, and reconnect behavior.
- Each Manual direction, tap versus hold, release/cancel, and return to Auto.
- Screen lock/background behavior, Bluetooth off/on, and tracker power cycle.
- Repeated disconnect/retry without extra subscriptions or delayed movement.
- A 15-minute run without growing logs, stuck timers, or resource accumulation.
- Android 12+ must connect with Nearby devices/CONNECT only; test an older
  Android device as well when available.

Manual mode bypasses firmware rain protection. The latest supplied firmware has
a single `AZ_REVERSED` definition. Verify its retained 2–220 command range against
the servo pulse mapping before extended physical movement. Production signing
and flashing hardware are outside this app build.

Android notification API reference:
[Create a notification](https://developer.android.com/develop/ui/compose/notifications/create-notification).
