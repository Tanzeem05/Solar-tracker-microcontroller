# Build and verification record — 1.1.1+3

## Update

Dual INA219 readings (Solar and Battery/Load), independent sensor errors,
temperature High/Normal status, deduplicated local heat/rain notifications,
and compact Overview / Controls / Monitor navigation are implemented.
Alerts operate while the app is open and connected; existing background
disconnect behavior is retained.

The workspace root `main.c` now contains the supplied dual-INA219 firmware
with rain reports at startup (after calibration), rain/mode changes, and
approximately one-second intervals. `firmware/main_with_rain_telemetry.c`
is an identical copy. The previous root source is preserved as
`firmware/backup/main_before_rain_update.c`. The app shows Waiting while
awaiting rain, then firmware guidance after ten seconds without a report.
A stopped-tracking notification requires an explicit Auto protection report;
Manual rain never falsely claims the panel stopped. Flashing the updated
firmware is required; installing the APK alone cannot add device telemetry.

## Toolchain

- Flutter 3.47.5 stable, revision `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`.
- Dart 3.13.4.
- Eclipse Temurin JDK 17.0.20.1+1, selected explicitly for Flutter.
- Gradle wrapper 9.3.1 (binary distribution), Android Gradle Plugin 9.1.0.
- Android minimum API 24; compile and target API 36.
- VS Code Flutter/Dart extensions 3.142.0.
- Android platform 36 revision 2, build-tools 36.0.0, platform-tools 37.0.1.
- Android NDK 28.2.13676358 (r28c), required by the generated project.
- `flutter_classic_bluetooth` 1.5.0, with the documented local Android fixes.
- AVR GCC 7.3.0-atmel3.6.1-arduino7, downloaded from Arduino's official
  distribution and SHA-256 checked against its package index.

## Verified

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub --reporter expanded`: all 38 tests passed.
- Initial setup validation, `flutter doctor -v`: Flutter and Android toolchain passed with the updated
  PATH. All Android licenses accepted. The only remaining diagnostic is the
  absent Visual Studio Windows desktop toolchain, which this Android app does
  not require. No Android device was attached.
- Tests cover framing, parsing, precision, error isolation, freshness, bounded
  logging, command ordering, hold timing/cancellation, late connection cleanup,
  background timeout, device selection, permission guidance, and large text.
- New coverage includes dual-sensor error isolation, fragmented Battery lines,
  strict >40°C threshold, alert deduplication/rearming, notification denial and
  failure, rain unknown/fresh/stale states, reboot/reconnect state reset, and
  Overview content fitting a 390×844 phone without scrolling to see rain.
- Rain update coverage checks the actual C output strings across every chunk
  split, recurring heartbeat freshness without notification spam, reconnect
  recovery, and Waiting / missing-firmware / wet / stale / dry UI states.

## Firmware build

- `../build-firmware.ps1` compiled root `main.c` for ATmega32 without warnings
  using `-std=gnu99 -Os -Wall -Wextra` and section garbage collection.
- Source clock: `F_CPU=1000000UL`. Existing sensor wiring, UART 9600, servo
  calibration, and Auto/Manual protection behavior are preserved.
- Flash: 5,408 bytes (16.5%); static RAM: 356 bytes (17.4%).
- Outputs: `../firmware-build/main.elf` and `../firmware-build/main.hex`.
- Source SHA-256 (both copies):
  `E75B8F310A54F0397799C595024839CB4D68C960A9FD4B75189F8F8D8DE3C418`.
- HEX SHA-256:
  `85816BAE1FAB3E2A903A10F073075353820CA8BF087CE786DF28ADFE07C53AFB`.
- Compilation passed; hardware flashing, fuse changes, and physical tests
  were not performed.

## APK builds

- ARM64 debug build passed using `flutter build apk --debug --no-pub
  --target-platform android-arm64`.
- Debug packaged metadata: app ID `com.solartracker.solar_tracker_app`, version
  `1.1.1+3`, min API 24, target API 36, label Solar Tracker, ABI `arm64-v8a`.
- Debug APK signature verified with `apksigner verify --verbose --print-certs`:
  APK Signature Scheme v2, Android Debug certificate.
- ARM64 release build passed using `flutter build apk --release --no-pub
  --target-platform android-arm64`.
- Release packaged metadata matches debug; ABI `arm64-v8a`; release is not
  debuggable. Its APK Signature Scheme v2 signature verifies with the same
  Android Debug certificate (demonstration signing only).
- `aapt dump permissions` confirms release has BLUETOOTH and BLUETOOTH_ADMIN
  capped at API 30, BLUETOOTH_CONNECT, POST_NOTIFICATIONS, and AndroidX's app-specific signature
  permission `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. It has no INTERNET,
  BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE, or location permission.
- Native Android compilation passed with all documented Bluetooth patches,
  including worker-thread writes and socket/channel cleanup.

Both APKs are in `build/app/outputs/flutter-apk/`:

| File | Bytes | SHA-256 |
|---|---:|---|
| `app-debug.apk` | 77,228,086 | `943AD8F780D7B81C33FF5D674CC6D55B3220F5D564C5556F66BE88D8FA8F95D1` |
| `app-release.apk` | 16,176,986 | `AFF018F10190CCC581CCDB243615920C693577820FA2DF1183CE57F758680EA7` |

Signing certificate SHA-256:
`386c8f83a5fdabbbc0ea019e0b46ff9fbef945dc8b411f236bf8d0996a27e887`.

## Universal release blocker

During the initial 1.0 build, the universal build was attempted and failed because Windows Application
Control blocked the official Flutter ARM32 release compiler:

`D:\Development\flutter\bin\cache\artifacts\engine\android-arm-release\windows-x64\gen_snapshot.exe`

The ARM64 and x86-64 AOT compiler outputs were generated in that attempt, but
ARM32 failed, so no universal APK was produced. No Windows security settings
were changed. The policy owner must review/approve the blocked compiler before
retrying `flutter build apk --release` or `./build-apks.ps1 -UniversalRelease`.
ARM64 APKs are the current fallback deliverables; they require an ARM64 Android
device. The universal deliverable remains outstanding.

The current Android CLI also returned exit code 1 after extracting SDK packages
without an error message. Flutter doctor and the successful debug build verify
that platform 36, build-tools 36.0.0, and NDK 28.2 are usable. The build emitted
an SDK XML metadata-version warning, which did not prevent debug compilation.

## Hardware acceptance

Pending by agreement: no phone or tracker was available during development.
Follow the acceptance checklist in README.md. Automated tests do not establish
that the HC-05 radio path, sensors, or physical movement work on the hardware.
