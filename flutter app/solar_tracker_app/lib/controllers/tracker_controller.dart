import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/tracker_state.dart';
import '../services/bluetooth_gateway.dart';
import '../services/alert_service.dart';
import '../services/telemetry_parser.dart';

class TrackerController extends ChangeNotifier {
  TrackerController(this.bluetooth, {DateTime Function()? clock, this.alerts})
    : _clock = clock ?? DateTime.now {
    _freshness = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _notify(),
    );
    _adapterSubscription = bluetooth.adapterEnabled.listen((enabled) {
      if (!enabled && (isConnected || isBusy)) {
        unawaited(
          disconnect(
            message: 'Bluetooth is off. Turn it on, then retry.',
            status: ConnectionStatus.adapterOff,
          ),
        );
      }
    }, onError: (Object _) {});
  }

  final BluetoothGateway bluetooth;
  final AlertService? alerts;
  RainReading rain = const RainReading();
  bool notificationsEnabled = false;
  bool notificationBusy = false;
  String? notificationMessage;
  bool _heatLatched = false;
  bool _rainLatched = false;
  DateTime? heatWarningAt;
  final DateTime Function() _clock;
  final TelemetryParser _parser = TelemetryParser();
  final SerialLineFramer _framer = SerialLineFramer();
  final Map<Metric, Measurement> _readings = {
    for (final metric in Metric.values) metric: const Measurement(),
  };
  final Queue<LogEntry> _log = Queue();
  SerialConnection? _connection;
  StreamSubscription<List<int>>? _inputSubscription;
  StreamSubscription<bool>? _stateSubscription;
  StreamSubscription<bool>? _adapterSubscription;
  Timer? _freshness;
  Timer? _holdDelay;
  Timer? _holdRepeat;
  Future<void>? _pendingWrite;
  bool _disposed = false;
  bool _attemptActive = false;
  bool _closing = false;
  bool _background = false;
  int _generation = 0;
  int _modeRevision = 0;
  Direction? _heldDirection;
  DateTime? _connectedAt;
  DateTime? _lastTelemetryAt;
  ConnectionStatus status = ConnectionStatus.disconnected;
  TrackerMode? selectedMode;
  PairedDevice? selectedDevice;
  String? message;

  DateTime get now => _clock();
  Map<Metric, Measurement> get readings => Map.unmodifiable(_readings);
  List<LogEntry> get log => List.unmodifiable(_log);
  bool get isConnected => status == ConnectionStatus.connected;
  bool get isBusy => _attemptActive || _closing;
  bool get writing => _pendingWrite != null;
  bool get canSelectMode => isConnected && !writing && !_background;
  bool get canMove => canSelectMode && selectedMode == TrackerMode.manual;
  bool get noTelemetry =>
      isConnected &&
      _connectedAt != null &&
      now.difference(_lastTelemetryAt ?? _connectedAt!) >=
          const Duration(seconds: 10);

  bool get missingRainTelemetry =>
      isConnected &&
      rain.condition == null &&
      _connectedAt != null &&
      now.difference(_connectedAt!) >= const Duration(seconds: 10);

  Future<List<PairedDevice>> discoverPairedDevices() async {
    if (isBusy || isConnected || _disposed || _background) return [];
    _attemptActive = true;
    final generation = ++_generation;
    status = ConnectionStatus.preparing;
    message = null;
    _notify();
    try {
      await bluetooth.prepare();
      if (!_valid(generation)) return [];
      final devices = await bluetooth.pairedDevices();
      if (!_valid(generation)) return [];
      devices.sort((a, b) {
        final aHc = a.name.toUpperCase().contains('HC-05');
        final bHc = b.name.toUpperCase().contains('HC-05');
        if (aHc != bHc) return aHc ? -1 : 1;
        return '${a.name}${a.address}'.compareTo('${b.name}${b.address}');
      });
      status = ConnectionStatus.disconnected;
      if (devices.isEmpty) {
        message =
            'No paired devices. Pair HC-05 in Bluetooth Settings first (PIN 1234 or 0000).';
      }
      return devices;
    } catch (error) {
      if (_valid(generation)) _setFailure(error);
      return [];
    } finally {
      _attemptActive = false;
      _notify();
    }
  }

  Future<void> connect(PairedDevice device) async {
    if (isBusy || isConnected || _disposed || _background) return;
    _attemptActive = true;
    final generation = ++_generation;
    selectedDevice = device;
    selectedMode = null;
    status = ConnectionStatus.connecting;
    message = null;
    _framer.reset();
    _notify();
    try {
      await bluetooth.prepare();
      if (!_valid(generation)) return;
      final connection = await bluetooth.connect(device.address);
      if (!_valid(generation)) {
        await connection.close();
        return;
      }
      _connection = connection;
      _resetEnvironment();
      for (final metric in Metric.values) {
        _readings[metric] = const Measurement();
      }
      _inputSubscription = connection.input.listen(
        (bytes) {
          if (_valid(generation)) {
            for (final line in _framer.add(bytes)) {
              _handleLine(line);
            }
            _notify();
          }
        },
        onDone: () => _remoteClosed(generation),
        onError: (Object error) => _remoteClosed(generation, error),
      );
      _stateSubscription = connection.connected.listen((connected) {
        if (!connected) _remoteClosed(generation);
      }, onError: (Object error) => _remoteClosed(generation, error));
      await _write(connection, 'A');
      if (!_valid(generation)) return;
      selectedMode = TrackerMode.auto;
      status = ConnectionStatus.connected;
      _connectedAt = now;
      _lastTelemetryAt = null;
      _append(
        'Auto requested; firmware does not acknowledge commands.',
        outgoing: true,
      );
    } catch (error) {
      if (_valid(generation)) {
        final failure = _failure(error);
        await disconnect(message: failure.message, status: failure.status);
      }
    } finally {
      _attemptActive = false;
      _notify();
    }
  }

  Future<void> retry() async {
    final device = selectedDevice;
    if (device != null) await connect(device);
  }

  Future<void> selectMode(TrackerMode mode) async {
    stopHold();
    if (!canSelectMode) return;
    final generation = _generation;
    final modeRevision = _modeRevision;
    if (await _send(mode == TrackerMode.auto ? 'A' : 'M') &&
        _valid(generation) &&
        modeRevision == _modeRevision) {
      selectedMode = mode;
      _append(
        '${mode == TrackerMode.auto ? 'Auto' : 'Manual'} requested; firmware does not acknowledge commands.',
        outgoing: true,
      );
      _notify();
    }
  }

  Future<void> nudge(Direction direction) async {
    if (canMove) await _send(direction.command);
  }

  void startHold(Direction direction) {
    stopHold();
    if (!canMove) return;
    _heldDirection = direction;
    unawaited(nudge(direction));
    _holdDelay = Timer(const Duration(milliseconds: 400), () {
      if (_heldDirection != direction) return;
      unawaited(nudge(direction));
      _holdRepeat = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_heldDirection == direction) unawaited(nudge(direction));
      });
    });
  }

  void stopHold() {
    _heldDirection = null;
    _holdDelay?.cancel();
    _holdRepeat?.cancel();
    _holdDelay = null;
    _holdRepeat = null;
  }

  Future<bool> _send(String command) async {
    final connection = _connection;
    if (connection == null || !isConnected || writing || _background) {
      return false;
    }
    final generation = _generation;
    try {
      await _write(connection, command);
      if (!_valid(generation)) return false;
      _append(command, outgoing: true);
      return true;
    } catch (error) {
      if (_valid(generation)) {
        await disconnect(
          message: 'Command write failed. ${_failure(error).message}',
        );
      }
      return false;
    } finally {
      _notify();
    }
  }

  Future<void> _write(SerialConnection connection, String command) async {
    final future = Future<void>.sync(
      () => connection.write(command),
    ).timeout(const Duration(seconds: 2));
    _pendingWrite = future;
    _notify();
    try {
      await future;
    } finally {
      if (identical(_pendingWrite, future)) _pendingWrite = null;
      _notify();
    }
  }

  void _remoteClosed(int generation, [Object? error]) {
    if (_valid(generation)) {
      unawaited(
        disconnect(
          message: error == null
              ? 'Connection lost. Power the tracker, move closer, then tap Retry.'
              : _failure(error).message,
        ),
      );
    }
  }

  Future<void> enterBackground() async {
    if (_background || _disposed) return;
    _background = true;
    final hadConnection = _connection != null;
    await disconnect(
      restoreAuto: true,
      message: hadConnection
          ? 'App paused. Auto was attempted before disconnecting; the tracker cannot confirm it. Reconnect to continue.'
          : 'App paused. Reconnect to continue.',
    );
  }

  void enterForeground() {
    _background = false;
    unawaited(refreshNotifications());
    _notify();
  }

  Future<void> refreshNotifications() async {
    if (alerts == null || _disposed) return;
    try {
      notificationsEnabled = await alerts!.enabled();
    } catch (_) {
      notificationsEnabled = false;
    }
    _notify();
  }

  Future<void> enableNotifications() async {
    if (alerts == null || notificationBusy || _disposed) return;
    notificationBusy = true;
    _notify();
    try {
      notificationsEnabled = await alerts!.requestPermission();
      if (_disposed) return;
      notificationMessage = notificationsEnabled
          ? null
          : 'Notifications are off. Enable them in App Settings; live status still works.';
      if (notificationsEnabled) {
        final temperature = _readings[Metric.temperature]!;
        if (temperature.status(now, isConnected) == ReadingStatus.live &&
            temperature.value! > 40) {
          _heatLatched = false;
          _heatAlert();
        }
        if (rain.isFresh(now, isConnected) &&
            rain.condition != RainCondition.dry) {
          _rainLatched = false;
          _rainAlert(rain.condition!);
        }
      }
    } catch (_) {
      notificationMessage =
          'Notifications could not be enabled. Check App Settings.';
    } finally {
      notificationBusy = false;
      _notify();
    }
  }

  void _resetEnvironment() {
    rain = const RainReading();
    heatWarningAt = null;
    _heatLatched = false;
    _rainLatched = false;
  }

  void _heatAlert() {
    if (_heatLatched) return;
    _heatLatched = true;
    unawaited(
      _postAlert(
        40,
        'High panel temperature',
        'Panel temperature exceeds 40°C. Check the solar panel.',
      ),
    );
  }

  void _rainAlert(RainCondition condition) {
    if (condition == RainCondition.dry) {
      _rainLatched = false;
      return;
    }
    if (_rainLatched) return;
    _rainLatched = true;
    unawaited(
      _postAlert(
        41,
        'Rain has started',
        condition == RainCondition.protecting
            ? 'Rain has started. Solar tracking has stopped; the panel is moving to its rain protection position.'
            : 'Rain has started. Panel stop is not confirmed. Manual mode disables rain protection.',
      ),
    );
  }

  Future<void> _postAlert(int id, String title, String body) async {
    final generation = _generation;
    if (alerts == null || _background || _disposed) return;
    try {
      final shown = await alerts!.show(id: id, title: title, body: body);
      if (!_valid(generation)) return;
      notificationsEnabled = shown;
      notificationMessage = shown
          ? null
          : 'Notifications are off. Enable alerts to receive phone notifications.';
    } catch (_) {
      if (!_valid(generation)) return;
      notificationMessage =
          'Phone notification failed. Check notification settings; live status still works.';
    }
    _notify();
  }

  Future<void> disconnect({
    bool restoreAuto = false,
    String? message,
    ConnectionStatus status = ConnectionStatus.disconnected,
  }) async {
    stopHold();
    if (_closing) return;
    _closing = true;
    ++_generation;
    this.status = ConnectionStatus.disconnecting;
    selectedMode = null;
    final connection = _connection;
    _connection = null;
    final pending = _pendingWrite;
    _pendingWrite = null;
    final input = _inputSubscription;
    final state = _stateSubscription;
    _inputSubscription = null;
    _stateSubscription = null;
    _framer.reset();
    _notify();
    try {
      if (restoreAuto && connection != null) {
        var expired = false;
        try {
          await (() async {
            if (pending != null) {
              try {
                await pending;
              } catch (_) {}
            }
            if (!expired) await connection.write('A');
          })().timeout(const Duration(milliseconds: 500));
          _append('A (Auto requested before leaving)', outgoing: true);
        } catch (_) {
          message =
              'Disconnected. Auto could not be requested before leaving; the tracker may remain in Manual.';
        } finally {
          expired = true;
        }
      }
      await input?.cancel();
      await state?.cancel();
      await connection?.close();
    } catch (_) {
      message ??=
          'Disconnected. The Bluetooth connection could not be closed normally.';
    } finally {
      this.status = status;
      this.message = message;
      _closing = false;
      _notify();
    }
  }

  Future<void> openBluetoothSettings() =>
      _openSettings(bluetooth.openBluetoothSettings);
  Future<void> openAppSettings() => _openSettings(bluetooth.openAppSettings);
  Future<void> _openSettings(Future<void> Function() open) async {
    stopHold();
    try {
      await open();
    } catch (_) {
      message =
          'Open Android Settings manually to change Bluetooth or Nearby devices permission.';
      _notify();
    }
  }

  void _handleLine(String line) {
    _append(line);
    final event = _parser.parse(line);
    switch (event.kind) {
      case TelemetryKind.reading:
        _readings[event.metric!] = Measurement(
          value: event.value,
          raw: event.raw,
          updatedAt: now,
        );
        _lastTelemetryAt = now;
        if (event.metric == Metric.temperature) {
          heatWarningAt = null;
          if (event.value! > 40) {
            _heatAlert();
          } else {
            _heatLatched = false;
          }
        }
      case TelemetryKind.electricalError:
        for (final metric in [Metric.voltage, Metric.current, Metric.power]) {
          _readings[metric] = const Measurement(
            error: 'Check INA219 power, SDA/SCL, address, and ground.',
          );
        }
      case TelemetryKind.temperatureError:
        heatWarningAt = null;
        _readings[Metric.temperature] = const Measurement(
          error: 'Check DS18B20 wiring, pull-up, power, and ground.',
        );
      case TelemetryKind.loadError:
        for (final metric in [
          Metric.loadVoltage,
          Metric.loadCurrent,
          Metric.loadPower,
        ]) {
          _readings[metric] = const Measurement(
            error:
                'Check load INA219 power, PC2/PC3 wiring, address, and ground.',
          );
        }
      case TelemetryKind.heatWarning:
        heatWarningAt = now;
        _heatAlert();
      case TelemetryKind.rain:
        rain = RainReading(condition: event.rain, updatedAt: now);
        _rainAlert(event.rain!);
      case TelemetryKind.startup:
        _resetEnvironment();
        _modeRevision++;
        for (final metric in Metric.values) {
          _readings[metric] = const Measurement();
        }
        // Firmware always boots in Auto; a previous Manual request is obsolete.
        selectedMode = TrackerMode.auto;
        stopHold();
        _connectedAt = now;
        _lastTelemetryAt = null;
      case TelemetryKind.separator:
      case TelemetryKind.unknown:
        break;
    }
  }

  void clearLog() {
    _log.clear();
    _notify();
  }

  void _append(String text, {bool outgoing = false}) {
    _log.add(LogEntry(now, text, outgoing: outgoing));
    while (_log.length > 200) {
      _log.removeFirst();
    }
  }

  BluetoothFailure _failure(Object error) => error is BluetoothFailure
      ? error
      : const BluetoothFailure(
          'Connection failed. Power the tracker, move closer, and disconnect other phones from HC-05 before retrying.',
        );
  void _setFailure(Object error) {
    final failure = _failure(error);
    status = failure.status;
    message = failure.message;
  }

  bool _valid(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _freshness?.cancel();
    stopHold();
    unawaited(_adapterSubscription?.cancel());
    unawaited(disconnect().whenComplete(bluetooth.dispose));
    super.dispose();
  }
}
