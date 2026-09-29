import '../models/tracker_state.dart';

class BluetoothFailure implements Exception {
  const BluetoothFailure(
    this.message, [
    this.status = ConnectionStatus.disconnected,
  ]);
  final String message;
  final ConnectionStatus status;
  @override
  String toString() => message;
}

abstract interface class SerialConnection {
  Stream<List<int>> get input;
  Stream<bool> get connected;
  Future<void> write(String command);
  Future<void> close();
}

abstract interface class BluetoothGateway {
  Stream<bool> get adapterEnabled;
  Future<void> prepare();
  Future<List<PairedDevice>> pairedDevices();
  Future<SerialConnection> connect(String address);
  Future<void> openBluetoothSettings();
  Future<void> openAppSettings();
  Future<void> dispose();
}
