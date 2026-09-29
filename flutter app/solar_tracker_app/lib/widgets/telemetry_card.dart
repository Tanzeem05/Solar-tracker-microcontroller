import 'package:flutter/material.dart';

import '../models/tracker_state.dart';

class TelemetryCard extends StatelessWidget {
  const TelemetryCard({
    super.key,
    required this.metric,
    required this.measurement,
    required this.now,
    required this.connected,
  });
  final Metric metric;
  final Measurement measurement;
  final DateTime now;
  final bool connected;
  @override
  Widget build(BuildContext context) {
    final (label, unit, icon) = switch (metric) {
      Metric.voltage => ('Solar voltage', 'V', Icons.bolt_outlined),
      Metric.current => ('Solar current', 'mA', Icons.electric_meter_outlined),
      Metric.power => ('Solar power', 'mW', Icons.solar_power_outlined),
      Metric.loadVoltage => ('Load voltage', 'V', Icons.bolt_outlined),
      Metric.loadCurrent => (
        'Load current',
        'mA',
        Icons.electric_meter_outlined,
      ),
      Metric.loadPower => ('Load power', 'mW', Icons.battery_charging_full),
      Metric.temperature => ('Temperature', '°C', Icons.thermostat_outlined),
    };
    final status = measurement.status(now, connected);
    final statusText = switch (status) {
      ReadingStatus.waiting => connected ? 'Waiting' : 'Waiting · disconnected',
      ReadingStatus.live => 'Live',
      ReadingStatus.stale => connected ? 'Stale' : 'Stale · disconnected',
      ReadingStatus.error =>
        connected ? 'Sensor error' : 'Sensor error · disconnected',
    };
    final color = switch (status) {
      ReadingStatus.live => const Color(0xff24734d),
      ReadingStatus.error => const Color(0xffa53022),
      ReadingStatus.stale => const Color(0xff805300),
      _ => const Color(0xff687568),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 12),
            Text(label),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${status == ReadingStatus.error ? '—' : measurement.raw ?? '—'} $unit',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              statusText,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            if (measurement.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  measurement.error!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
