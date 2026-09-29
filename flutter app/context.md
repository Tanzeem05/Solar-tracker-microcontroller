# Solar Tracker Flutter App — Build Context

This document is the implementation brief and source of truth for a Flutter Android app that monitors and controls the solar-tracker firmware in [`main.c`](main.c).

It is written so that a developer or coding agent can build the app without having to rediscover the firmware protocol. The first release targets a real Android phone and an HC-05 Bluetooth Classic module. Android Studio is not required.

## 1. Product goal

Build a small, reliable Android dashboard that:

- connects directly to an already-paired HC-05 over Bluetooth Classic RFCOMM/SPP;
- shows live solar voltage, solar current, solar power, and panel temperature;
- switches the tracker between automatic and manual modes;
- moves azimuth left/right and elevation up/down in Manual mode;
- shows connection, permission, sensor-error, and stale-data states clearly;
- includes a compact raw serial log for troubleshooting;
- can be developed and built with Flutter, VS Code, a JDK, and Android SDK command-line tools only.

This is **not a BLE app**. Packages such as `flutter_blue_plus` are for Bluetooth Low Energy and must not be used for the HC-05 SPP connection.

## 2. Supported platform and scope

### Required for version 1

- Android phone with Bluetooth Classic support
- HC-05 paired in Android system Bluetooth settings
- Monitoring of the four values already transmitted by `main.c`
- Auto/Manual selection and four manual direction commands
- Reconnection and meaningful failure messages
- Debug APK and release APK builds from the command line

### Not required for version 1

- iOS support: ordinary HC-05 SPP accessories are not available to normal iOS apps unless they participate in Apple's MFi accessory system
- BLE support
- account/login, cloud database, Internet access, or remote control
- changing HC-05 baud rate or AT-mode configuration from the app
- graphs, persistence, CSV export, notifications, or background operation
- displaying LDR readings, rain state, servo positions, or confirmed firmware mode, because `main.c` does not transmit them

Optional graphs or history can be added later, but should not delay the reliable Bluetooth/control path.

## 3. Complete system

```text
LDRs / rain sensor / INA219 / DS18B20
                  |
                  v
        ATmega32 running main.c
          UART 9600 baud, 8N1
                  |
                  v
           HC-05 Bluetooth SPP
                  |
                  v
        Flutter app on Android phone
```

Bluetooth SPP is a transparent byte stream. The Android side selects the SPP service; it does **not** configure `9600 baud`. The HC-05 UART side must already be configured to match the ATmega32 firmware's 9600-baud UART.

The standard SPP UUID is:

```text
00001101-0000-1000-8000-00805F9B34FB
```

## 4. What `main.c` actually does

### Hardware and sensors

| Function | Firmware hardware |
|---|---|
| Light direction | Four LDRs on ADC0–ADC3 |
| Azimuth motion | Servo on PD4 / OC1B |
| Elevation motion | Servo on PD5 / OC1A |
| Rain detection | Digital rain sensor on PB0, active-low by default |
| Temperature | DS18B20 on PD2 using 1-Wire |
| Solar electrical data | INA219 at I2C address `0x40` on PC0/PC1 |
| Phone link | HC-05 on ATmega32 UART PD0/PD1 at 9600 8N1 |

### Startup

1. The MCU initializes the ADC, both servos, UART, rain input, and INA219.
2. Both servo commands start at `90`.
3. It waits approximately 800 ms for the servos.
4. It takes 64 LDR calibration samples at 10 ms intervals. During this period, the light should be aimed at the **solar panel center** so the firmware learns the panel/LDR alignment bias.
5. It starts in Auto mode and prints:

```text
Solar Tracker Online. INA219 Monitoring Started.
```

The app must not treat the absence of immediate telemetry during startup as a failed Bluetooth connection.

### Auto mode

- Auto mode is the power-on default.
- The four LDR values are averaged into left/right and top/bottom pairs.
- The firmware compares normalized errors against its boot-time calibration.
- Hysteresis prevents twitching: motion starts outside an error magnitude of 60 and stops inside 25.
- Servo steps are adaptive: 1, 2, 3, or 4 command units based on the error.
- In low light (average ADC below 55), tracking holds its current position.
- Both axes may move in the same 40 ms control cycle.
- When rain is detected in Auto mode, automatic light tracking stops and elevation moves gradually to the configured vertical rain-stow command.

### Manual mode

- Automatic LDR tracking is disabled.
- Each received direction byte changes one axis by 15 command units.
- A direction byte is a **one-shot nudge**, not a continuous-motion state.
- To implement press-and-hold, the app must send repeated direction bytes at a controlled rate.
- Manual mode does **not** execute the firmware's rain-protection branch. The UI must warn that manual control overrides automatic rain stow.

### Telemetry schedule

`INA219_REPORT_LOOPS` is `1000 / 40`, so electrical telemetry is emitted roughly once per second. The real interval can be slightly longer because sensor reads and UART writes take time.

The DS18B20 uses a two-phase conversion. On the first report cycle the firmware starts a conversion; temperature normally appears from the next report cycle onward. Therefore, voltage/current/power may appear before temperature after boot or reconnect.

## 5. Phone-to-firmware command protocol

Commands are single ASCII bytes. The firmware accepts uppercase and lowercase, but the app should always send uppercase.

| App action | Byte | Hex | Firmware result |
|---|---:|---:|---|
| Auto | `A` | `0x41` | Select Auto mode; clear both motion-state variables |
| Manual | `M` | `0x4D` | Select Manual mode; clear both motion-state variables |
| Left | `L` | `0x4C` | In Manual only: azimuth `+15` command units |
| Right | `R` | `0x52` | In Manual only: azimuth `-15` command units |
| Up | `U` | `0x55` | In Manual only: elevation `+15` command units |
| Down | `D` | `0x44` | In Manual only: elevation `-15` command units |

Important protocol properties:

- A delimiter is not required. Send exactly one command character for each action.
- `CR`, `LF`, and spaces are ignored, so a library method that appends a newline will still work, but raw one-byte writes are preferred.
- `L/R/U/D` are ignored in Auto mode.
- There is no Stop command because movement is one nudge per direction byte.
- There are no acknowledgements or negative acknowledgements.
- The firmware does not echo commands or report its current mode.
- If several direction bytes arrive before one firmware loop drains the UART buffer, only the last direction byte drained is acted on in that loop. Do not flood the connection.

### Recommended UI command behavior

- After a successful connection, attach the receive listener first, then send `A` once. This establishes a deterministic safe Auto state because the firmware might have remained in Manual after a previous app disconnected.
- Mark the UI mode as Auto after that write succeeds, but understand it is app-inferred, not firmware-confirmed.
- When Manual is tapped, write `M`, then enable the D-pad if the write succeeds.
- A direction-button tap sends one byte.
- A held direction button may repeat every 200–250 ms after a short initial delay. Never repeat faster than the firmware's 40 ms loop; the slower interval also produces controllable 15-unit nudges.
- Stop the repeat timer immediately on pointer-up, pointer-cancel, route change, app pause, disconnect, or disposal.
- Only one direction repeat may be active at a time.
- On disconnect, disable every control immediately and cancel queued/repeating sends.

## 6. Firmware-to-phone telemetry protocol

Text is ASCII, terminated with `\r\n`. A normal report is:

```text
Solar Voltage: 5.120000 V
Solar Current: 34.500 mA
Solar Power: 176.800 mW
------------------------
Temperature: 28.50 C
```

The order currently places the three INA219 lines and separator first. Temperature follows when a prior temperature conversion is ready. The parser should identify each line independently and must not depend on receiving a whole report as one Bluetooth packet.

### Accepted line grammar

Use anchored matching after trimming the completed line:

```text
^Solar Voltage:\s*(-?\d+(?:\.\d+)?)\s+V$
^Solar Current:\s*(-?\d+(?:\.\d+)?)\s+mA$
^Solar Power:\s*(-?\d+(?:\.\d+)?)\s+mW$
^Temperature:\s*(-?\d+(?:\.\d+)?)\s+C$
```

Parse numeric values as `double`, but retain the raw value string for display if preserving the firmware's exact decimal formatting is desired. The current firmware clamps electrical readings to zero or above, while temperature may be negative.

### Other valid firmware lines

```text
Solar Tracker Online. INA219 Monitoring Started.
INA219: Communication Error
Temperature: Sensor Error
------------------------
```

Handling rules:

- Startup line: add it to the terminal; it can also clear a previous sensor-error banner.
- INA219 error: mark voltage/current/power unavailable or errored without crashing or disconnecting Bluetooth.
- Temperature error: mark only temperature unavailable or errored.
- Separator: retain it in the terminal if useful, otherwise ignore it.
- Unknown/malformed line: show it in the raw log and ignore it for card values.
- Never convert an error or malformed value to numeric zero. Zero is a valid sensor reading.

### Stream framing is mandatory

RFCOMM delivers arbitrary byte chunks. One read may contain half a line, several lines, or the end of one line plus the beginning of another. Packet-safe parsing must:

1. subscribe once to the connection's byte stream;
2. append/decode chunks continuously;
3. split only on newline boundaries;
4. strip a trailing carriage return;
5. retain an incomplete final line until more bytes arrive;
6. clear the partial-line buffer on disconnect before a new connection.

The recommended package provides `connection.input.lines()`, which already performs this framing. If that API is not used, implement and unit-test an equivalent accumulator. Do not call `utf8.decode()` independently on arbitrary chunks unless malformed/incomplete sequences are handled; ASCII is sufficient for the current protocol.

### Freshness

Store a timestamp per measurement and display a stale state if a value has not been updated for about 3 seconds while connected. On disconnect, keep or clear the last values according to the chosen UX, but visually label them stale/disconnected so old data is never mistaken for live data.

## 7. Required screens and user experience

A single responsive dashboard is enough.

### Connection section

- Bluetooth/connection status: unsupported, adapter off, permission needed, disconnected, connecting, connected, or reconnecting
- `Connect HC-05` / `Disconnect` action
- list of bonded devices, with devices whose names contain `HC-05` sorted first
- show both device name and MAC address because many modules use the same name
- friendly prompts for adapter off, permission denied, not paired, out of range, busy/already connected, timeout, and unsupported SPP service

Prefer a paired-device workflow for version 1:

1. The user pairs HC-05 in Android Settings using PIN `1234` or, for some modules, `0000`.
2. The app requests only the permission needed to connect/list paired devices.
3. The app shows bonded devices and connects by MAC address.

This avoids discovery complexity and older-Android location requirements. A `Bluetooth Settings` shortcut is helpful when no HC-05 is paired.

### Live data section

Four cards:

- Solar voltage in V
- Solar current in mA
- Solar power in mW
- Temperature in °C (the wire text uses `C`; the UI can render `°C`)

Each card should support: waiting, live, stale, and sensor error. Do not invent precision that is not received.

### Control section

- segmented Auto / Manual mode control
- large, touch-friendly Up, Down, Left, Right D-pad
- D-pad disabled while disconnected or while app mode is Auto
- visible Manual-mode warning: **Manual mode disables firmware rain protection**
- optional short haptic feedback per tap, but not required

Since the firmware gives no acknowledgement, avoid wording such as “confirmed by tracker.” Use “Auto requested” / “Manual requested” in diagnostics if exactness matters.

### Serial monitor

- last 100–300 completed lines in a bounded list/ring buffer
- timestamp optional
- Clear action
- auto-scroll only when the user is already near the bottom
- never let the log grow without a bound

## 8. Flutter architecture

Keep the first version simple and testable. A suggested layout is:

```text
lib/
  main.dart
  app.dart
  models/
    telemetry.dart
    connection_status.dart
    tracker_mode.dart
  services/
    bluetooth_serial_service.dart
    telemetry_parser.dart
  controllers/
    tracker_controller.dart
  screens/
    dashboard_screen.dart
  widgets/
    connection_panel.dart
    telemetry_card.dart
    mode_selector.dart
    direction_pad.dart
    serial_log.dart
test/
  telemetry_parser_test.dart
  tracker_controller_test.dart
```

Responsibilities:

- `BluetoothSerialService`: permissions, paired devices, connect/disconnect, raw input lines, raw output bytes, and connection errors. No UI code.
- `TelemetryParser`: pure Dart line-to-event parsing. No Bluetooth or widget dependencies.
- `TrackerController`: owns app state, stream subscriptions, command serialization, timers, freshness, bounded log, and lifecycle cleanup.
- Widgets/screens: render controller state and forward user intent only.

For this small app, `ChangeNotifier`, `ValueNotifier`, or plain `StreamBuilder` is sufficient. A large state-management dependency is not necessary unless the project already standardizes on one.

### Suggested model

```text
TelemetrySnapshot
  voltageVolts: double?
  currentMilliamps: double?
  powerMilliwatts: double?
  temperatureCelsius: double?
  voltageUpdatedAt/currentUpdatedAt/powerUpdatedAt/temperatureUpdatedAt
  ina219Error: String?
  temperatureError: String?

TrackerController state
  connectionStatus
  connectedDeviceName/address
  selectedMode (app-inferred)
  telemetrySnapshot
  boundedRawLines
  lastError
```

Dispose/cancel every stream subscription, periodic freshness timer, hold-repeat timer, and connection object. Guard asynchronous completions with `mounted` in widgets or keep them in the controller so a disposed widget is never updated.

## 9. Bluetooth package choice

Recommended as of 2026-09-28:

```powershell
flutter pub add flutter_classic_bluetooth
```

At the time this context was prepared, `flutter_classic_bluetooth` 1.5.0 supports Android Bluetooth Classic RFCOMM/SPP, paired-device listing, permission checks, typed connection failures, streamed input/output, and newline reassembly with `input.lines()`. Version 1.5.0 requires Flutter 3.44 or newer; on an older compatible Flutter SDK, dependency resolution may select an older package version. Commit `pubspec.lock` for reproducible app builds.

Relevant API shape to verify against the resolved package version:

```dart
final bluetooth = FlutterClassicBluetooth();
final paired = await bluetooth.getPairedDevices();
final connection = await bluetooth.connect(address: address);

final lineSub = connection.input.lines().listen(handleLine);
await connection.output.writeString('A');

await lineSub.cancel();
await connection.close();
connection.dispose();
```

The default connection UUID is SPP. Do not introduce a BLE package alongside it.

The package is relatively new, so keep it isolated behind `BluetoothSerialService`. If it becomes unsuitable, only that adapter should need replacement. An Android-only alternative can be evaluated, but old `flutter_bluetooth_serial` 0.4-era examples should not be copied blindly because modern Android/Gradle/plugin compatibility has caused build issues.

## 10. Android permissions

For an app that connects only to devices already paired in Android Settings:

- Android 12 / API 31 and later requires `BLUETOOTH_CONNECT` at manifest and runtime levels.
- Bluetooth discovery would additionally require `BLUETOOTH_SCAN` and is intentionally out of scope for version 1.
- On Android 11 and lower, legacy `BLUETOOTH` and `BLUETOOTH_ADMIN` declarations may be supplied with `maxSdkVersion="30"`.
- Location permission should not be requested merely to list/connect to already-paired devices.

The recommended plugin supplies Bluetooth declarations through manifest merging and can request permissions for the operation. Still inspect the final merged manifest/build behavior rather than assuming permission success. Request permission in context when the user taps Connect, explain denial, and provide a route to App Settings after permanent denial.

Do not add `INTERNET`; direct RFCOMM does not need it.

## 11. Development setup without Android Studio

Android Studio is optional. Disk use is kept down by testing on a physical phone instead of installing an Android emulator and system images.

### Install

1. Install Git for Windows.
2. Install VS Code plus the **Flutter** extension; it also installs the Dart extension.
3. Install the current stable Flutter SDK. VS Code can do this through `Flutter: New Project` → `Download SDK`, or download/extract Flutter manually to a writable path such as `C:\dev\flutter`. Do not place it under `Program Files`.
4. Install a 64-bit JDK 17 distribution. Android Gradle Plugin 8.x requires Java 17. Configure Flutter explicitly if necessary:

   ```powershell
   flutter config --jdk-dir "C:\Path\To\jdk-17"
   ```

5. Download the Android SDK **Command-line Tools for Windows** without installing Android Studio. Arrange the extracted files exactly like:

   ```text
   C:\Android\sdk\cmdline-tools\latest\bin\sdkmanager.bat
   C:\Android\sdk\cmdline-tools\latest\lib\...
   ```

6. Use `sdkmanager.bat --list` and install:

   - `platform-tools`
   - the Android SDK platform matching the generated Flutter project's `compileSdk`
   - the corresponding/current Android SDK build-tools
   - `cmdline-tools;latest` if an update is offered

   Example only—replace the API/build-tools version with the current stable version required by `flutter doctor` and the generated project:

   ```powershell
   & "C:\Android\sdk\cmdline-tools\latest\bin\sdkmanager.bat" `
     "platform-tools" `
     "platforms;android-35" `
     "build-tools;35.0.0"
   ```

7. Set `ANDROID_SDK_ROOT` to `C:\Android\sdk`, add Flutter `bin` and Android `platform-tools` to `PATH`, and tell Flutter where the SDK is:

   ```powershell
   flutter config --android-sdk "C:\Android\sdk"
   flutter doctor --android-licenses
   flutter doctor -v
   ```

The Android Studio line in `flutter doctor` may remain absent; that is acceptable if the Android toolchain itself is green and command-line builds work.

### Use a physical phone

1. Enable Developer options and USB debugging on the Android phone.
2. Connect the phone by USB and accept the RSA/debugging prompt.
3. Verify it appears:

   ```powershell
   flutter devices
   adb devices
   ```

4. Pair HC-05 in the phone's normal Bluetooth settings.
5. Run on the phone:

   ```powershell
   flutter run
   ```

An emulator is not useful for validating the HC-05 radio path. The final Bluetooth testing must use a real Android device.

## 12. Project creation and build commands

From the desired parent directory:

```powershell
flutter create --platforms=android --org com.example solar_tracker_app
Set-Location solar_tracker_app
flutter pub add flutter_classic_bluetooth
flutter analyze
flutter test
flutter run
```

Replace `com.example` with the final organization/application ID before release.

Build an installable debug APK:

```powershell
flutter build apk --debug
```

Build smaller release APKs per CPU architecture:

```powershell
flutter build apk --split-per-abi
```

For direct sharing during the project demonstration, a single larger APK is simpler:

```powershell
flutter build apk
```

Typical output is under:

```text
build/app/outputs/flutter-apk/
```

Use `flutter install` to install to a connected phone. A release intended for distribution must use a securely stored signing key; do not commit the keystore, passwords, `key.properties`, or secrets.

## 13. Connection lifecycle

Implement this sequence explicitly:

1. User taps Connect.
2. Check Bluetooth Classic support.
3. Request/check connect permission.
4. If the adapter is off, ask the user to enable it; do not loop prompts.
5. Load bonded devices and show a chooser.
6. Connect to the chosen MAC address with a visible timeout.
7. Subscribe to input and connection-state streams.
8. Send `A` and initialize the app-inferred mode to Auto.
9. Parse and render lines until disconnect.
10. On remote close/error, cancel repeat timers, disable controls, mark data stale, clear partial parser state, close/dispose resources, and show a retry action.

Only one connection attempt may run at a time. Disable duplicate Connect actions while connecting. If automatic reconnect is added, it must be cancellable and visible; it must not create parallel sockets or continue after the user taps Disconnect.

Persisting the last chosen MAC address locally is acceptable. Do not silently connect to a different device just because its name is `HC-05`.

## 14. Error and troubleshooting messages

Map technical failures to actionable UI text:

| Condition | User-facing guidance |
|---|---|
| No paired devices | Pair HC-05 in Android Bluetooth Settings first (`1234` or `0000`) |
| Permission denied | Allow Nearby devices/Bluetooth connection permission in App Settings |
| Bluetooth off | Turn Bluetooth on, then retry |
| Timeout/unreachable | Power the tracker, move closer, and check that HC-05 is not connected to another phone |
| Busy | Disconnect any other phone/PC from HC-05, then retry |
| Connected, no data | Check HC-05 TX → ATmega PD0/RXD, common ground, UART 9600, and flashed firmware |
| Data works, controls do not | Select Manual before using the D-pad |
| Reversed movement | Fix the firmware axis direction/calibration; do not relabel the app buttons to conceal wiring/mechanical direction problems |
| INA219 error line | Check INA219 power, address, SDA/SCL, and common ground |
| Temperature error line | Check DS18B20 wiring, pull-up, power, and common ground |

## 15. Testing requirements

### Pure Dart unit tests

Test at least:

- all four valid numeric telemetry lines;
- negative temperature;
- exact decimal strings and leading zero values;
- INA219 and temperature error lines;
- startup and separator lines;
- malformed and unknown input;
- one line split across multiple chunks;
- several lines in one chunk;
- `\r\n` and `\n` termination;
- an incomplete buffered line cleared on disconnect;
- bounded raw-log eviction;
- stale-value timing;
- direction controls rejected while Auto/disconnected;
- hold-repeat cancellation on release and disconnect.

### Widget tests

- waiting/live/stale/error card states;
- D-pad enable/disable rules;
- Manual rain-safety warning;
- connecting state prevents a second connection attempt;
- denied permission and no-paired-device guidance.

### Real-hardware acceptance test

1. Fresh launch with permission not yet granted.
2. HC-05 unpaired, then paired through Settings.
3. Successful connection and initial Auto command.
4. Voltage/current/power refresh roughly every second.
5. Temperature begins after its conversion delay.
6. Manual mode plus one tap in each direction.
7. Press-and-hold movement stops immediately on release.
8. Return to Auto and verify LDR tracking.
9. Power-cycle the tracker during a connection and verify clean disconnect/recovery.
10. Turn phone Bluetooth off/on and reconnect.
11. Cause/disconnect a sensor if safe and verify error-line handling.
12. Leave the dashboard open for at least 15 minutes and verify no duplicate listeners, runaway log, or repeat timer.

## 16. Important firmware findings and constraints

These are present in the current `main.c` and should be known before blaming the app:

1. `AZ_REVERSED` is defined twice, first as `0` and immediately again as `1`. The later definition is effectively used, normally with a compiler redefinition warning. Remove one definition in firmware and keep the intended value.
2. Servo command limits are `2..220`, but `command_to_pulse()` maps using a divisor of 180. Therefore command `220` produces a pulse above the stated 1000–2000 µs window. Confirm the mechanical/electrical safe range and make the comment, limits, and mapping agree before extended operation.
3. Manual mode bypasses rain protection entirely.
4. No rain status, LDR values, servo command/angle, mode state, or acknowledgements are transmitted.
5. The app cannot confirm whether a command was applied; it can only confirm that the socket write completed.
6. Telemetry has human-readable labels rather than a versioned machine protocol. Parsing must be tolerant, and future firmware label/unit changes must be coordinated with the app.
7. The INA219 calculation assumes the standard `0.1 Ω` shunt and clamps negative solar current to zero.
8. The DS18B20 implementation assumes only one sensor on the 1-Wire bus (`Skip ROM`).

Do not silently add UI values that the current protocol cannot provide.

## 17. Recommended future firmware protocol improvements

These are optional firmware changes, not version-1 app requirements. If firmware can be updated later, prefer a versioned, one-line message such as:

```text
TEL,v=1,voltage_v=5.120000,current_ma=34.500,power_mw=176.800,temp_c=28.50,rain=0,mode=A,az=90,el=90
ACK,cmd=M,mode=M
ERR,sensor=INA219,code=COMM
```

Useful additions would be:

- a protocol version;
- one complete telemetry frame per sample;
- rain state, mode, azimuth command, elevation command, and optionally averaged LDR values;
- `ACK` for mode/movement commands;
- a query/status command;
- a defined Stop command if motion later becomes continuous;
- explicit behavior stating whether rain safety overrides Manual mode.

Any protocol revision should retain newline framing and ideally preserve the old human-readable output temporarily or introduce a clear version handshake.

## 18. Definition of done

Version 1 is complete when:

- a clean checkout can be built from VS Code/PowerShell without Android Studio;
- `flutter analyze` and `flutter test` pass;
- the app installs and launches on a physical Android phone;
- it lists paired devices and connects to HC-05 over Classic SPP;
- fragmented serial input cannot corrupt telemetry values;
- all four live readings and both sensor-error forms render correctly;
- Auto, Manual, and all four one-byte movement commands work;
- hold-repeat is rate-limited and always cancels safely;
- Manual mode visibly warns about disabled rain protection;
- disconnect/reconnect does not leave duplicate subscriptions or timers;
- the raw serial log stays bounded;
- an APK can be produced from the command line.

## 19. References checked for this context

- Firmware source: [`main.c`](main.c)
- Flutter install with VS Code: <https://docs.flutter.dev/install/with-vs-code>
- Flutter Android setup and physical-device validation: <https://docs.flutter.dev/platform-integration/android/setup>
- Flutter Android APK/release builds: <https://docs.flutter.dev/deployment/android>
- Android SDK command-line manager: <https://developer.android.com/tools/sdkmanager>
- Android Bluetooth permissions: <https://developer.android.com/develop/connectivity/bluetooth/bt-permissions>
- Android/Gradle JDK requirements: <https://developer.android.com/build/jdks>
- Recommended Bluetooth Classic package: <https://pub.dev/packages/flutter_classic_bluetooth>

