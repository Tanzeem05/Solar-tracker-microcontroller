import '../models/tracker_state.dart';

enum TelemetryKind {
  reading,
  electricalError,
  loadError,
  temperatureError,
  heatWarning,
  rain,
  startup,
  separator,
  unknown,
}

class TelemetryEvent {
  const TelemetryEvent(
    this.kind, {
    this.metric,
    this.value,
    this.raw,
    this.rain,
  });
  final TelemetryKind kind;
  final Metric? metric;
  final double? value;
  final String? raw;
  final RainCondition? rain;
}

class TelemetryParser {
  static final _patterns = <Metric, RegExp>{
    Metric.voltage: RegExp(r'^Solar Voltage:\s*(-?\d+(?:\.\d+)?)\s+V$'),
    Metric.current: RegExp(r'^Solar Current:\s*(-?\d+(?:\.\d+)?)\s+mA$'),
    Metric.power: RegExp(r'^Solar Power:\s*(-?\d+(?:\.\d+)?)\s+mW$'),
    Metric.loadVoltage: RegExp(r'^Battery Voltage:\s*(-?\d+(?:\.\d+)?)\s+V$'),
    Metric.loadCurrent: RegExp(r'^Battery Current:\s*(-?\d+(?:\.\d+)?)\s+mA$'),
    Metric.loadPower: RegExp(r'^Battery Power:\s*(-?\d+(?:\.\d+)?)\s+mW$'),
    Metric.temperature: RegExp(r'^Temperature:\s*(-?\d+(?:\.\d+)?)\s+C$'),
  };

  TelemetryEvent parse(String input) {
    final line = input.trim();
    for (final entry in _patterns.entries) {
      final match = entry.value.firstMatch(line);
      if (match != null) {
        final raw = match.group(1)!;
        final value = double.tryParse(raw);
        if (value != null && value.isFinite) {
          return TelemetryEvent(
            TelemetryKind.reading,
            metric: entry.key,
            value: value,
            raw: raw,
          );
        }
      }
    }
    final rain = switch (line) {
      'Rain: Dry' => RainCondition.dry,
      'Rain: Detected' => RainCondition.raining,
      'Rain: Detected; Tracking stopped' => RainCondition.protecting,
      _ => null,
    };
    if (rain != null) return TelemetryEvent(TelemetryKind.rain, rain: rain);
    return TelemetryEvent(switch (line) {
      'INA219: Communication Error' ||
      'INA219 #1: Communication Error' => TelemetryKind.electricalError,
      'INA219 #2: Communication Error' => TelemetryKind.loadError,
      'Temperature: Sensor Error' => TelemetryKind.temperatureError,
      'Excessive heat detected' => TelemetryKind.heatWarning,
      'Solar Tracker Online. INA219 Monitoring Started.' ||
      'Solar Tracker Online. Dual INA219 Monitoring Started.' =>
        TelemetryKind.startup,
      '------------------------' => TelemetryKind.separator,
      _ => TelemetryKind.unknown,
    });
  }
}

/// One instance per socket. Overlong lines are discarded through the next LF.
class SerialLineFramer {
  static const maxLength = 1024;
  final List<int> _pending = [];
  bool _discarding = false;
  List<String> add(List<int> bytes) {
    final lines = <String>[];
    for (final byte in bytes) {
      if (byte == 10) {
        if (!_discarding) {
          if (_pending.isNotEmpty && _pending.last == 13) _pending.removeLast();
          lines.add(String.fromCharCodes(_pending));
        } else {
          lines.add('[Discarded serial line longer than 1024 bytes]');
        }
        reset();
      } else if (!_discarding) {
        if (_pending.length == maxLength) {
          _pending.clear();
          _discarding = true;
        } else {
          _pending.add(byte < 128 ? byte : 0xfffd);
        }
      }
    }
    return lines;
  }

  void reset() {
    _pending.clear();
    _discarding = false;
  }
}
