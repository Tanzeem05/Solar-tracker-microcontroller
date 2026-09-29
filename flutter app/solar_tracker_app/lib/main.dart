import 'package:flutter/material.dart';

import 'app.dart';
import 'controllers/tracker_controller.dart';
import 'services/bluetooth_serial_service.dart';
import 'services/alert_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _TrackerRoot());
}

class _TrackerRoot extends StatefulWidget {
  const _TrackerRoot();
  @override
  State<_TrackerRoot> createState() => _TrackerRootState();
}

class _TrackerRootState extends State<_TrackerRoot> {
  late final controller = TrackerController(
    BluetoothSerialService(),
    alerts: AndroidAlertService(),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SolarTrackerApp(controller: controller);
}
