import 'package:flutter_test/flutter_test.dart';
import 'package:solar_tracker_app/controllers/tracker_controller.dart';
import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/alert_service.dart';
import 'package:solar_tracker_app/services/telemetry_parser.dart';

import 'fakes.dart';

class FakeAlerts implements AlertService {
  bool allowed = true;
  bool fail = false;
  final posted = <({int id, String title, String body})>[];
  @override
  Future<bool> enabled() async => allowed;
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (fail) throw StateError('notification unavailable');
    if (allowed) posted.add((id: id, title: title, body: body));
    return allowed;
  }
}

void main() {
  test(
    'new firmware labels, error identities, startup and heat parse exactly',
    () {
      final parser = TelemetryParser();
      for (final (line, metric, value) in [
        ('Battery Voltage: 12.004000 V', Metric.loadVoltage, '12.004000'),
        ('Battery Current: 0.100 mA', Metric.loadCurrent, '0.100'),
        ('Battery Power: 1.200 mW', Metric.loadPower, '1.200'),
      ]) {
        final event = parser.parse(line);
        expect(event.metric, metric);
        expect(event.raw, value);
      }
      expect(
        parser.parse('INA219 #1: Communication Error').kind,
        TelemetryKind.electricalError,
      );
      expect(
        parser.parse('INA219 #2: Communication Error').kind,
        TelemetryKind.loadError,
      );
      expect(
        parser
            .parse('Solar Tracker Online. Dual INA219 Monitoring Started.')
            .kind,
        TelemetryKind.startup,
      );
      expect(
        parser.parse('Excessive heat detected').kind,
        TelemetryKind.heatWarning,
      );
      expect(
        parser.parse('Battery Voltage: 12 mV').kind,
        TelemetryKind.unknown,
      );
      expect(parser.parse('Rain: maybe').kind, TelemetryKind.unknown);
    },
  );

  late FakeBluetooth bluetooth;
  late FakeAlerts alerts;
  late TrackerController controller;
  late FakeConnection socket;
  late DateTime time;
  setUp(() async {
    bluetooth = FakeBluetooth();
    alerts = FakeAlerts();
    time = DateTime(2026);
    controller = TrackerController(
      bluetooth,
      alerts: alerts,
      clock: () => time,
    );
    await controller.connect(bluetooth.devices.single);
    socket = bluetooth.connections.single;
  });
  tearDown(() => controller.dispose());

  test('fragmented dual readings and errors never cross sensor groups', () {
    socket.receive('Solar Voltage: 5.100000 V\r\nBattery Vol');
    socket.receive('tage: 12.200000 V\nTemperature: 25.00 C\n');
    expect(controller.readings[Metric.voltage]!.raw, '5.100000');
    expect(controller.readings[Metric.loadVoltage]!.raw, '12.200000');
    socket.receive('INA219 #2: Communication Error\n');
    expect(controller.readings[Metric.voltage]!.error, isNull);
    expect(controller.readings[Metric.loadCurrent]!.error, isNotNull);
    expect(controller.readings[Metric.temperature]!.value, 25);
    socket.receive('Battery Power: 5.000 mW\nINA219 #1: Communication Error\n');
    expect(controller.readings[Metric.loadPower]!.raw, '5.000');
    expect(controller.readings[Metric.power]!.error, isNotNull);
  });

  test(
    'strictly above 40 alerts once per hot episode including text warning',
    () {
      socket.receive('Temperature: 40.00 C\n');
      expect(alerts.posted, isEmpty);
      socket.receive(
        'Temperature: 40.06 C\nExcessive heat detected\nTemperature: 42.00 C\nExcessive heat detected\n',
      );
      expect(alerts.posted.length, 1);
      socket.receive('Temperature: Sensor Error\nTemperature: 43.00 C\n');
      expect(alerts.posted.length, 1);
      socket.receive('Temperature: 40.00 C\nTemperature: 41.00 C\n');
      expect(alerts.posted.length, 2);
    },
  );

  test(
    'rain unknown until report, alerts once per wet episode and goes stale',
    () async {
      socket.receive('Solar Voltage: 0.000000 V\nBattery Power: 0.000 mW\n');
      expect(controller.rain.condition, isNull);
      expect(alerts.posted, isEmpty);
      socket.receive(
        'Rain: Detected; Tracking stopped\nRain: Detected; Tracking stopped\n',
      );
      expect(alerts.posted.length, 1);
      expect(alerts.posted.single.body, contains('tracking has stopped'));
      expect(controller.rain.isFresh(time, true), isTrue);
      time = time.add(const Duration(seconds: 3));
      expect(controller.rain.isFresh(time, true), isFalse);
      socket.receive('Rain: Dry\nRain: Detected\n');
      expect(alerts.posted.length, 2);
      expect(alerts.posted.last.body, contains('stop is not confirmed'));
      await controller.disconnect();
      expect(controller.rain.isFresh(time, controller.isConnected), isFalse);
    },
  );

  test(
    'denial and notification failure do not break telemetry or Bluetooth',
    () async {
      alerts.allowed = false;
      await controller.enableNotifications();
      expect(controller.notificationsEnabled, isFalse);
      expect(controller.notificationMessage, contains('App Settings'));
      socket.receive('Temperature: 41.00 C\n');
      await Future<void>.delayed(Duration.zero);
      expect(alerts.posted, isEmpty);
      alerts.allowed = true;
      await controller.enableNotifications();
      expect(alerts.posted.length, 1);
      alerts.fail = true;
      socket.receive('Temperature: 39.00 C\nTemperature: 42.00 C\n');
      await Future<void>.delayed(Duration.zero);
      expect(controller.notificationMessage, contains('failed'));
      expect(controller.isConnected, isTrue);
      expect(controller.readings[Metric.temperature]!.value, 42);
    },
  );

  test('reboot and reconnect clear rain and alert episode state', () async {
    socket.receive('Rain: Detected; Tracking stopped\nTemperature: 45.00 C\n');
    socket.receive('Solar Tracker Online. Dual INA219 Monitoring Started.\n');
    expect(controller.rain.condition, isNull);
    expect(controller.readings.values.every((m) => m.value == null), isTrue);
    socket.receive('Temperature: 45.00 C\n');
    expect(alerts.posted.length, 3);
    await controller.disconnect();
    await controller.retry();
    expect(controller.rain.condition, isNull);
    bluetooth.connections.last.receive('Temperature: 45.00 C\n');
    expect(alerts.posted.length, 4);
  });

  test(
    'periodic rain heartbeat stays live without repeating notifications and recovers on reconnect',
    () async {
      for (var i = 0; i < 15; i++) {
        time = time.add(const Duration(seconds: 1));
        socket.receive('Rain: Detected; Tracking stopped\r\n');
        expect(controller.rain.isFresh(time, true), isTrue);
        expect(controller.missingRainTelemetry, isFalse);
      }
      expect(alerts.posted.length, 1);
      await controller.disconnect();
      await controller.retry();
      expect(controller.rain.condition, isNull);
      bluetooth.connections.last.receive(
        'Rain: Detected; Tracking stopped\r\n',
      );
      expect(controller.rain.condition, RainCondition.protecting);
      expect(alerts.posted.length, 2);
    },
  );
}
