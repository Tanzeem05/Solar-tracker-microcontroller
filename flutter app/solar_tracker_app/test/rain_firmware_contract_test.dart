import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/telemetry_parser.dart';

void main() {
  test('actual firmware rain messages parse across every Bluetooth split', () {
    final firmware = File(
      'firmware/main_with_rain_telemetry.c',
    ).readAsStringSync();
    final emitted = RegExp(
      r'uart_send_string\("(Rain:[^"\r\n]+)\\r\\n"\);',
    ).allMatches(firmware).map((match) => match.group(1)!).toSet();
    final expected = {
      'Rain: Dry': RainCondition.dry,
      'Rain: Detected': RainCondition.raining,
      'Rain: Detected; Tracking stopped': RainCondition.protecting,
    };
    expect(emitted, expected.keys.toSet());
    final parser = TelemetryParser();
    final bytes = ascii.encode('${emitted.join('\r\n')}\r\n');
    for (var split = 0; split <= bytes.length; split++) {
      final framer = SerialLineFramer();
      final lines = [
        ...framer.add(bytes.sublist(0, split)),
        ...framer.add(bytes.sublist(split)),
      ];
      expect(lines.length, 3);
      for (final line in lines) {
        final event = parser.parse(line);
        expect(event.kind, TelemetryKind.rain);
        expect(event.rain, expected[line]);
      }
    }
  });
}
