import 'dart:io';

/// Local network helpers.
abstract final class NetworkService {
  static const _virtualPrefixes = [
    'docker',
    'veth',
    'br-',
    'vmnet',
    'vboxnet',
    'virbr',
    'utun',
    'tun',
    'tap',
    'zt',
    'tailscale',
    'wg',
    'awdl',
    'llw',
    'ipsec',
    'rmnet',
    'vethernet',
    'hyper-v',
    'loopback',
  ];

  static bool _isVirtual(String name) {
    final n = name.toLowerCase();
    return _virtualPrefixes.any(n.startsWith) || n.contains('virtual');
  }

  static bool isPrivateIPv4(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.contains(null)) return false;
    final a = p[0]!, b = p[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127); // CGNAT / hotspot ranges
  }

  /// IPv4 interfaces likely to be a LAN, best candidates first.
  static Future<List<NetworkInterface>> lanInterfaces() async {
    final all = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final usable = all.where((i) => i.addresses.isNotEmpty).toList();
    int score(NetworkInterface i) {
      final n = i.name.toLowerCase();
      var s = 0;
      if (_isVirtual(n)) s += 100;
      if (!i.addresses.any((a) => isPrivateIPv4(a.address))) s += 50;
      if (n.startsWith('wl') ||
          n.startsWith('wi-fi') ||
          n.startsWith('en') ||
          n.startsWith('eth') ||
          n.startsWith('wlan'))
        s -= 10;
      return s;
    }

    usable.sort((a, b) => score(a).compareTo(score(b)));
    return usable;
  }

  /// Local IPv4 addresses to advertise (e.g. in the pairing QR code).
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final i in await lanInterfaces()) {
      for (final a in i.addresses) {
        if (!out.contains(a.address)) out.add(a.address);
      }
    }
    return out;
  }

  /// Parses "host:port", "host" (default port) or "[v6]:port".
  static (String, int)? parseHostPort(String input, int defaultPort) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final v6 = RegExp(r'^\[([0-9a-fA-F:.]+)\](?::(\d+))?$').firstMatch(s);
    if (v6 != null) {
      final port = v6.group(2) == null
          ? defaultPort
          : int.tryParse(v6.group(2)!);
      return (port == null || port < 1 || port > 65535)
          ? null
          : (v6.group(1)!, port);
    }
    final parts = s.split(':');
    if (parts.length > 2) return (s, defaultPort); // bare IPv6
    final host = parts[0];
    if (!RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(host)) return null;
    if (parts.length == 1) return (host, defaultPort);
    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) return null;
    return (host, port);
  }
}
