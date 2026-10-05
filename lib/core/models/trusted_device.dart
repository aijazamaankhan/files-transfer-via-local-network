import 'dart:convert';
import 'dart:typed_data';

import 'device_info.dart';

/// A device we have paired with. Holds the shared secret used for
/// authentication and the pinned certificate fingerprint.
class TrustedDevice {
  TrustedDevice({
    required this.info,
    required this.secret,
    required this.pairedAt,
    List<String>? lastAddresses,
    this.lastSeen,
    this.autoAccept,
  }) : lastAddresses = lastAddresses ?? [];

  DeviceInfo info;
  final Uint8List secret;
  final DateTime pairedAt;
  List<String> lastAddresses;
  DateTime? lastSeen;

  /// Per-device override of the global auto-accept setting; null = inherit.
  bool? autoAccept;

  String get id => info.id;
  String get name => info.name;
  String get fingerprint => info.fingerprint;

  Map<String, Object?> toJson() => {
    'info': info.toJson(),
    'secret': base64.encode(secret),
    'pairedAt': pairedAt.toIso8601String(),
    'lastAddresses': lastAddresses,
    'lastSeen': lastSeen?.toIso8601String(),
    'autoAccept': autoAccept,
  };

  factory TrustedDevice.fromJson(Map<String, Object?> json) => TrustedDevice(
    info: DeviceInfo.fromJson((json['info'] as Map).cast<String, Object?>()),
    secret: base64.decode(json['secret'] as String),
    pairedAt: DateTime.parse(json['pairedAt'] as String),
    lastAddresses: (json['lastAddresses'] as List?)?.cast<String>() ?? [],
    lastSeen: json['lastSeen'] == null
        ? null
        : DateTime.parse(json['lastSeen'] as String),
    autoAccept: json['autoAccept'] as bool?,
  );
}
