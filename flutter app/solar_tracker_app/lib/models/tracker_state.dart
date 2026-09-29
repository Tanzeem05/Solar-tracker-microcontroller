enum ConnectionStatus {
  disconnected,
  preparing,
  connecting,
  connected,
  disconnecting,
  permissionNeeded,
  adapterOff,
  unsupported,
}

enum TrackerMode { auto, manual }

enum Direction {
  up('U'),
  down('D'),
  left('L'),
  right('R');

  const Direction(this.command);
  final String command;
}

enum Metric {
  voltage,
  current,
  power,
  loadVoltage,
  loadCurrent,
  loadPower,
  temperature,
}

enum RainCondition { dry, raining, protecting }

class RainReading {
  const RainReading({this.condition, this.updatedAt});
  final RainCondition? condition;
  final DateTime? updatedAt;
  bool isFresh(DateTime now, bool connected) =>
      connected &&
      updatedAt != null &&
      now.difference(updatedAt!) < const Duration(seconds: 3);
}

enum ReadingStatus { waiting, live, stale, error }

class Measurement {
  const Measurement({this.value, this.raw, this.updatedAt, this.error});
  final double? value;
  final String? raw;
  final DateTime? updatedAt;
  final String? error;
  ReadingStatus status(DateTime now, bool connected) {
    if (error != null) return ReadingStatus.error;
    if (value == null) return ReadingStatus.waiting;
    if (!connected ||
        now.difference(updatedAt!) >= const Duration(seconds: 3)) {
      return ReadingStatus.stale;
    }
    return ReadingStatus.live;
  }
}

class PairedDevice {
  const PairedDevice(this.name, this.address);
  final String name;
  final String address;
}

class LogEntry {
  const LogEntry(this.time, this.text, {this.outgoing = false});
  final DateTime time;
  final String text;
  final bool outgoing;
}
