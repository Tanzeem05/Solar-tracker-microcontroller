# Local Android fixes to flutter_classic_bluetooth 1.5.0

Source: https://pub.dev/packages/flutter_classic_bluetooth/versions/1.5.0
The original MIT license is retained. Only lib/, android/, and package metadata
are included; this application supports Android only.

The app resolves this checked-in copy through a pubspec dependency override.

1. `handleConnect` skips `cancelDiscovery` on Android 12+ unless SCAN permission
   is already granted. Upstream calls it unconditionally, causing a
   SecurityException for a CONNECT-only client.
2. A 15-second native timer closes an in-progress socket to abort connect.
   Failed sockets are closed, and timers are always cancelled. The app does not
   use the package's Dart-only timeout, which leaves native work running.
3. Connection state subscriptions report an already-closed connection as
   disconnected instead of emitting an unconditional connected snapshot.
4. The app calls an Android-only `releaseConnection` method after cancelling
   subscriptions and closing/disposing the Dart connection. This unregisters
   both native event-channel handlers instead of retaining each past socket.
5. Socket writes run on a worker thread, returning results on the platform
   thread. This lets the app close a blocked socket at its write/background
   deadline. Dart command gating ensures one write at a time. Failure to obtain
   the input stream also emits disconnection instead of silently stopping.

Do not remove this override until equivalent behavior has been verified in an
upstream version, including physical tests on Android 12+ with only CONNECT.
