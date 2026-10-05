import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../core/discovery/discovery_service.dart';
import '../core/models/device_info.dart';
import '../core/protocol/protocol.dart';

/// mDNS / DNS-SD discovery via the platform's native stack (Bonjour on Apple
/// platforms, NSD on Android, Windows DNS-SD, Avahi on Linux).
///
/// This complements UDP multicast: on iOS raw multicast sockets need a
/// special Apple entitlement, whereas Bonjour only needs the Local Network
/// permission and `NSBonjourServices`.
class BonjourDiscovery extends DeviceDiscoveryService {
  BonjourDiscovery({required this.localInfo});

  static const serviceType = '_lanbeam._tcp';

  final DeviceInfo Function() localInfo;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  final Map<String, DiscoveredDevice> _devices = {};
  int _advertisedPort = 0;
  String _advertisedName = '';

  @override
  List<DiscoveredDevice> get devices => _devices.values.toList();

  @override
  bool get isRunning => _discovery != null;

  BonsoirService _service() {
    final info = localInfo();
    _advertisedPort = info.port;
    _advertisedName = info.name;
    return BonsoirService(
      // The instance name must be unique on the network: use the device id.
      name: info.id,
      type: serviceType,
      port: info.port,
      attributes: {
        'n': info.name.length > 60 ? info.name.substring(0, 60) : info.name,
        'dt': info.deviceType.name,
        'os': info.os.name,
        'v': info.appVersion,
        'fp': info.fingerprint,
        'pr': info.protocols.join(','),
        'pv': '${Protocol.version}',
      },
    );
  }

  @override
  Future<void> start() async {
    if (_discovery != null) return;
    await _startBroadcast();
    final discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    await discovery.initialize();
    _sub = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          if (service.name != localInfo().id) {
            service.resolve(discovery.serviceResolver);
          }
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          _onResolved(service);
        case BonsoirDiscoveryServiceLostEvent(:final service):
          if (_devices.remove(service.name) != null) notifyListeners();
        default:
      }
    });
    await discovery.start();
    _discovery = discovery;
  }

  Future<void> _startBroadcast() async {
    final b = BonsoirBroadcast(service: _service(), printLogs: false);
    await b.initialize();
    await b.start();
    _broadcast = b;
  }

  void _onResolved(BonsoirService service) {
    if (service.name == localInfo().id) return;
    final a = service.attributes;
    if (a['pv'] != '${Protocol.version}') return;
    final addresses = service.hostAddresses;
    final address = addresses.firstWhere(
      (h) => InternetAddress.tryParse(h)?.type == InternetAddressType.IPv4,
      orElse: () => addresses.isEmpty ? '' : addresses.first,
    );
    if (address.isEmpty) return;
    try {
      final info = DeviceInfo.fromJson({
        'id': service.name,
        'name': a['n'] ?? 'Unknown device',
        'deviceType': a['dt'],
        'os': a['os'],
        'appVersion': a['v'],
        'protocols': (a['pr'] ?? '').split(','),
        'port': service.port,
        'fp': a['fp'],
      });
      _devices[info.id] = DiscoveredDevice(
        info: info,
        address: address,
        lastSeen: DateTime.now(),
        via: 'mdns',
      );
      notifyListeners();
    } on FormatException {
      // Ignore malformed advertisements.
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _discovery?.stop();
    _discovery = null;
    await _broadcast?.stop();
    _broadcast = null;
    _devices.clear();
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    // mDNS caches are refreshed by the OS; restarting the browse forces it.
    if (_discovery == null) return;
    await stop();
    await start();
  }

  @override
  Future<void> announce() async {
    final info = localInfo();
    if (_broadcast == null) return;
    if (info.port == _advertisedPort && info.name == _advertisedName) return;
    await _broadcast?.stop();
    await _startBroadcast();
  }
}
