import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/tracker_controller.dart';
import '../models/tracker_state.dart';
import '../widgets/direction_pad.dart';
import '../widgets/serial_log.dart';
import '../widgets/overview_panel.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.controller});
  final TrackerController controller;
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  TrackerController get controller => widget.controller;
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(controller.refreshNotifications());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) controller.stopHold();
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(controller.enterBackground());
    } else if (state == AppLifecycleState.resumed) {
      controller.enterForeground();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.stopHold();
    super.dispose();
  }

  Future<void> _chooseDevice() async {
    controller.stopHold();
    final devices = await controller.discoverPairedDevices();
    if (!mounted || devices.isEmpty) return;
    final chosen = await showModalBottomSheet<PairedDevice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Choose a paired device',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final device in devices)
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(device.name),
                      subtitle: Text(device.address),
                      onTap: () => Navigator.pop(context, device),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted && chosen != null) await controller.connect(chosen);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(controller.enterBackground());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Solar Tracker',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: const Icon(Icons.wb_sunny_outlined),
          actions: [
            IconButton(
              tooltip: 'Bluetooth Settings',
              onPressed: controller.openBluetoothSettings,
              icon: const Icon(Icons.settings_bluetooth),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) {
            controller.stopHold();
            setState(() => _tab = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              label: 'Overview',
            ),
            NavigationDestination(
              icon: Icon(Icons.control_camera),
              label: 'Controls',
            ),
            NavigationDestination(icon: Icon(Icons.terminal), label: 'Monitor'),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SingleChildScrollView(
                key: PageStorageKey('tab-$_tab'),
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _connectionPanel(context),
                    const SizedBox(height: 8),
                    if (_tab == 0) ...[
                      OverviewPanel(controller: controller),
                      if (controller.noTelemetry)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text(
                            'No recent telemetry. Check tracker power, HC-05 TX to PD0/RXD, common ground and UART 9600.',
                          ),
                        ),
                      _notificationPanel(),
                    ],
                    if (_tab == 1) _controls(context),
                    if (_tab == 2) ...[
                      SerialLog(
                        entries: controller.log,
                        onClear: controller.clearLog,
                        initiallyExpanded: true,
                      ),
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Live alerts require this app to remain open and connected. Rain status requires firmware that transmits rain reports.',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _notificationPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.notifications_outlined, size: 20),
          Text(
            controller.notificationsEnabled
                ? 'Alerts enabled'
                : 'Phone alerts are off',
          ),
          if (!controller.notificationsEnabled)
            TextButton(
              onPressed: controller.notificationBusy
                  ? null
                  : controller.enableNotifications,
              child: const Text('Enable alerts'),
            ),
        ],
      ),
      const Text(
        'Alerts while open and connected · High temperature > 40°C',
        style: TextStyle(fontSize: 12),
      ),
      if (controller.notificationMessage != null) ...[
        Text(controller.notificationMessage!),
        TextButton(
          onPressed: controller.openAppSettings,
          child: const Text('App Settings'),
        ),
      ],
    ],
  );

  Widget _controls(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Panel control', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'Mode reflects your request; the tracker sends no confirmation.',
          ),
          const SizedBox(height: 12),
          SegmentedButton<TrackerMode>(
            segments: const [
              ButtonSegment(
                value: TrackerMode.auto,
                label: Text('Auto'),
                icon: Icon(Icons.auto_mode),
              ),
              ButtonSegment(
                value: TrackerMode.manual,
                label: Text('Manual'),
                icon: Icon(Icons.touch_app_outlined),
              ),
            ],
            selected: {
              if (controller.selectedMode != null) controller.selectedMode!,
            },
            emptySelectionAllowed: true,
            onSelectionChanged: controller.canSelectMode
                ? (modes) {
                    if (modes.isNotEmpty) {
                      unawaited(controller.selectMode(modes.first));
                    }
                  }
                : null,
          ),
          if (controller.selectedMode == TrackerMode.manual)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffff0d0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Manual mode disables firmware rain protection',
              ),
            ),
          const SizedBox(height: 12),
          DirectionPad(controller: controller),
          const SizedBox(height: 12),
          Text(
            controller.selectedMode == TrackerMode.manual
                ? 'Tap to nudge. Hold to repeat. Release to stop sending.'
                : 'Select Manual to move the panel.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Widget _connectionPanel(BuildContext context) {
    final label = switch (controller.status) {
      ConnectionStatus.disconnected => 'Disconnected',
      ConnectionStatus.preparing => 'Checking Bluetooth…',
      ConnectionStatus.connecting => 'Connecting… (up to 15 seconds)',
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.disconnecting => 'Disconnecting…',
      ConnectionStatus.permissionNeeded => 'Permission needed',
      ConnectionStatus.adapterOff => 'Bluetooth is off',
      ConnectionStatus.unsupported => 'Bluetooth Classic unavailable',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  controller.isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth,
                  color: controller.isConnected
                      ? const Color(0xff24734d)
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (controller.isBusy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (controller.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(controller.message!),
              ),
            if (!controller.isConnected &&
                controller.selectedDevice == null &&
                controller.message == null)
              const Text(
                'Pair HC-05 in Bluetooth Settings first.',
                style: TextStyle(fontSize: 12),
              ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: controller.isBusy
                      ? null
                      : controller.isConnected
                      ? () => controller.disconnect()
                      : _chooseDevice,
                  icon: Icon(
                    controller.isConnected ? Icons.link_off : Icons.bluetooth,
                  ),
                  label: Text(
                    controller.isConnected ? 'Disconnect' : 'Connect HC-05',
                  ),
                ),
                if (!controller.isConnected &&
                    controller.selectedDevice != null)
                  OutlinedButton(
                    onPressed: controller.isBusy ? null : controller.retry,
                    child: const Text('Retry'),
                  ),
                if (controller.isConnected && controller.selectedDevice != null)
                  Text(controller.selectedDevice!.name),
                if (controller.status == ConnectionStatus.permissionNeeded)
                  TextButton(
                    onPressed: controller.openAppSettings,
                    child: const Text('App Settings'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
