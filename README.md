# Dual-Axis Solar Tracker

This project combines ATmega32 firmware with a Flutter Android app to build a
two-axis solar tracker. The controller follows the strongest light source,
protects the panel when rain is detected, measures energy flow and panel
temperature, and communicates with a phone through an HC-05 Bluetooth module.

```text
LDRs + rain + temperature + electrical sensors
                       |
                       v
              ATmega32 running main.c
          servos <---- | ----> UART at 9600 baud
                       |                |
                       v                v
                 solar panel       HC-05 / SPP
                                        |
                                        v
                              Flutter Android app
```

## Project contents

| Path | Purpose |
|---|---|
| [`main.c`](main.c) | ATmega32 firmware and hardware pin definitions |
| [`firmware-build/main.hex`](firmware-build/main.hex) | Compiled firmware image |
| [`build-firmware.ps1`](build-firmware.ps1) | Firmware build script |
| [`solar_tracker_app/`](solar_tracker_app/) | Flutter Android application |
| [`solar_tracker_app/README.md`](solar_tracker_app/README.md) | Detailed app setup, build and test notes |

## ATmega32 firmware features

The firmware targets a raw ATmega32 running at **1 MHz**.

### Automatic dual-axis tracking

- Four LDRs on ADC0-ADC3 measure light at the bottom-left, bottom-right,
  top-left and top-right of the sensor head.
- Each ADC result is averaged over 16 samples. The four results are combined
  into left/right and top/bottom values for azimuth and elevation control.
- Errors are normalized, so tracking responds to the proportional light
  imbalance instead of only the raw ADC difference.
- At startup, the servos move to their center commands and the firmware takes
  64 calibration samples. This learns the offset between the LDR head and the
  panel's best physical alignment.
- Hysteresis starts motion when the normalized error reaches 60 and stops it
  inside 25. This reduces servo chatter around the target.
- Adaptive steps move quickly when the error is large and gently near the
  target. Both axes can be corrected in the same 40 ms control cycle.
- Tracking pauses in low light instead of hunting randomly.
- Software limits constrain both servo commands, and movement slows near the
  configured ends of travel.

Timer1 produces two 50 Hz PWM outputs: OC1B drives azimuth and OC1A drives
elevation.

### Rain protection

The active-low rain module is read on PB0. In Auto mode, a wet reading suspends
light tracking and gradually moves the elevation axis to the configured
vertical stow position. The optional azimuth-centering behavior is present but
disabled by default.

Rain state is transmitted at startup, whenever the rain or operating mode
changes, and about once per second:

```text
Rain: Dry
Rain: Detected
Rain: Detected; Tracking stopped
```

Manual mode intentionally bypasses automatic rain protection. A wet reading in
Manual therefore reports rain but does not claim that tracking has stopped.

### Electrical monitoring

Two INA219 modules independently monitor:

- solar-panel input voltage, current and calculated power; and
- battery/load voltage, current and calculated power.

Both modules use the default I²C address `0x40`. To avoid an address collision,
the solar sensor uses the ATmega32 hardware TWI peripheral on PC0/PC1, while the
battery/load sensor uses a software I²C implementation on PC2/PC3. Each bus has
timeouts and reports its own communication error, so one failed sensor does not
hide the state of the other.

The code assumes each INA219 board has a 0.1 ohm shunt. Negative current is
clamped to zero, so the telemetry represents forward energy flow rather than
bidirectional current.

### Temperature monitoring

A waterproof DS18B20 is connected to PD2 through a 1-Wire bus with an external
10 kOhm pull-up. Conversion and reading are split across report cycles so the
sensor's conversion delay does not block the tracking loop for 750 ms. The
firmware reports temperature to two decimal places and sends
`Excessive heat detected` above 40 degrees Celsius.

### Bluetooth control and telemetry

The HC-05 uses the hardware UART at **9600 baud, 8 data bits, no parity and one
stop bit (8N1)**. Phone commands are single ASCII characters:

| Command | Result |
|---|---|
| `A` | Select automatic tracking |
| `M` | Select manual control |
| `L` / `R` | Nudge azimuth left/right in Manual |
| `U` / `D` | Nudge elevation up/down in Manual |

Direction commands are one-shot 15-unit movements, not continuous motor states.
The firmware accepts upper- or lowercase commands and ignores whitespace. It
does not send command acknowledgements or report a confirmed current mode.

Approximately once per second it sends solar and battery/load voltage, current
and power, temperature, rain state, sensor errors, and a separator over the
same UART connection.

## Hardware connections

| Device/function | ATmega32 connection | Physical pin |
|---|---|---:|
| LDR bottom-left | PA0 / ADC0 | 40 |
| LDR bottom-right | PA1 / ADC1 | 39 |
| LDR top-left | PA2 / ADC2 | 38 |
| LDR top-right | PA3 / ADC3 | 37 |
| Rain sensor D0 | PB0 | 1 |
| HC-05 TX -> MCU RX | PD0 / RXD | 14 |
| HC-05 RX <- MCU TX | PD1 / TXD | 15 |
| DS18B20 data | PD2 | 16 |
| Azimuth servo | PD4 / OC1B | 18 |
| Elevation servo | PD5 / OC1A | 19 |
| Solar INA219 SCL/SDA | PC0 / PC1 | 22 / 23 |
| Load INA219 SCL/SDA | PC2 / PC3 | 24 / 25 |

The ATmega32, sensors, HC-05 and servo supply must share a common ground. The
servos must be powered from a suitable regulated supply, not from MCU I/O pins.
The firmware is compiled for a 1 MHz CPU clock, so the chip clock/fuse setup
must match for UART, PWM, 1-Wire and software-I²C timing to be correct.

## Flutter app

The app is an offline Android dashboard for the tracker. It uses Bluetooth
Classic Serial Port Profile (SPP), not Bluetooth Low Energy. The HC-05 must
already be paired in Android settings; the app lists paired devices but does
not scan for or pair new devices.

The app provides:

- an Overview showing live solar input, battery/load output, temperature and
  rain status;
- separate waiting, live, stale, disconnected and sensor-error states, so old
  data is not mistaken for a current reading;
- Auto/Manual mode selection and a direction pad with tap-to-nudge and
  controlled press-and-hold repetition;
- a bounded raw serial monitor for diagnostics;
- clear Bluetooth permission, adapter, timeout and connection error messages;
- local phone alerts for temperature above 40 degrees Celsius and for rain;
- deduplication so repeated heat or rain reports do not spam notifications;
- automatic cancellation of held controls during mode changes, navigation,
  disconnects and app lifecycle changes.

Receive listeners are attached before the app sends `A` after connecting. This
requests a known safe Auto state, but the UI describes it as a request because
the firmware has no acknowledgement protocol. When the app is backgrounded, it
makes a best-effort request for Auto and then disconnects. Alerts only work
while the app remains open and connected.

The parser handles fragmented Bluetooth byte streams, preserves the firmware's
display precision, rejects malformed readings without turning them into zero,
and isolates failures from the two INA219s and the temperature sensor. Readings
become stale after three seconds without an update. The serial log retains at
most 200 completed entries.

## Main implementation difficulties

### Two sensors with the same I2C address

Both INA219 boards are fixed at `0x40` in this build. They cannot coexist on one
bus without changing an address, so the project implements a second, bit-banged
I2C master. PC2 and PC3 are JTAG pins on the ATmega32, which also means JTAG has
to be disabled correctly before those pins can be used as GPIO.

### Timing several protocols on a 1 MHz MCU

The controller simultaneously maintains 50 Hz servo PWM, ADC sampling, a
40 ms tracking loop, UART traffic, hardware and software I2C, and timing-sensitive
1-Wire communication. The implementation uses peripheral PWM, short timeouts,
and a two-phase temperature conversion to keep the tracker responsive. Sensor
reporting and UART output still add some time, so the one-second telemetry rate
is approximate.

### Stable mechanical tracking

Raw LDR equality does not necessarily mean that the panel itself is optimally
aimed. Startup bias calibration, normalized errors, hysteresis, adaptive steps,
low-light holding and edge slowdown work together to reduce offsets, oscillation
and mechanical stress. Final direction, travel limits and stow position remain
specific to the physical frame and must be calibrated on the real hardware.

### An unconfirmed serial control protocol

The UART protocol has no acknowledgement, checksum, sequence number or explicit
mode telemetry. A successful Bluetooth write proves only that Android handed
off the byte; it does not prove that the MCU acted on it. The app therefore
treats its mode as inferred, avoids flooding direction commands, and warns when
Auto restoration cannot be guaranteed.

### Safety and validation limits

- Manual mode bypasses rain stow, so it must be used with care in wet weather.
- The configured servo command limits are `2..220`, while
  `command_to_pulse()` scales values using a `/180` formula. A command of 220
  produces about 2222 microseconds even though the documented nominal window is
  1000-2000 microseconds. Verify each servo and linkage, then reduce the limits
  if necessary before extended operation.
- The DS18B20 driver reads the temperature bytes but does not validate the
  scratchpad CRC, so wiring noise may not always be distinguishable from a
  valid measurement.
- Electrical calculations assume a 0.1 ohm INA219 shunt and discard negative
  current. Different modules or bidirectional measurements need recalibration.
- Firmware compilation and automated Flutter tests have passed, but they do
  not verify sensor polarity, servo direction, mechanical binding, radio range,
  phone permissions or real electrical accuracy. Hardware acceptance is still
  required.

## Build and run

### Firmware

On Windows PowerShell, from this directory:

```powershell
.\setup-avr.ps1
.\build-firmware.ps1
```

The build produces `firmware-build/main.elf` and
`firmware-build/main.hex`. It does not flash the ATmega32 or change its fuses.
Use a suitable AVR programmer to flash the HEX file and ensure the MCU actually
runs at 1 MHz.

### Flutter app

With Flutter, JDK 17 and the Android SDK configured:

```bash
cd solar_tracker_app
flutter pub get
flutter analyze
flutter test
flutter run
```

On the phone, pair the HC-05 in Android Bluetooth settings first (the common
default PIN is `1234` or `0000`). Open the app, grant Nearby devices permission,
select the paired HC-05, and connect. See the
[app README](solar_tracker_app/README.md) for APK builds, exact tool versions,
troubleshooting and the hardware acceptance checklist.
