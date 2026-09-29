import 'package:flutter/material.dart';

import '../controllers/tracker_controller.dart';
import '../models/tracker_state.dart';

class OverviewPanel extends StatelessWidget {
  const OverviewPanel({super.key, required this.controller});
  final TrackerController controller;
  static const green = Color(0xff24734d);
  static const red = Color(0xffa53022);

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _electrical(
              context,
              'Solar input',
              Icons.solar_power_outlined,
              [Metric.voltage, Metric.current, Metric.power],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _electrical(
              context,
              'Load / battery',
              Icons.battery_charging_full,
              [Metric.loadVoltage, Metric.loadCurrent, Metric.loadPower],
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _temperature(context)),
          const SizedBox(width: 8),
          Expanded(child: _rain(context)),
        ],
      ),
      if (controller.selectedMode == TrackerMode.manual)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Manual mode disables firmware rain protection',
            style: TextStyle(color: red),
          ),
        ),
    ],
  );

  Widget _electrical(
    BuildContext context,
    String title,
    IconData icon,
    List<Metric> metrics,
  ) => _module(title, icon, [
    for (var i = 0; i < metrics.length; i++) ...[
      if (i != 0) const Divider(height: 12),
      _reading(
        context,
        metrics[i],
        ['Voltage', 'Current', 'Power'][i],
        ['V', 'mA', 'mW'][i],
      ),
    ],
  ]);

  Widget _reading(
    BuildContext context,
    Metric metric,
    String label,
    String unit,
  ) {
    final measurement = controller.readings[metric]!;
    final status = measurement.status(controller.now, controller.isConnected);
    final statusLabel = _status(status);
    return Semantics(
      label: '$label: $statusLabel',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '${measurement.error != null ? '—' : measurement.raw ?? '—'} $unit',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Tooltip(
            message: measurement.error ?? statusLabel,
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 11,
                color: status == ReadingStatus.error
                    ? red
                    : status == ReadingStatus.live
                    ? green
                    : Colors.brown,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _status(ReadingStatus status) => switch (status) {
    ReadingStatus.waiting => 'Waiting',
    ReadingStatus.live => 'Live',
    ReadingStatus.stale => controller.isConnected ? 'Stale' : 'Disconnected',
    ReadingStatus.error =>
      controller.isConnected ? 'Sensor error' : 'Error · disconnected',
  };

  Widget _temperature(BuildContext context) {
    final temperature = controller.readings[Metric.temperature]!;
    final state = temperature.status(controller.now, controller.isConnected);
    final warningFresh =
        controller.isConnected &&
        controller.heatWarningAt != null &&
        controller.now.difference(controller.heatWarningAt!) <
            const Duration(seconds: 3);
    final high =
        warningFresh ||
        (state == ReadingStatus.live && temperature.value! > 40);
    final label = high
        ? 'High · above 40°C'
        : state == ReadingStatus.live
        ? 'Normal · ≤ 40°C'
        : _status(state);
    return _module('Temperature', Icons.thermostat_outlined, [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '${temperature.error == null ? temperature.raw ?? '—' : '—'} °C',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
      Text(
        label,
        style: TextStyle(
          color: high || state == ReadingStatus.error ? red : green,
          fontWeight: FontWeight.w600,
        ),
      ),
    ]);
  }

  Widget _rain(BuildContext context) {
    final reading = controller.rain;
    final fresh = reading.isFresh(controller.now, controller.isConnected);
    final title = switch (reading.condition) {
      null => controller.isConnected ? 'Waiting' : 'Unknown',
      RainCondition.dry => 'Dry',
      RainCondition.raining || RainCondition.protecting => 'Raining',
    };
    final description = reading.condition == null
        ? controller.missingRainTelemetry
              ? 'No rain data. Flash the updated main.c.'
              : controller.isConnected
              ? 'Waiting for rain report'
              : 'Connect to read rain status'
        : !fresh
        ? controller.isConnected
              ? 'Stale · last reported'
              : 'Disconnected · last reported'
        : switch (reading.condition!) {
            RainCondition.dry => 'No rain detected',
            RainCondition.raining => 'Stop not confirmed',
            RainCondition.protecting => 'Tracking stopped · rain stow',
          };
    return _module('Rain', Icons.water_drop_outlined, [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      Text(
        description,
        style: TextStyle(
          fontSize: 12,
          color: fresh && reading.condition != RainCondition.dry
              ? red
              : Colors.brown,
        ),
      ),
    ]);
  }

  Widget _module(String title, IconData icon, List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: green),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );
}
