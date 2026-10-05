import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/discovery/composite_discovery.dart';
import '../core/discovery/udp_multicast_discovery.dart';
import '../core/engine.dart';
import '../core/models/device_info.dart';
import '../core/models/settings.dart';
import '../core/models/transfer_models.dart';
import '../core/platform_interfaces.dart';
import '../core/security/pairing_service.dart';
import '../core/transfer/file_source.dart';
import '../core/transfer/transfer_receiver.dart';
import '../core/transfer/transfer_service.dart';
import '../core/transfer/transfer_task.dart';
import '../features/pairing/pairing_dialogs.dart';
import '../features/receive/incoming_request_dialog.dart';
import '../platform/android_bridge.dart';
import '../platform/bonjour_discovery.dart';
import '../platform/platform_services.dart';
import '../ui/format.dart';

/// Application-level glue between the core engine, platform services and
/// the widget tree (dialogs for incoming requests and pairing prompts,
/// notifications, Android foreground service).
class AppController extends ChangeNotifier {
  AppController._(this.engine, this.notifications);

  final LanBeamEngine engine;
  final LocalNotificationService notifications;
  final pickers = const FilePickerService();
  final permissions = const PermissionService();
  final startup = StartupService();
  final BluetoothService bluetooth = const UnsupportedBluetoothService();

  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// Selected tab in the root shell.
  final tab = ValueNotifier<int>(0);

  final List<StreamSubscription> _subs = [];
  final Set<TransferTask> _watched = {};
  bool _foregroundServiceRunning = false;
  Future<void> _dialogChain = Future.value();

  static Future<AppController> create() async {
    final dataDir = await AppPaths.dataDirectory();
    final downloads = await AppPaths.defaultDownloads();
    final deviceType = await _detectDeviceType();
    final name = await _defaultDeviceName();

    final registry = FileSourceRegistry()
      ..register('content', (j) => ContentUriFileSource(j['uri'] as String));

    final engine = LanBeamEngine(
      EngineConfig(
        dataDirectory: dataDir,
        deviceType: deviceType,
        sourceRegistry: registry,
        defaultSettings: AppSettings(
          deviceName: name,
          downloadDirectory: downloads,
          // Phones save straight to Downloads; desktops ask where by default.
          askWhereToSave: !deviceType.isMobile,
        ),
        discoveryFactory: (localInfo) => CompositeDiscovery([
          UdpMulticastDiscovery(
            localInfo: localInfo,
            onBeforeStart: AndroidBridge.instance.acquireMulticastLock,
            onAfterStop: AndroidBridge.instance.releaseMulticastLock,
          ),
          BonjourDiscovery(localInfo: localInfo),
        ]),
      ),
    );
    final notifications = LocalNotificationService();
    await notifications.init();
    await engine.start();
    final controller = AppController._(engine, notifications);
    controller._wire();
    return controller;
  }

  static Future<DeviceType> _detectDeviceType() async {
    if (Platform.isAndroid) {
      final info = await AndroidBridge.instance.deviceInfo();
      return info['isTablet'] == true ? DeviceType.tablet : DeviceType.phone;
    }
    if (Platform.isIOS) {
      final view = PlatformDispatcher.instance.views.firstOrNull;
      if (view != null) {
        final size = view.physicalSize / view.devicePixelRatio;
        if (size.shortestSide >= 600) return DeviceType.tablet;
      }
      return DeviceType.phone;
    }
    return DeviceType.desktop;
  }

  static Future<String> _defaultDeviceName() async {
    if (Platform.isAndroid) {
      final info = await AndroidBridge.instance.deviceInfo();
      final model = (info['model'] as String?) ?? 'Android';
      final maker = (info['manufacturer'] as String?) ?? '';
      final full = model.toLowerCase().startsWith(maker.toLowerCase())
          ? model
          : '$maker $model';
      return sanitizeDisplayName(
        full.trim().isEmpty ? 'Android phone' : full.trim(),
      );
    }
    if (Platform.isIOS) return 'iPhone';
    final host = Platform.localHostname.split('.').first;
    return sanitizeDisplayName(host.isEmpty ? 'My computer' : host);
  }

  AppSettings get settings => engine.settings.value;

  void _wire() {
    engine.addListener(_onEngineChanged);
    notifications.enabled = settings.notificationsEnabled;
    _subs.add(engine.receiver.requests.listen(_onIncomingRequest));
    _subs.add(engine.pairing.prompts.listen(_onPairingPrompt));
    _subs.add(engine.receiver.finished.listen(_onIncomingFinished));
    if (settings.launchAtStartup) unawaited(startup.apply(true));
    _onEngineChanged();
  }

  void _onEngineChanged() {
    for (final t in engine.transfers) {
      if (_watched.add(t)) t.addListener(() => _onTaskChanged(t));
    }
    _updateForegroundService();
    notifyListeners();
  }

  void _onTaskChanged(TransferTask t) {
    _updateForegroundService();
    if (t is OutgoingTransfer &&
        !t.isRunning &&
        (t.status.isFinal || t.status == TransferStatus.failed) &&
        _reported.add('${t.id}:${t.status.name}')) {
      _onOutgoingSettled(t);
    }
  }

  final Set<String> _reported = {};

  /// Keeps the Android foreground service running while transfers are active.
  void _updateForegroundService() {
    final active = engine.transfers
        .where((t) => t.status == TransferStatus.active)
        .toList();
    if (active.isNotEmpty && !_foregroundServiceRunning) {
      _foregroundServiceRunning = true;
      final title = active.length == 1
          ? '${active.first.direction == TransferDirection.outgoing ? 'Sending' : 'Receiving'} ${active.first.title}'
          : '${active.length} transfers in progress';
      unawaited(
        AndroidBridge.instance.startTransferService(title).catchError((_) {}),
      );
    } else if (active.isEmpty && _foregroundServiceRunning) {
      _foregroundServiceRunning = false;
      unawaited(
        AndroidBridge.instance.stopTransferService().catchError((_) {}),
      );
    }
  }

  // -------------------------------------------------------------------
  // Dialog plumbing

  BuildContext? get _context => navigatorKey.currentContext;

  /// Shows dialogs one at a time, in order of arrival.
  Future<T?> _enqueueDialog<T>(Future<T?> Function(BuildContext) show) {
    final completer = Completer<T?>();
    _dialogChain = _dialogChain.then((_) async {
      final ctx = _context;
      if (ctx == null || !ctx.mounted) {
        completer.complete(null);
        return;
      }
      try {
        completer.complete(await show(ctx));
      } catch (e) {
        completer.completeError(e);
      }
    });
    return completer.future;
  }

  void toast(String message, {bool error = false}) {
    final m = messengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Colors.red.shade700 : null,
      ),
    );
  }

  void _onIncomingRequest(IncomingRequest request) {
    final t = request.task;
    unawaited(
      notifications.show(
        id: t.id.hashCode,
        title: '${t.peer.name} wants to send you files',
        body: '${t.title} · ${formatBytes(t.totalBytes)}',
      ),
    );
    _enqueueDialog<void>((ctx) async {
      if (t.status != TransferStatus.awaitingApproval) return;
      await showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) =>
            IncomingRequestDialog(controller: this, request: request),
      );
    });
  }

  PairingPinPrompt? _visiblePin;
  NavigatorState? _pinNavigator;

  void _onPairingPrompt(PairingPrompt prompt) {
    switch (prompt) {
      case PairingApprovalPrompt():
        unawaited(
          notifications.show(
            id: prompt.device.id.hashCode,
            title: 'Pairing request',
            body: '${prompt.device.name} wants to pair with this device',
          ),
        );
        _enqueueDialog<void>((ctx) async {
          if (prompt.isDecided) return;
          final approved = await showDialog<bool>(
            context: ctx,
            barrierDismissible: false,
            builder: (_) => PairingApprovalDialog(prompt: prompt),
          );
          prompt.respond(approved ?? false);
        });
      case PairingPinPrompt():
        _closePinDialog();
        final ctx = _context;
        if (ctx == null) return;
        _visiblePin = prompt;
        _pinNavigator = Navigator.of(ctx);
        unawaited(
          showDialog<void>(
            context: ctx,
            barrierDismissible: false,
            builder: (_) => PinDisplayDialog(
              prompt: prompt,
              onCancel: engine.pairing.cancelPinSession,
            ),
          ).whenComplete(() {
            if (identical(_visiblePin, prompt)) _visiblePin = null;
          }),
        );
      case PairingCompletedPrompt():
        _closePinDialog();
        toast('Paired with ${prompt.device.name}');
      case PairingCancelledPrompt():
        _closePinDialog();
    }
  }

  void _closePinDialog() {
    if (_visiblePin != null) {
      _visiblePin = null;
      _pinNavigator?.pop();
    }
    _pinNavigator = null;
  }

  void _onIncomingFinished(IncomingTransfer t) {
    if (t.status == TransferStatus.completed) {
      final saved = t.files.values
          .map((f) => f.savedPath)
          .whereType<String>()
          .toList();
      unawaited(AndroidBridge.instance.scanMedia(saved).catchError((_) {}));
      unawaited(
        notifications.show(
          id: t.id.hashCode,
          title: 'Received from ${t.peer.name}',
          body: '${t.title} · ${formatBytes(t.totalBytes)}',
        ),
      );
    }
  }

  void _onOutgoingSettled(OutgoingTransfer t) {
    if (t.status == TransferStatus.completed) {
      unawaited(
        notifications.show(
          id: t.id.hashCode,
          title: 'Sent to ${t.peer.name}',
          body: '${t.title} · ${formatBytes(t.totalBytes)}',
        ),
      );
    } else if (t.status == TransferStatus.failed ||
        t.status == TransferStatus.rejected) {
      unawaited(
        notifications.show(
          id: t.id.hashCode,
          title: t.status == TransferStatus.rejected
              ? '${t.peer.name} declined'
              : 'Transfer interrupted',
          body: t.error?.userMessage ?? t.title,
        ),
      );
    }
  }

  // -------------------------------------------------------------------
  // Actions used by the UI

  Future<void> updateSettings(AppSettings Function(AppSettings) change) async {
    final before = settings;
    await engine.updateSettings(change);
    notifications.enabled = settings.notificationsEnabled;
    if (before.launchAtStartup != settings.launchAtStartup) {
      await startup.apply(settings.launchAtStartup);
    }
    notifyListeners();
  }

  Future<void> requestStartupPermissions() async {
    await notifications.requestPermission();
    await permissions.ensureLegacyStorage();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    engine.removeListener(_onEngineChanged);
    unawaited(engine.dispose());
    super.dispose();
  }
}
