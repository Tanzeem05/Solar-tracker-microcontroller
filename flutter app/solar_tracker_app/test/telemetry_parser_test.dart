import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/telemetry_parser.dart';

void main() {
  final parser = TelemetryParser();
  test('parses four readings and preserves received decimal strings', () {
    final cases = {
      'Solar Voltage: 05.120000 V': (Metric.voltage, 5.12, '05.120000'),
      'Solar Current: 0.000 mA': (Metric.current, 0.0, '0.000'),
      'Solar Power: 176.800 mW': (Metric.power, 176.8, '176.800'),
      'Temperature: -12.50 C': (Metric.temperature, -12.5, '-12.50'),
    };
    for (final entry in cases.entries) {
      final event = parser.parse('  ${entry.key}  ');
      expect(event.kind, TelemetryKind.reading);
      expect((event.metric, event.value, event.raw), entry.value);
    }
  });
  test('recognizes errors, startup, and separator without inventing zeros', () {
    final cases = {
      'INA219: Communication Error': TelemetryKind.electricalError,
      'Temperature: Sensor Error': TelemetryKind.temperatureError,
      'Solar Tracker Online. INA219 Monitoring Started.': TelemetryKind.startup,
      '------------------------': TelemetryKind.separator,
    };
    for (final entry in cases.entries) {
      final event = parser.parse(entry.key);
      expect(event.kind, entry.value);
      expect(event.value, isNull);
    }
  });
  test('rejects malformed input and wrong units', () {
    for (final line in [
      'noise',
      '',
      'Temperature: NaN C',
      'Temperature: +2 C',
      'Solar Voltage: 5 mV',
      'Solar Power: 1e3 mW',
      'prefix Solar Current: 1 mA',
      'Temperature: 2 C extra',
      'Solar Voltage: ${'9' * 400} V',
    ]) {
      expect(parser.parse(line).kind, TelemetryKind.unknown, reason: line);
    }
  });
  test('reassembles every possible split of CRLF reports', () {
    const report =
        'Solar Voltage: 5.120000 V\r\nSolar Current: 0.000 mA\nTemperature: -1.25 C\r\n';
    final bytes = ascii.encode(report);
    for (var split = 0; split <= bytes.length; split++) {
      final framer = SerialLineFramer();
      expect(
        [
          ...framer.add(bytes.sublist(0, split)),
          ...framer.add(bytes.sublist(split)),
        ],
        [
          'Solar Voltage: 5.120000 V',
          'Solar Current: 0.000 mA',
          'Temperature: -1.25 C',
        ],
      );
    }
  });
  test('disconnect clears partial line and overflow resynchronizes', () {
    final framer = SerialLineFramer();
    expect(framer.add(ascii.encode('Solar Vol')), isEmpty);
    framer.reset();
    expect(framer.add(ascii.encode('Temperature: 2 C\n')), [
      'Temperature: 2 C',
    ]);
    expect(framer.add(List.filled(4096, 65)), isEmpty);
    expect(framer.add(ascii.encode('\nSolar Power: 0 mW\n')), [
      '[Discarded serial line longer than 1024 bytes]',
      'Solar Power: 0 mW',
    ]);
  });
  test('measurement freshness is per timestamp at three seconds', () {
    final time = DateTime(2026);
    final reading = Measurement(value: 0, raw: '0', updatedAt: time);
    expect(
      reading.status(time.add(const Duration(milliseconds: 2999)), true),
      ReadingStatus.live,
    );
    expect(
      reading.status(time.add(const Duration(seconds: 3)), true),
      ReadingStatus.stale,
    );
    expect(reading.status(time, false), ReadingStatus.stale);
    expect(const Measurement().status(time, true), ReadingStatus.waiting);
    expect(
      const Measurement(error: 'sensor').status(time, true),
      ReadingStatus.error,
    );
  });
}
