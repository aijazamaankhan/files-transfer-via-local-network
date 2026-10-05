import 'dart:async';

import '../models/history_record.dart';
import '../models/settings.dart';
import '../models/trusted_device.dart';
import '../util/notifier.dart';
import 'json_store.dart';

/// Persisted user settings.
class SettingsStore extends Notifier {
  SettingsStore(this._store, this._defaults) : _settings = _defaults;

  final JsonFileStore _store;
  final AppSettings _defaults;
  AppSettings _settings;

  AppSettings get value => _settings;

  Future<void> load() async {
    final raw = await _store.read();
    if (raw is Map) {
      _settings = AppSettings.fromJson(raw.cast(), _defaults);
    }
  }

  Future<void> flush() => _store.flush();

  Future<void> update(AppSettings Function(AppSettings) change) async {
    _settings = change(_settings);
    notifyListeners();
    await _store.write(_settings.toJson());
  }
}

/// Paired devices and their shared secrets.
class TrustedDeviceStore extends Notifier {
  TrustedDeviceStore(this._store);

  final JsonFileStore _store;
  final Map<String, TrustedDevice> _devices = {};

  List<TrustedDevice> get all =>
      _devices.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  TrustedDevice? get(String id) => _devices[id];

  bool isTrusted(String id) => _devices.containsKey(id);

  Future<void> flush() => _store.flush();

  Future<void> load() async {
    final raw = await _store.read();
    if (raw is List) {
      for (final item in raw) {
        try {
          final d = TrustedDevice.fromJson((item as Map).cast());
          _devices[d.id] = d;
        } catch (_) {
          // Skip malformed entries rather than losing all pairings.
        }
      }
    }
  }

  Future<void> put(TrustedDevice device) async {
    _devices[device.id] = device;
    notifyListeners();
    await _save();
  }

  Future<void> remove(String id) async {
    if (_devices.remove(id) != null) {
      notifyListeners();
      await _save();
    }
  }

  /// Updates volatile fields (addresses, last seen) without blocking callers.
  void touch(String id, {List<String>? addresses, int? port, String? name}) {
    final d = _devices[id];
    if (d == null) return;
    if (addresses != null && addresses.isNotEmpty) d.lastAddresses = addresses;
    if (port != null || name != null) {
      d.info = d.info.copyWith(port: port, name: name);
    }
    d.lastSeen = DateTime.now();
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() =>
      _store.write(_devices.values.map((d) => d.toJson()).toList());
}

/// Local-only transfer history (never leaves the device).
class TransferHistoryService extends Notifier {
  TransferHistoryService(this._store, {this.maxRecords = 1000});

  final JsonFileStore _store;
  final int maxRecords;
  final List<HistoryRecord> _records = [];

  List<HistoryRecord> get records => List.unmodifiable(_records);

  Future<void> flush() => _store.flush();

  Future<void> load() async {
    final raw = await _store.read();
    if (raw is List) {
      for (final item in raw) {
        try {
          _records.add(HistoryRecord.fromJson((item as Map).cast()));
        } catch (_) {}
      }
    }
  }

  /// Inserts or replaces (by transfer id) a record at the top.
  Future<void> record(HistoryRecord r) async {
    _records.removeWhere((e) => e.transferId == r.transferId);
    _records.insert(0, r);
    if (_records.length > maxRecords) {
      _records.removeRange(maxRecords, _records.length);
    }
    notifyListeners();
    await _save();
  }

  Future<void> remove(String transferId) async {
    _records.removeWhere((e) => e.transferId == transferId);
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _records.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() =>
      _store.write(_records.map((r) => r.toJson()).toList());
}
