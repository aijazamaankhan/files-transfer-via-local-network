import 'discovery_service.dart';

/// Runs several discovery mechanisms (e.g. UDP multicast and mDNS/Bonjour)
/// and merges their results by device id. A failure in one mechanism never
/// prevents the others from working.
class CompositeDiscovery extends DeviceDiscoveryService {
  CompositeDiscovery(this.delegates) {
    for (final d in delegates) {
      d.addListener(notifyListeners);
    }
  }

  final List<DeviceDiscoveryService> delegates;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  List<DiscoveredDevice> get devices {
    final merged = <String, DiscoveredDevice>{};
    for (final d in delegates) {
      for (final dev in d.devices) {
        final existing = merged[dev.id];
        if (existing == null || dev.lastSeen.isAfter(existing.lastSeen)) {
          merged[dev.id] = dev;
        }
      }
    }
    return merged.values.toList()..sort(
      (a, b) => a.info.name.toLowerCase().compareTo(b.info.name.toLowerCase()),
    );
  }

  @override
  Future<void> start() async {
    _running = true;
    await Future.wait(delegates.map((d) => d.start().catchError((_) {})));
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _running = false;
    await Future.wait(delegates.map((d) => d.stop().catchError((_) {})));
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    await Future.wait(delegates.map((d) => d.refresh().catchError((_) {})));
  }

  @override
  Future<void> announce() async {
    await Future.wait(delegates.map((d) => d.announce().catchError((_) {})));
  }
}
