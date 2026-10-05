import '../models/device_info.dart';
import '../util/notifier.dart';

/// A device found on the network.
class DiscoveredDevice {
  DiscoveredDevice({
    required this.info,
    required this.address,
    required this.lastSeen,
    this.via = 'lan',
  });

  DeviceInfo info;
  String address;
  DateTime lastSeen;

  /// Discovery mechanism that found it (lan, manual, …).
  final String via;

  String get id => info.id;
}

/// Finds nearby LanBeam devices. Implementations can be swapped (UDP
/// multicast, mDNS, BLE) without touching the transfer logic.
abstract class DeviceDiscoveryService extends Notifier {
  /// Currently visible devices (excluding this one).
  List<DiscoveredDevice> get devices;

  DiscoveredDevice? find(String deviceId) {
    for (final d in devices) {
      if (d.id == deviceId) return d;
    }
    return null;
  }

  bool get isRunning;

  Future<void> start();
  Future<void> stop();

  /// Actively asks devices to announce themselves.
  Future<void> refresh();

  /// Re-announces this device (e.g. after a name or port change).
  Future<void> announce();
}
