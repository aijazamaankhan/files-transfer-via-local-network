import 'dart:io';

import '../protocol/protocol.dart';

enum DeviceType {
  phone,
  tablet,
  desktop,
  laptop;

  static DeviceType parse(Object? v) => DeviceType.values.firstWhere(
    (e) => e.name == v,
    orElse: () => DeviceType.desktop,
  );

  bool get isMobile => this == phone || this == tablet;
}

enum DeviceOs {
  android,
  ios,
  windows,
  macos,
  linux,
  unknown;

  static DeviceOs parse(Object? v) =>
      DeviceOs.values.firstWhere((e) => e.name == v, orElse: () => unknown);

  static DeviceOs get current {
    if (Platform.isAndroid) return android;
    if (Platform.isIOS) return ios;
    if (Platform.isWindows) return windows;
    if (Platform.isMacOS) return macos;
    if (Platform.isLinux) return linux;
    return unknown;
  }

  String get label => switch (this) {
    android => 'Android',
    ios => 'iOS',
    windows => 'Windows',
    macos => 'macOS',
    linux => 'Linux',
    unknown => 'Unknown',
  };
}

/// Public description of a device, as advertised over discovery and `/info`.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.os,
    required this.port,
    required this.fingerprint,
    this.appVersion = Protocol.appVersion,
    this.protocols = const [Protocol.transferProtocolId],
  });

  final String id;
  final String name;
  final DeviceType deviceType;
  final DeviceOs os;
  final String appVersion;
  final List<String> protocols;
  final int port;

  /// SHA-256 fingerprint of the device's TLS certificate (lowercase hex).
  final String fingerprint;

  bool get supportsCurrentProtocol =>
      protocols.contains(Protocol.transferProtocolId);

  DeviceInfo copyWith({String? name, int? port}) => DeviceInfo(
    id: id,
    name: name ?? this.name,
    deviceType: deviceType,
    os: os,
    port: port ?? this.port,
    fingerprint: fingerprint,
    appVersion: appVersion,
    protocols: protocols,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'deviceType': deviceType.name,
    'os': os.name,
    'appVersion': appVersion,
    'protocols': protocols,
    'port': port,
    'fp': fingerprint,
  };

  /// Parses untrusted input. Throws [FormatException] if invalid.
  factory DeviceInfo.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final port = json['port'];
    final fp = json['fp'];
    if (id is! String || id.isEmpty || id.length > 64) {
      throw const FormatException('invalid device id');
    }
    if (name is! String || name.isEmpty) {
      throw const FormatException('invalid device name');
    }
    if (port is! int || port <= 0 || port > 65535) {
      throw const FormatException('invalid port');
    }
    if (fp is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) {
      throw const FormatException('invalid fingerprint');
    }
    final protocols = json['protocols'];
    return DeviceInfo(
      id: id,
      name: sanitizeDisplayName(name),
      deviceType: DeviceType.parse(json['deviceType']),
      os: DeviceOs.parse(json['os']),
      appVersion: (json['appVersion'] as String?) ?? 'unknown',
      protocols: protocols is List
          ? protocols.whereType<String>().take(16).toList()
          : const [],
      port: port,
      fingerprint: fp,
    );
  }

  @override
  String toString() => 'DeviceInfo($name, $id, ${os.name}, :$port)';
}

/// Strips control characters and clamps length of names received from peers.
String sanitizeDisplayName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (cleaned.isEmpty) return 'Unknown device';
  return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
}

/// Short, human-comparable form of a fingerprint, e.g. `3B9A-11F0-7C2E`.
String shortFingerprint(String fp) {
  final upper = fp.toUpperCase();
  if (upper.length < 12) return upper;
  return '${upper.substring(0, 4)}-${upper.substring(4, 8)}-${upper.substring(8, 12)}';
}
