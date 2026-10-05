import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/device_info.dart';
import '../networking/network_service.dart';
import '../protocol/protocol.dart';
import 'discovery_service.dart';

/// Encodes/decodes discovery datagrams (PROTOCOL.md §1).
abstract final class DiscoveryPacket {
  static Uint8List encode(String type, DeviceInfo info) => utf8.encode(
    jsonEncode({
      'proto': Protocol.name,
      'v': Protocol.version,
      'type': type,
      ...info.toJson(),
    }),
  );

  /// Returns (type, info) or null for anything that isn't a valid packet.
  static (String, DeviceInfo)? decode(List<int> data) {
    if (data.length > 2048) return null;
    try {
      final json = jsonDecode(utf8.decode(data));
      if (json is! Map || json['proto'] != Protocol.name || json['v'] != Protocol.version) {
        return null;
      }
      final type = json['type'];
      if (type is! String || !const {'announce', 'query', 'bye'}.contains(type)) {
        return null;
      }
      return (type, DeviceInfo.fromJson(json.cast()));
    } catch (_) {
      return null;
    }
  }
}

/// UDP multicast + broadcast discovery. Works offline on any LAN that does
/// not filter multicast/broadcast between clients.
class UdpMulticastDiscovery extends DeviceDiscoveryService {
  UdpMulticastDiscovery({
    required this.localInfo,
    this.port = Protocol.discoveryPort,
    this.group = Protocol.multicastGroup,
    this.announceInterval = Protocol.announceInterval,
    this.deviceTimeout = Protocol.deviceTimeout,
    this.onBeforeStart,
    this.onAfterStop,
    this.enableBroadcast = true,
  });

  final DeviceInfo Function() localInfo;
  final int port;
  final String group;
  final Duration announceInterval;
  final Duration deviceTimeout;
  final bool enableBroadcast;

  /// Platform hooks (Android acquires a Wi-Fi multicast lock).
  final Future<void> Function()? onBeforeStart;
  final Future<void> Function()? onAfterStop;

  RawDatagramSocket? _listener;
  final List<RawDatagramSocket> _senders = [];
  final Map<String, DiscoveredDevice> _devices = {};
  Timer? _announceTimer;
  Timer? _expiryTimer;

  @override
  List<DiscoveredDevice> get devices => _devices.values.toList()
    ..sort((a, b) => a.info.name.toLowerCase().compareTo(b.info.name.toLowerCase()));

  @override
  bool get isRunning => _listener != null;

  @override
  Future<void> start() async {
    if (_listener != null) return;
    await onBeforeStart?.call();
    final groupAddress = InternetAddress(group);
    final listener = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: !Platform.isWindows && !Platform.isAndroid,
    );
    listener.broadcastEnabled = true;
    listener.multicastLoopback = true;
    final interfaces = await NetworkService.lanInterfaces();
    var joined = false;
    for (final iface in interfaces) {
      try {
        listener.joinMulticast(groupAddress, iface);
        joined = true;
      } catch (_) {}
    }
    if (!joined) {
      try {
        listener.joinMulticast(groupAddress);
      } catch (_) {}
    }
    listener.listen((event) {
      if (event == RawSocketEvent.read) {
        Datagram? d;
        while ((d = listener.receive()) != null) {
          _onDatagram(d!);
        }
      }
    });
    _listener = listener;

    // One sender per interface so announcements reach every LAN this device
    // is on (Wi-Fi + Ethernet, hotspot, …).
    for (final iface in interfaces) {
      final addr = iface.addresses.first;
      try {
        final s = await RawDatagramSocket.bind(addr, 0);
        s.broadcastEnabled = true;
        s.multicastLoopback = true;
        try {
          s.setRawOption(RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            addr.rawAddress,
          ));
        } catch (_) {}
        s.listen((e) {
          if (e == RawSocketEvent.read) {
            Datagram? d;
            while ((d = s.receive()) != null) {
              _onDatagram(d!);
            }
          }
        });
        _senders.add(s);
      } catch (_) {}
    }

    _announceTimer = Timer.periodic(announceInterval, (_) => announce());
    _expiryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _expire());
    await refresh();
    await announce();
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    if (_listener == null) return;
    _send('bye');
    _announceTimer?.cancel();
    _expiryTimer?.cancel();
    _listener?.close();
    _listener = null;
    for (final s in _senders) {
      s.close();
    }
    _senders.clear();
    _devices.clear();
    await onAfterStop?.call();
    notifyListeners();
  }

  @override
  Future<void> refresh() async => _send('query');

  @override
  Future<void> announce() async => _send('announce');

  void _send(String type, [InternetAddress? to]) {
    final data = DiscoveryPacket.encode(type, localInfo());
    final targets = to != null
        ? [to]
        : [InternetAddress(group), if (enableBroadcast) InternetAddress('255.255.255.255')];
    final sockets = _senders.isNotEmpty ? _senders : [?_listener];
    for (final s in sockets) {
      for (final t in targets) {
        try {
          s.send(data, t, port);
        } catch (_) {}
      }
    }
  }

  void _onDatagram(Datagram d) {
    final parsed = DiscoveryPacket.decode(d.data);
    if (parsed == null) return;
    final (type, info) = parsed;
    if (info.id == localInfo().id) return;
    final address = d.address.address;
    switch (type) {
      case 'bye':
        if (_devices.remove(info.id) != null) notifyListeners();
      case 'query':
        _upsert(info, address);
        // Reply directly so the querier learns about us immediately.
        final reply = DiscoveryPacket.encode('announce', localInfo());
        try {
          (_listener)?.send(reply, d.address, port);
        } catch (_) {}
      case 'announce':
        _upsert(info, address);
    }
  }

  void _upsert(DeviceInfo info, String address) {
    final existing = _devices[info.id];
    final now = DateTime.now();
    if (existing == null) {
      _devices[info.id] = DiscoveredDevice(info: info, address: address, lastSeen: now);
      notifyListeners();
    } else {
      final changed = existing.address != address ||
          existing.info.name != info.name ||
          existing.info.port != info.port;
      existing
        ..info = info
        ..address = address
        ..lastSeen = now;
      if (changed) notifyListeners();
    }
  }

  void _expire() {
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere((_, d) => now.difference(d.lastSeen) > deviceTimeout);
    if (_devices.length != before) notifyListeners();
  }
}
