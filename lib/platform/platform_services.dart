import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path_provider/path_provider.dart';

import '../core/platform_interfaces.dart';
import '../core/transfer/file_scanner.dart';
import 'android_bridge.dart';

bool get isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;
bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// File and folder selection using native pickers.
class FilePickerService {
  const FilePickerService();

  /// Lets the user choose files to send. Returns null when cancelled.
  Future<List<SendSelection>?> pickFiles() async {
    if (Platform.isAndroid) return AndroidBridge.instance.pickFiles();
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      lockParentWindow: true,
    );
    if (result == null) return null;
    return [
      for (final f in result.files)
        if (f.path != null) LocalPathSelection(f.path!),
    ];
  }

  /// Lets the user choose a folder to send recursively.
  Future<List<SendSelection>?> pickFolder() async {
    if (Platform.isAndroid) {
      final tree = await AndroidBridge.instance.pickTree();
      return tree == null ? null : [tree];
    }
    final dir = await FilePicker.getDirectoryPath(lockParentWindow: true);
    return dir == null ? null : [LocalPathSelection(dir)];
  }

  /// Native folder chooser for destination folders.
  Future<String?> chooseDirectory({String? initial, String? title}) =>
      FilePicker.getDirectoryPath(
        initialDirectory: initial,
        dialogTitle: title,
        lockParentWindow: true,
      );
}

/// Platform notifications via flutter_local_notifications.
class LocalNotificationService implements NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool enabled = true;

  @override
  Future<void> init() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'LanBeam',
          appUserModelId: 'com.lanbeam.LanBeam',
          guid: '6b0f3e7a-9a51-4f6e-8a2b-6c7d1f0e2a11',
        ),
      );
      _ready = await _plugin.initialize(settings: settings) ?? false;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
      _ready = false;
    }
  }

  /// Asks for permission on platforms that require it (Android 13+, Apple).
  Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true);
    } catch (_) {}
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_ready || !enabled) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'lanbeam_events',
            'Transfers',
            channelDescription: 'Incoming requests and completed transfers',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Notification failed: $e');
    }
  }
}

/// Runtime permissions. Only what is needed, only when needed.
///
/// The camera permission is requested by the QR scanner plugin itself when
/// it starts; notifications by [LocalNotificationService]. The only other
/// runtime permission is storage on Android 9–10, handled natively.
class PermissionService {
  const PermissionService();

  /// Storage write access for saving into Download/ on Android 9–10 only.
  Future<bool> ensureLegacyStorage() async {
    if (!Platform.isAndroid) return true;
    try {
      return await AndroidBridge.instance.requestLegacyStorage();
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's page in the system settings (mobile).
  Future<void> openSettings() async {
    if (Platform.isAndroid) await AndroidBridge.instance.openAppSettings();
  }
}

/// Launch-at-login for desktop platforms.
class StartupService {
  bool _configured = false;

  bool get supported => isDesktop;

  void _setup() {
    if (_configured) return;
    launchAtStartup.setup(
      appName: 'LanBeam',
      appPath: Platform.resolvedExecutable,
      packageName: 'com.lanbeam.lanbeam',
    );
    _configured = true;
  }

  Future<void> apply(bool enabled) async {
    if (!supported) return;
    try {
      _setup();
      enabled
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
    } catch (e) {
      debugPrint('Launch at startup failed: $e');
    }
  }
}

/// Default storage locations per platform.
abstract final class AppPaths {
  static Future<String> dataDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  /// Where received files go by default.
  static Future<String> defaultDownloads() async {
    if (Platform.isAndroid) {
      final dl = await AndroidBridge.instance.downloadsDirectory();
      if (dl != null) return '$dl${Platform.pathSeparator}LanBeam';
    }
    if (Platform.isIOS) {
      // Exposed in the Files app via UIFileSharingEnabled.
      final docs = await getApplicationDocumentsDirectory();
      return '${docs.path}${Platform.pathSeparator}Received';
    }
    // Desktop: ~/Downloads/LanBeam, falling back gracefully when the user
    // directories are not configured (e.g. minimal Linux installs).
    String? base;
    try {
      base = (await getDownloadsDirectory())?.path;
    } catch (_) {}
    if (base == null) {
      try {
        base = (await getApplicationDocumentsDirectory()).path;
      } catch (_) {}
    }
    base ??=
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    base ??= await dataDirectory();
    return '$base${Platform.pathSeparator}LanBeam';
  }
}

/// Opens a folder in the system file manager (never runs received files).
Future<void> revealInFileManager(String path) async {
  try {
    final dir = await FileSystemEntity.isDirectory(path)
        ? path
        : File(path).parent.path;
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [dir]);
    } else if (Platform.isMacOS) {
      // -R reveals in Finder; plain `open` would launch an .app bundle.
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dir]);
    }
  } catch (e) {
    debugPrint('Cannot open folder: $e');
  }
}
