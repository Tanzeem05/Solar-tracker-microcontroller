import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solar_tracker_app/models/tracker_state.dart';
import 'package:solar_tracker_app/services/bluetooth_serial_service.dart';

void main() {
  test('connect errors map to actionable guidance', () {
    final cases = {
      BtcConnectFailure.notPaired: 'Pair HC-05',
      BtcConnectFailure.serviceNotSupported: 'SPP',
      BtcConnectFailure.busy: 'busy',
      BtcConnectFailure.timeout: 'timed out',
      BtcConnectFailure.unreachable: 'move closer',
      BtcConnectFailure.unknown: 'move closer',
    };
    for (final entry in cases.entries) {
      final failure = BluetoothSerialService.mapFailure(
        BtcConnectionException('failure', cause: entry.key),
      );
      expect(failure.message, contains(entry.value));
    }
    expect(
      BluetoothSerialService.mapFailure(const BtcPermissionException()).status,
      ConnectionStatus.permissionNeeded,
    );
    expect(
      BluetoothSerialService.mapFailure(const BtcDisabledException()).status,
      ConnectionStatus.adapterOff,
    );
  });
}
