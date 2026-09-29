import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';

import '../models/tracker_state.dart';
import 'bluetooth_gateway.dart';

class BluetoothSerialService implements BluetoothGateway {
  final FlutterClassicBluetooth _bluetooth = FlutterClassicBluetooth();
  static const _settings = MethodChannel('solar_tracker/settings');
  final _adapter = StreamController<bool>.broadcast();
  StreamSubscription<BtcAdapterState>? _adapterSubscription;
  bool _disposed = false;

  @override
  Stream<bool> get adapterEnabled => _adapter.stream;

  @override
  Future<void> prepare() => _guard(() async {
    _checkActive();
    if (!await _bluetooth.isSupported()) {
      throw const BluetoothFailure(
        'This phone does not support Bluetooth Classic.',
        ConnectionStatus.unsupported,
      );
    }
    _checkActive();
    const permissions = {BtcPermission.connect};
    var permission = await _bluetooth.checkPermissions(
      permissions: permissions,
    );
    if (permission == BtcPermissionStatus.denied) {
      permission = await _bluetooth.requestPermissions(
        permissions: permissions,
      );
    }
    _checkActive();
    if (permission != BtcPermissionStatus.granted &&
        permission != BtcPermissionStatus.notRequired) {
      throw const BluetoothFailure(
        'Allow Nearby devices permission to connect to HC-05. If denied permanently, enable it in App Settings.',
        ConnectionStatus.permissionNeeded,
      );
    }
    if (!await _bluetooth.isEnabled()) {
      throw const BluetoothFailure(
        'Turn Bluetooth on in Bluetooth Settings, then retry.',
        ConnectionStatus.adapterOff,
      );
    }
    _checkActive();
    // Reading the initial native adapter state requires CONNECT permission.
    _adapterSubscription ??= _bluetooth.adapterState.listen(
      (state) {
        if (state == BtcAdapterState.on ||
            state == BtcAdapterState.off ||
            state == BtcAdapterState.turningOff) {
          _adapter.add(state == BtcAdapterState.on);
        }
      },
      onError: (Object error) {
        _adapter.addError(error);
      },
    );
  });

  @override
  Future<List<PairedDevice>> pairedDevices() => _guard(
    () async => [
      for (final device in await _bluetooth.getPairedDevices())
        PairedDevice(device.displayName, device.address),
    ],
  );

  @override
  Future<SerialConnection> connect(String address) => _guard(() async {
    // The checked-in Android adapter enforces a 15-second native deadline.
    // Avoid a second Dart deadline that could allow overlapping native sockets.
    return _ClassicConnection(
      await _bluetooth.connect(address: address, uuid: BtcUuid.spp),
    );
  });

  @override
  Future<void> openBluetoothSettings() =>
      _settings.invokeMethod<void>('openBluetoothSettings');
  @override
  Future<void> openAppSettings() async {
    if (!await _bluetooth.openAppSettings()) {
      throw const BluetoothFailure('Open App Settings manually.');
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _adapterSubscription?.cancel();
    await _adapter.close();
  }

  void _checkActive() {
    if (_disposed) {
      throw const BluetoothFailure('Bluetooth service was closed.');
    }
  }

  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on BtcException catch (error) {
      throw mapFailure(error);
    }
  }

  static BluetoothFailure mapFailure(BtcException error) {
    if (error is BtcPermissionException ||
        error is BtcConnectionException &&
            error.cause == BtcConnectFailure.permissionDenied) {
      return const BluetoothFailure(
        'Allow Nearby devices permission in App Settings, then retry.',
        ConnectionStatus.permissionNeeded,
      );
    }
    if (error is BtcDisabledException ||
        error is BtcConnectionException &&
            error.cause == BtcConnectFailure.adapterOff) {
      return const BluetoothFailure(
        'Bluetooth is off. Turn it on, then retry.',
        ConnectionStatus.adapterOff,
      );
    }
    if (error is BtcUnsupportedException) {
      return const BluetoothFailure(
        'Bluetooth Classic is unavailable on this phone.',
        ConnectionStatus.unsupported,
      );
    }
    if (error is BtcConnectionException) {
      return BluetoothFailure(switch (error.cause) {
        BtcConnectFailure.notPaired =>
          'Pair HC-05 in Bluetooth Settings first (PIN 1234 or 0000).',
        BtcConnectFailure.serviceNotSupported =>
          'This device does not offer Bluetooth Classic SPP. Select the paired HC-05.',
        BtcConnectFailure.busy =>
          'HC-05 is busy. Disconnect other phones or computers, then retry.',
        BtcConnectFailure.timeout =>
          'Connection timed out. Power the tracker, move closer, and disconnect other phones before retrying.',
        _ =>
          'Could not reach HC-05. Power the tracker, move closer, and disconnect other phones before retrying.',
      });
    }
    if (error is BtcTimeoutException) {
      return const BluetoothFailure(
        'Connection timed out. Power the tracker, move closer, then retry.',
      );
    }
    return const BluetoothFailure(
      'Bluetooth communication failed. Check tracker power and reconnect.',
    );
  }
}

class _ClassicConnection implements SerialConnection {
  _ClassicConnection(this.connection);
  final BtcConnection connection;
  bool _closed = false;
  @override
  Stream<List<int>> get input => connection.input;
  @override
  Stream<bool> get connected => connection.stateStream.map(
    (state) => state == BtcConnectionState.connected,
  );
  @override
  Future<void> write(String command) => BluetoothSerialService._guard(
    () => connection.output.writeString(command),
  );
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await connection.close();
    } finally {
      connection.dispose();
      // The Android plugin otherwise retains two handlers per past socket.
      await const MethodChannel(
        'flutter_classic_bluetooth',
      ).invokeMethod<void>('releaseConnection', {'id': connection.id});
    }
  }
}
