import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solar_tracker_app/app.dart';
import 'package:solar_tracker_app/controllers/tracker_controller.dart';
import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/bluetooth_gateway.dart';
import 'package:solar_tracker_app/widgets/telemetry_card.dart';

import 'fakes.dart';

void main() {
  testWidgets('measurement cards show waiting, live, stale and error', (
    tester,
  ) async {
    final now = DateTime(2026);
    Future<void> render(Measurement reading, bool connected) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TelemetryCard(
                metric: Metric.voltage,
                measurement: reading,
                now: now,
                connected: connected,
              ),
            ),
          ),
        );
    await render(const Measurement(), true);
    expect(find.text('Waiting'), findsOneWidget);
    await render(
      Measurement(value: 5.12, raw: '5.120000', updatedAt: now),
      true,
    );
    expect(find.text('5.120000 V'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    await render(
      Measurement(
        value: 5.12,
        raw: '5.120000',
        updatedAt: now.subtract(const Duration(seconds: 3)),
      ),
      true,
    );
    expect(find.text('Stale'), findsOneWidget);
    await render(const Measurement(error: 'Check INA219'), true);
    expect(find.text('Sensor error'), findsOneWidget);
    expect(find.text('— V'), findsOneWidget);
  });

  testWidgets(
    'paired chooser, initial Auto, Manual warning, and direction tap',
    (tester) async {
      final bluetooth = FakeBluetooth();
      final controller = TrackerController(bluetooth);
      addTearDown(controller.dispose);
      await tester.pumpWidget(SolarTrackerApp(controller: controller));
      await tester.tap(find.text('Connect HC-05'));
      await tester.pumpAndSettle();
      expect(find.text('00:11:22:33:44:55'), findsOneWidget);
      await tester.tap(find.text('HC-05'));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      expect(controller.canMove, isFalse);
      await tester.tap(find.text('Controls'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Manual'));
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      expect(
        find.text('Manual mode disables firmware rain protection'),
        findsOneWidget,
      );
      final up = find.byKey(const ValueKey('direction-up'));
      await tester.ensureVisible(up);
      await tester.tap(up);
      await tester.pump();
      expect(bluetooth.connections.single.writes, ['A', 'M', 'U']);
      await tester.pump(const Duration(seconds: 1));
      expect(bluetooth.connections.single.writes, ['A', 'M', 'U']);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('permission denial and empty paired list provide guidance', (
    tester,
  ) async {
    final bluetooth = FakeBluetooth()
      ..prepareError = const BluetoothFailure(
        'Allow Nearby devices permission.',
        ConnectionStatus.permissionNeeded,
      );
    final controller = TrackerController(bluetooth);
    addTearDown(controller.dispose);
    await tester.pumpWidget(SolarTrackerApp(controller: controller));
    await tester.tap(find.text('Connect HC-05'));
    await tester.pumpAndSettle();
    expect(find.text('Permission needed'), findsOneWidget);
    expect(find.text('App Settings'), findsOneWidget);
    bluetooth.prepareError = null;
    bluetooth.devices = [];
    await tester.tap(find.text('Connect HC-05'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No paired devices.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('connecting disables a second connection attempt', (
    tester,
  ) async {
    final bluetooth = FakeBluetooth()
      ..connectGate = Completer<SerialConnection>();
    final controller = TrackerController(bluetooth);
    addTearDown(controller.dispose);
    await tester.pumpWidget(SolarTrackerApp(controller: controller));
    unawaited(controller.connect(bluetooth.devices.single));
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Connect HC-05'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Connecting…'), findsOneWidget);
    bluetooth.connectGate!.complete(FakeConnection());
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'narrow screen and large text remain scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TrackerController(FakeBluetooth());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: SolarTrackerApp(controller: controller),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final tab in ['Controls', 'Monitor', 'Overview']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('overview fits both sensors and weather on a typical phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bluetooth = FakeBluetooth();
    final controller = TrackerController(bluetooth);
    addTearDown(controller.dispose);
    await controller.connect(bluetooth.devices.single);
    bluetooth.connections.single.receive(
      'Solar Voltage: 5.120000 V\nSolar Current: 3.000 mA\nSolar Power: 15.360 mW\nBattery Voltage: 12.000000 V\nBattery Current: 10.000 mA\nBattery Power: 120.000 mW\nTemperature: 41.00 C\n',
    );
    await tester.pumpWidget(SolarTrackerApp(controller: controller));
    expect(find.text('Solar input'), findsOneWidget);
    expect(find.text('Load / battery'), findsOneWidget);
    expect(find.text('12.000000 V'), findsOneWidget);
    expect(find.text('High · above 40°C'), findsOneWidget);
    expect(find.text('Waiting for rain report'), findsOneWidget);
    expect(
      tester.getBottomRight(find.text('Waiting for rain report')).dy,
      lessThan(tester.getTopLeft(find.byType(NavigationBar)).dy),
    );
    expect(find.byKey(const ValueKey('direction-up')), findsNothing);
    bluetooth.connections.single.receive('Rain: Dry\nTemperature: 40.00 C\n');
    await tester.pump();
    expect(find.text('Dry'), findsOneWidget);
    expect(find.text('Normal · ≤ 40°C'), findsOneWidget);
    await tester.tap(find.text('Controls'));
    await tester.pumpAndSettle();
    await controller.selectMode(TrackerMode.manual);
    await tester.pump();
    final up = find.byKey(const ValueKey('direction-up'));
    await tester.ensureVisible(up);
    final gesture = await tester.startGesture(tester.getCenter(up));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    final count = bluetooth.connections.single.writes.length;
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(bluetooth.connections.single.writes.length, count);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'missing rain guidance becomes live dry or protected rain after firmware reports',
    (tester) async {
      final bluetooth = FakeBluetooth();
      var time = DateTime(2026);
      final controller = TrackerController(bluetooth, clock: () => time);
      addTearDown(controller.dispose);
      await controller.connect(bluetooth.devices.single);
      await tester.pumpWidget(SolarTrackerApp(controller: controller));
      expect(find.text('Waiting for rain report'), findsOneWidget);
      time = time.add(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text('No rain data. Flash the updated main.c.'),
        findsOneWidget,
      );
      bluetooth.connections.single.receive(
        'Rain: Detected; Tracking stopped\r\n',
      );
      await tester.pump();
      expect(find.text('Raining'), findsOneWidget);
      expect(find.text('Tracking stopped · rain stow'), findsOneWidget);
      expect(
        find.text('No rain data. Flash the updated main.c.'),
        findsNothing,
      );
      time = time.add(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Stale · last reported'), findsOneWidget);
      bluetooth.connections.single.receive('Rain: Dry\r\n');
      await tester.pump();
      expect(find.text('Dry'), findsOneWidget);
      expect(find.text('No rain detected'), findsOneWidget);
      await controller.disconnect();
      await tester.pump();
      expect(find.text('Disconnected · last reported'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    },
  );
}
