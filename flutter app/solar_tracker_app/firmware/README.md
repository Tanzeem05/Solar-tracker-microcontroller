# Rain reporting firmware

The canonical source is [../../main.c](../../main.c) in the workspace root.
It now uses the latest supplied **dual-INA219** firmware with rain telemetry.
The old single-sensor workspace source is preserved at
`backup/main_before_rain_update.c`.
`main_with_rain_telemetry.c` is an identical convenience copy.

## What to install

1. Flash `../../firmware-build/main.hex` to your **ATmega32 running at 1 MHz**
   using your existing programmer workflow, or compile the updated root main.c
   in your existing AVR project and flash that output.
2. Install the new Solar Tracker 1.1.1 APK on your ARM64 Android phone.
3. Pair/connect HC-05 and enable phone notifications in the app.
4. Open Monitor. A dry sensor should produce `Rain: Dry` periodically.
   Wet the sensor for a controlled test: Auto should report
   `Rain: Detected; Tracking stopped`. Dry it again to rearm the alert.

Installing the APK alone cannot change the firmware already burned into the MCU.
No hardware was flashed and no fuses were changed during this build.
The HEX was compiled with AVR GCC 7.3.0 for ATmega32, with the source's
`F_CPU=1000000UL`. Compilation passed without warnings: 5,408 bytes program,
356 bytes static RAM. Actual wiring, sensor polarity and servo motion still
need hardware verification.

## Protocol and behavior

Rain status is sent on the first control iteration after startup calibration,
whenever rain or Auto/Manual mode changes, and in each approximately one-second
sensor report. The periodic heartbeat lets a phone connect after boot or after
a rain transition and still learn the current state. Rain messages precede
the slower electrical/temperature report. All lines end in CRLF.

| UART line | Meaning |
|---|---|
| `Rain: Dry` | Rain input is dry |
| `Rain: Detected` | Wet input in Manual; rain protection is bypassed |
| `Rain: Detected; Tracking stopped` | Wet input in Auto; light tracking stops and rain stow runs |

Rain stow can still move the elevation servo. “Tracking stopped” means light
tracking is suspended, not that all servo motion is complete. Notifications
occur once per wet episode while the app is open and connected.
Missing/stale reports never become a false Dry reading.

Rain sensor D0 remains on **PB0, physical pin 1**, active-low
(`RAIN_ACTIVE_LOW=1`). Both INA219 sensors, temperature reporting, UART 9600,
Auto/Manual behavior, direction commands and servo calibration are retained.
The existing 2..220 command range and /180 pulse mapping are unchanged.

## Rebuild on this computer

From the workspace root:

```powershell
.\setup-avr.ps1
.\build-firmware.ps1
```

The setup script downloads a portable official Arduino AVR toolchain and checks
its SHA-256 against the official package index. The build script only compiles
and creates `firmware-build/main.elf` and `firmware-build/main.hex`; it never
flashes a device or changes fuses. If using another AVR GCC installation, pass
`-CompilerDirectory <path-to-avr-bin>` to the build script.
