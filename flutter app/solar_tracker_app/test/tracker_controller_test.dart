import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solar_tracker_app/controllers/tracker_controller.dart';
import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/bluetooth_gateway.dart';

import 'fakes.dart';

void main() {
  const device = PairedDevice('HC-05', '00:11:22:33:44:55');
  void scenario(
    void Function(FakeAsync, FakeBluetooth, TrackerController) body,
  ) {
    fakeAsync((time) {
      final bluetooth = FakeBluetooth();
      final start = DateTime(2026);
      final controller = TrackerController(
        bluetooth,
        clock: () => start.add(time.elapsed),
      );
      try {
        body(time, bluetooth, controller);
      } finally {
        controller.dispose();
        time.elapse(Duration.zero);
      }
    });
  }

  test(
    'listeners precede initial A; only Manual accepts exact nudge bytes',
    () => scenario((time, bluetooth, controller) {
      controller.nudge(Direction.left);
      controller.connect(device);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      expect(connection.order.take(3), [
        'listen-input',
        'listen-state',
        'write-A',
      ]);
      expect(controller.selectedMode, TrackerMode.auto);
      controller.nudge(Direction.left);
      time.elapse(Duration.zero);
      expect(connection.writes, ['A']);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      for (final direction in Direction.values) {
        controller.nudge(direction);
        time.elapse(Duration.zero);
      }
      controller.selectMode(TrackerMode.auto);
      time.elapse(Duration.zero);
      expect(connection.writes, ['A', 'M', 'U', 'D', 'L', 'R', 'A']);
    }),
  );
  test(
    'duplicate connect is rejected and late socket is closed',
    () => scenario((time, bluetooth, controller) {
      final gate = Completer<SerialConnection>();
      bluetooth.connectGate = gate;
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.connect(device);
      expect(bluetooth.addresses, [device.address]);
      controller.disconnect();
      time.elapse(Duration.zero);
      final lateSocket = FakeConnection();
      gate.complete(lateSocket);
      time.elapse(Duration.zero);
      expect(lateSocket.closed, isTrue);
      expect(lateSocket.writes, isEmpty);
      expect(controller.isConnected, isFalse);
    }),
  );
  test(
    'initial write failure never enables controls',
    () => scenario((time, bluetooth, controller) {
      bluetooth.nextConnection = FakeConnection()
        ..writeError = StateError('failed');
      controller.connect(device);
      time.elapse(Duration.zero);
      expect(controller.isConnected, isFalse);
      expect(controller.canMove, isFalse);
      expect(bluetooth.connections.single.closed, isTrue);
    }),
  );
  test(
    'holding repeats at 400ms then 250ms and release cancels',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      controller.startHold(Direction.up);
      time.elapse(Duration.zero);
      time.elapse(const Duration(milliseconds: 399));
      expect(connection.writes, ['A', 'M', 'U']);
      time.elapse(const Duration(milliseconds: 1));
      time.elapse(const Duration(milliseconds: 250));
      expect(connection.writes, ['A', 'M', 'U', 'U', 'U']);
      controller.stopHold();
      time.elapse(const Duration(seconds: 2));
      expect(connection.writes.length, 5);
    }),
  );
  test(
    'slow write skips repeats and release leaves no queued directions',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      connection.writeGate = Completer<void>();
      controller.startHold(Direction.right);
      time.elapse(Duration.zero);
      time.elapse(const Duration(milliseconds: 900));
      controller.stopHold();
      connection.writeGate!.complete();
      time.elapse(Duration.zero);
      time.elapse(const Duration(seconds: 1));
      expect(connection.writes, ['A', 'M', 'R']);
    }),
  );
  test(
    'remote disconnect cancels held command and retry resets framing',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final first = bluetooth.connections.single;
      first.receive('Solar Voltage: 5.0 V\nSolar Cur');
      controller.startHold(Direction.down);
      time.elapse(Duration.zero);
      first.states.add(false);
      time.elapse(Duration.zero);
      time.elapse(const Duration(seconds: 2));
      expect(first.writes, ['A', 'M', 'D']);
      expect(
        controller.readings[Metric.voltage]!.status(
          controller.now,
          controller.isConnected,
        ),
        ReadingStatus.stale,
      );
      controller.retry();
      time.elapse(Duration.zero);
      final second = bluetooth.connections.last;
      second.receive('Temperature: 28.50 C\n');
      expect(second.writes, ['A']);
      expect(controller.readings[Metric.temperature]!.raw, '28.50');
      expect(controller.readings[Metric.current]!.value, isNull);
    }),
  );
  test(
    'background requests Auto after pending write then closes',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      controller.startHold(Direction.left);
      time.elapse(Duration.zero);
      controller.enterBackground();
      time.elapse(Duration.zero);
      expect(controller.canMove, isFalse);
      expect(connection.writes, ['A', 'M', 'L', 'A']);
      expect(connection.closed, isTrue);
      time.elapse(const Duration(seconds: 2));
      expect(connection.writes.length, 4);
    }),
  );
  test(
    'background deadline does not send delayed Auto after closing',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      final gate = Completer<void>();
      connection.writeGate = gate;
      controller.nudge(Direction.up);
      time.elapse(Duration.zero);
      controller.enterBackground();
      time.elapse(Duration.zero);
      time.elapse(const Duration(milliseconds: 500));
      expect(connection.closed, isTrue);
      gate.complete();
      time.elapse(Duration.zero);
      expect(connection.writes, ['A', 'M', 'U']);
      expect(controller.message, contains('may remain in Manual'));
    }),
  );
  test(
    'telemetry errors are isolated, zero is real, and logs stay bounded',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      connection.receive(
        'Solar Voltage: 0.000000 V\nTemperature: -5.00 C\nINA219: Communication Error\n',
      );
      expect(controller.readings[Metric.voltage]!.error, isNotNull);
      expect(controller.readings[Metric.temperature]!.raw, '-5.00');
      connection.receive(
        'Solar Voltage: 0.000000 V\nTemperature: Sensor Error\n',
      );
      expect(controller.readings[Metric.voltage]!.value, 0);
      expect(controller.readings[Metric.voltage]!.error, isNull);
      expect(controller.readings[Metric.temperature]!.error, isNotNull);
      for (var i = 0; i < 300; i++) {
        connection.receive('line $i\n');
      }
      expect(controller.log.length, 200);
      expect(controller.log.first.text, 'line 100');
      controller.clearLog();
      expect(controller.log, isEmpty);
    }),
  );
  test(
    'boot banner cancels manual hold and clears old sensor errors',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      controller.startHold(Direction.up);
      time.elapse(Duration.zero);
      connection.receive(
        'Temperature: Sensor Error\nSolar Tracker Online. INA219 Monitoring Started.\n',
      );
      time.elapse(const Duration(seconds: 1));
      expect(controller.selectedMode, TrackerMode.auto);
      expect(controller.readings[Metric.temperature]!.error, isNull);
      expect(connection.writes, ['A', 'M', 'U']);
    }),
  );
  test(
    'permission and empty-pairing guidance; HC-05 sorts first',
    () => scenario((time, bluetooth, controller) {
      bluetooth.prepareError = const BluetoothFailure(
        'Allow Nearby devices',
        ConnectionStatus.permissionNeeded,
      );
      controller.discoverPairedDevices();
      time.elapse(Duration.zero);
      expect(controller.status, ConnectionStatus.permissionNeeded);
      bluetooth.prepareError = null;
      bluetooth.devices = [];
      controller.discoverPairedDevices();
      time.elapse(Duration.zero);
      expect(controller.message, contains('Pair HC-05'));
      bluetooth.devices = [const PairedDevice('AAA', '1'), device];
      List<PairedDevice>? found;
      controller.discoverPairedDevices().then((value) => found = value);
      time.elapse(Duration.zero);
      expect(found!.first.name, 'HC-05');
    }),
  );
  test(
    'freshness is per measurement and no-data guidance waits ten seconds',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      time.elapse(const Duration(seconds: 9));
      expect(controller.noTelemetry, isFalse);
      time.elapse(const Duration(seconds: 1));
      expect(controller.noTelemetry, isTrue);
      final connection = bluetooth.connections.single;
      connection.receive('Solar Voltage: 5 V\n');
      expect(controller.noTelemetry, isFalse);
      time.elapse(const Duration(seconds: 3));
      connection.receive('Temperature: 28 C\n');
      expect(
        controller.readings[Metric.voltage]!.status(controller.now, true),
        ReadingStatus.stale,
      );
      expect(
        controller.readings[Metric.temperature]!.status(controller.now, true),
        ReadingStatus.live,
      );
    }),
  );
  test(
    'adapter off and write failure close connection',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      bluetooth.adapter.add(false);
      time.elapse(Duration.zero);
      expect(controller.status, ConnectionStatus.adapterOff);
      controller.retry();
      time.elapse(Duration.zero);
      bluetooth.connections.last.writeError = StateError('broken');
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      expect(controller.isConnected, isFalse);
      expect(controller.message, contains('write failed'));
    }),
  );
  test(
    'only the newest held direction repeats; mode change cancels it',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      controller.startHold(Direction.left);
      time.elapse(Duration.zero);
      time.elapse(const Duration(milliseconds: 200));
      controller.startHold(Direction.right);
      time.elapse(Duration.zero);
      time.elapse(const Duration(milliseconds: 400));
      controller.selectMode(TrackerMode.auto);
      time.elapse(Duration.zero);
      time.elapse(const Duration(seconds: 1));
      expect(connection.writes, ['A', 'M', 'L', 'R', 'R', 'A']);
    }),
  );
  test(
    'firmware reboot wins over an obsolete pending Manual write',
    () => scenario((time, bluetooth, controller) {
      controller.connect(device);
      time.elapse(Duration.zero);
      final connection = bluetooth.connections.single;
      final gate = Completer<void>();
      connection.writeGate = gate;
      controller.selectMode(TrackerMode.manual);
      time.elapse(Duration.zero);
      connection.receive('Solar Tracker Online. INA219 Monitoring Started.\n');
      gate.complete();
      time.elapse(Duration.zero);
      expect(controller.selectedMode, TrackerMode.auto);
      expect(controller.canMove, isFalse);
    }),
  );
  test(
    'disposal closes a socket arriving after cancellation',
    () => scenario((time, bluetooth, controller) {
      final gate = Completer<SerialConnection>();
      bluetooth.connectGate = gate;
      controller.connect(device);
      time.elapse(Duration.zero);
      controller.dispose();
      time.elapse(Duration.zero);
      final connection = FakeConnection();
      gate.complete(connection);
      time.elapse(Duration.zero);
      expect(connection.closed, isTrue);
      expect(connection.writes, isEmpty);
      expect(time.periodicTimerCount, 0);
    }),
  );
}
