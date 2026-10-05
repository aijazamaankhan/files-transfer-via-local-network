/// Interfaces that platform layers implement. The core engine depends only
/// on these, so platform code can be swapped or mocked in tests.
library;

abstract class NotificationService {
  Future<void> init();

  Future<void> show({
    required int id,
    required String title,
    required String body,
  });
}

class NoopNotificationService implements NotificationService {
  const NoopNotificationService();
  @override
  Future<void> init() async {}
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {}
}

enum BluetoothAvailability { unsupported, unavailable, off, on }

/// Bluetooth integration point (Phase 4). The intended role is connection
/// bootstrap — advertise presence and exchange LAN/hotspot details over BLE —
/// with the file data still flowing over Wi-Fi. See docs/ARCHITECTURE.md §6.
abstract class BluetoothService {
  Future<BluetoothAvailability> availability();
}

class UnsupportedBluetoothService implements BluetoothService {
  const UnsupportedBluetoothService();
  @override
  Future<BluetoothAvailability> availability() async =>
      BluetoothAvailability.unsupported;
}
