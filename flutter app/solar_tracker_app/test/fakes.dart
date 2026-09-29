import 'dart:async';
import 'dart:convert';

import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/bluetooth_gateway.dart';

class FakeConnection implements SerialConnection {
  // Return a fresh cancellation Future in the fake-clock zone. A broadcast
  // controller can return Dart's cached root-zone Future, outside fake_async.
  final bytes = StreamController<List<int>>(
    sync: true,
    onCancel: () => Future<void>.value(),
  );
  final states = StreamController<bool>(
    sync: true,
    onCancel: () => Future<void>.value(),
  );
  final writes = <String>[];
  final order = <String>[];
  Completer<void>? writeGate;
  Object? writeError;
  bool closed = false;
  @override
  Stream<List<int>> get input {
    order.add('listen-input');
    return bytes.stream;
  }

  @override
  Stream<bool> get connected {
    order.add('listen-state');
    return states.stream;
  }

  @override
  Future<void> write(String command) async {
    if (closed) throw StateError('closed');
    order.add('write-$command');
    writes.add(command);
    if (writeError != null) throw writeError!;
    await writeGate?.future;
  }

  void receive(String text) => bytes.add(ascii.encode(text));
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(bytes.close());
    unawaited(states.close());
  }
}

class FakeBluetooth implements BluetoothGateway {
  final adapter = StreamController<bool>.broadcast(sync: true);
  final connections = <FakeConnection>[];
  final addresses = <String>[];
  List<PairedDevice> devices = [
    const PairedDevice('HC-05', '00:11:22:33:44:55'),
  ];
  Object? prepareError;
  Completer<void>? prepareGate;
  Completer<SerialConnection>? connectGate;
  FakeConnection? nextConnection;
  int prepareCount = 0;
  @override
  Stream<bool> get adapterEnabled => adapter.stream;
  @override
  Future<void> prepare() async {
    prepareCount++;
    if (prepareError != null) throw prepareError!;
    await prepareGate?.future;
  }

  @override
  Future<List<PairedDevice>> pairedDevices() async => [...devices];
  @override
  Future<SerialConnection> connect(String address) async {
    addresses.add(address);
    if (connectGate != null) return connectGate!.future;
    final connection = nextConnection ?? FakeConnection();
    nextConnection = null;
    connections.add(connection);
    return connection;
  }

  @override
  Future<void> openBluetoothSettings() async {}
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> dispose() async {
    await adapter.close();
  }
}
