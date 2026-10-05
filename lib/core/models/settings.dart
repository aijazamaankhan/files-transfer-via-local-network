import '../destinations/file_category.dart';
import '../protocol/protocol.dart';

enum ConflictPolicy {
  ask,
  rename,
  replace,
  skip;

  static ConflictPolicy parse(Object? v) =>
      ConflictPolicy.values.firstWhere((e) => e.name == v, orElse: () => ask);
}

/// User preferences. Immutable; update with [copyWith].
class AppSettings {
  const AppSettings({
    required this.deviceName,
    required this.downloadDirectory,
    this.useDestinationRules = false,
    this.destinationRules = const {},
    this.askWhereToSave = true,
    this.autoAcceptTrusted = false,
    this.conflictPolicy = ConflictPolicy.ask,
    this.servicePort = Protocol.defaultServicePort,
    this.discoveryEnabled = true,
    this.qrTokenTtlMinutes = 5,
    this.requireApprovalForQr = true,
    this.notificationsEnabled = true,
    this.launchAtStartup = false,
    this.maxConcurrentFiles = 3,
    this.bluetoothEnabled = false,
    this.themeMode = 'system',
  });

  final String deviceName;
  final String downloadDirectory;

  /// When true, incoming files are routed by type without asking.
  final bool useDestinationRules;
  final Map<FileCategory, String> destinationRules;

  /// When rules are off: ask for a folder (true) or use [downloadDirectory].
  final bool askWhereToSave;

  final bool autoAcceptTrusted;
  final ConflictPolicy conflictPolicy;
  final int servicePort;
  final bool discoveryEnabled;
  final int qrTokenTtlMinutes;
  final bool requireApprovalForQr;
  final bool notificationsEnabled;
  final bool launchAtStartup;
  final int maxConcurrentFiles;
  final bool bluetoothEnabled;
  final String themeMode;

  AppSettings copyWith({
    String? deviceName,
    String? downloadDirectory,
    bool? useDestinationRules,
    Map<FileCategory, String>? destinationRules,
    bool? askWhereToSave,
    bool? autoAcceptTrusted,
    ConflictPolicy? conflictPolicy,
    int? servicePort,
    bool? discoveryEnabled,
    int? qrTokenTtlMinutes,
    bool? requireApprovalForQr,
    bool? notificationsEnabled,
    bool? launchAtStartup,
    int? maxConcurrentFiles,
    bool? bluetoothEnabled,
    String? themeMode,
  }) => AppSettings(
    deviceName: deviceName ?? this.deviceName,
    downloadDirectory: downloadDirectory ?? this.downloadDirectory,
    useDestinationRules: useDestinationRules ?? this.useDestinationRules,
    destinationRules: destinationRules ?? this.destinationRules,
    askWhereToSave: askWhereToSave ?? this.askWhereToSave,
    autoAcceptTrusted: autoAcceptTrusted ?? this.autoAcceptTrusted,
    conflictPolicy: conflictPolicy ?? this.conflictPolicy,
    servicePort: servicePort ?? this.servicePort,
    discoveryEnabled: discoveryEnabled ?? this.discoveryEnabled,
    qrTokenTtlMinutes: qrTokenTtlMinutes ?? this.qrTokenTtlMinutes,
    requireApprovalForQr: requireApprovalForQr ?? this.requireApprovalForQr,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    launchAtStartup: launchAtStartup ?? this.launchAtStartup,
    maxConcurrentFiles: maxConcurrentFiles ?? this.maxConcurrentFiles,
    bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
    themeMode: themeMode ?? this.themeMode,
  );

  Map<String, Object?> toJson() => {
    'deviceName': deviceName,
    'downloadDirectory': downloadDirectory,
    'useDestinationRules': useDestinationRules,
    'destinationRules': {
      for (final e in destinationRules.entries) e.key.name: e.value,
    },
    'askWhereToSave': askWhereToSave,
    'autoAcceptTrusted': autoAcceptTrusted,
    'conflictPolicy': conflictPolicy.name,
    'servicePort': servicePort,
    'discoveryEnabled': discoveryEnabled,
    'qrTokenTtlMinutes': qrTokenTtlMinutes,
    'requireApprovalForQr': requireApprovalForQr,
    'notificationsEnabled': notificationsEnabled,
    'launchAtStartup': launchAtStartup,
    'maxConcurrentFiles': maxConcurrentFiles,
    'bluetoothEnabled': bluetoothEnabled,
    'themeMode': themeMode,
  };

  factory AppSettings.fromJson(Map<String, Object?> j, AppSettings defaults) {
    T pick<T>(String key, T fallback) {
      final v = j[key];
      return v is T ? v : fallback;
    }

    final rules = <FileCategory, String>{};
    final rawRules = j['destinationRules'];
    if (rawRules is Map) {
      for (final e in rawRules.entries) {
        final cat = FileCategory.values
            .where((c) => c.name == e.key)
            .firstOrNull;
        if (cat != null && e.value is String) rules[cat] = e.value as String;
      }
    }
    return AppSettings(
      deviceName: pick('deviceName', defaults.deviceName),
      downloadDirectory: pick('downloadDirectory', defaults.downloadDirectory),
      useDestinationRules: pick(
        'useDestinationRules',
        defaults.useDestinationRules,
      ),
      destinationRules: rules.isEmpty ? defaults.destinationRules : rules,
      askWhereToSave: pick('askWhereToSave', defaults.askWhereToSave),
      autoAcceptTrusted: pick('autoAcceptTrusted', defaults.autoAcceptTrusted),
      conflictPolicy: ConflictPolicy.parse(j['conflictPolicy']),
      servicePort: pick('servicePort', defaults.servicePort).clamp(1024, 65535),
      discoveryEnabled: pick('discoveryEnabled', defaults.discoveryEnabled),
      qrTokenTtlMinutes: pick(
        'qrTokenTtlMinutes',
        defaults.qrTokenTtlMinutes,
      ).clamp(1, 30),
      requireApprovalForQr: pick(
        'requireApprovalForQr',
        defaults.requireApprovalForQr,
      ),
      notificationsEnabled: pick(
        'notificationsEnabled',
        defaults.notificationsEnabled,
      ),
      launchAtStartup: pick('launchAtStartup', defaults.launchAtStartup),
      maxConcurrentFiles: pick(
        'maxConcurrentFiles',
        defaults.maxConcurrentFiles,
      ).clamp(1, 8),
      bluetoothEnabled: pick('bluetoothEnabled', defaults.bluetoothEnabled),
      themeMode: pick('themeMode', defaults.themeMode),
    );
  }
}
