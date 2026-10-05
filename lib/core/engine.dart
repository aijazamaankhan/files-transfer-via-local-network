import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'destinations/destination_manager.dart';
import 'discovery/discovery_service.dart';
import 'discovery/udp_multicast_discovery.dart';
import 'models/device_info.dart';
import 'models/history_record.dart';
import 'models/settings.dart';
import 'models/transfer_models.dart';
import 'models/trusted_device.dart';
import 'networking/lan_server.dart';
import 'networking/network_service.dart';
import 'networking/peer_client.dart';
import 'security/auth_service.dart';
import 'security/device_identity.dart';
import 'security/pairing_service.dart';
import 'storage/json_store.dart';
import 'storage/stores.dart';
import 'transfer/checksum.dart';
import 'transfer/file_scanner.dart';
import 'transfer/file_source.dart';
import 'transfer/transfer_receiver.dart';
import 'transfer/transfer_service.dart';
import 'transfer/transfer_task.dart';
import 'util/errors.dart';
import 'util/notifier.dart';

/// Static configuration for [LanBeamEngine].
class EngineConfig {
  const EngineConfig({
    required this.dataDirectory,
    required this.defaultSettings,
    required this.deviceType,
    this.enableDiscovery = true,
    this.useIsolateChecksums = true,
    this.bindAddress,
    this.discoveryFactory,
    this.onDiscoveryStart,
    this.onDiscoveryStop,
    this.sourceRegistry,
  });

  /// App-private directory for identity, settings, history and resume state.
  final String dataDirectory;
  final AppSettings defaultSettings;
  final DeviceType deviceType;
  final bool enableDiscovery;
  final bool useIsolateChecksums;

  /// Restrict the server to one address (tests use loopback).
  final InternetAddress? bindAddress;

  final DeviceDiscoveryService Function(DeviceInfo Function() localInfo)? discoveryFactory;
  final Future<void> Function()? onDiscoveryStart;
  final Future<void> Function()? onDiscoveryStop;
  final FileSourceRegistry? sourceRegistry;
}

/// Facade that wires every core service together. The UI talks only to this.
class LanBeamEngine extends Notifier {
  LanBeamEngine(this.config);

  final EngineConfig config;

  late final DeviceIdentity identity;
  late final SettingsStore settings;
  late final TrustedDeviceStore trustedDevices;
  late final TransferHistoryService history;
  late final ChecksumService checksums;
  late final DestinationManager destinations;
  late final AuthenticationService auth;
  late final PairingService pairing;
  late final TransferReceiver receiver;
  late final LanServer server;
  late final FileSourceRegistry sources;
  DeviceDiscoveryService? discovery;

  final TransferQueue _queue = TransferQueue();
  final Map<String, OutgoingTransfer> _outgoing = {};
  final Map<String, PeerClient> _clients = {};
  final _scanner = FileScanner();
  final List<StreamSubscription> _subs = [];
  bool _started = false;

  bool get isStarted => _started;

  DeviceInfo get localInfo => DeviceInfo(
    id: identity.deviceId,
    name: settings.value.deviceName,
    deviceType: config.deviceType,
    os: DeviceOs.current,
    port: server.port == 0 ? settings.value.servicePort : server.port,
    fingerprint: identity.fingerprint,
  );

  /// All transfers, newest first.
  List<TransferTask> get transfers {
    final all = <TransferTask>[..._outgoing.values, ...receiver.transfers];
    all.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return all;
  }

  List<OutgoingTransfer> get outgoing => _outgoing.values.toList();

  Future<void> start() async {
    final dir = config.dataDirectory;
    identity = await DeviceIdentity.loadOrCreate(dir);
    settings = SettingsStore(JsonFileStore(p.join(dir, 'settings.json')), config.defaultSettings);
    trustedDevices = TrustedDeviceStore(JsonFileStore(p.join(dir, 'trusted_devices.json'), sensitive: true));
    history = TransferHistoryService(JsonFileStore(p.join(dir, 'history.json')));
    await Future.wait([settings.load(), trustedDevices.load(), history.load()]);

    sources = config.sourceRegistry ?? FileSourceRegistry();
    checksums = config.useIsolateChecksums
        ? await IsolateChecksumService.spawn()
        : InlineChecksumService();
    destinations = DestinationManager();
    auth = AuthenticationService(localDeviceId: identity.deviceId, trustedDevices: trustedDevices);
    pairing = PairingService(
      localFingerprint: identity.fingerprint,
      trustedDevices: trustedDevices,
      onPaired: (_) => notifyListeners(),
    )..requireApprovalForQr = settings.value.requireApprovalForQr;
    receiver = TransferReceiver(
      settings: () => settings.value,
      trustedDevices: trustedDevices,
      destinations: destinations,
      checksums: checksums,
      history: history,
      inboxDirectory: p.join(dir, 'inbox'),
    );
    await receiver.loadInbox();
    _subs.add(receiver.added.listen((_) => notifyListeners()));
    _subs.add(receiver.finished.listen((_) => notifyListeners()));

    server = LanServer(
      identity: identity,
      localInfo: () => localInfo,
      pairing: pairing,
      auth: auth,
      receiver: receiver,
      onPeerSeen: (id, address) => trustedDevices.touch(id, addresses: [address]),
      onPeerRevoked: (id) async {
        _clients.remove(id)?.close();
        await trustedDevices.remove(id);
        notifyListeners();
      },
    );
    await server.start(
      preferredPort: settings.value.servicePort,
      address: config.bindAddress,
    );

    if (config.enableDiscovery && settings.value.discoveryEnabled) {
      await _startDiscovery();
    }
    _started = true;
    notifyListeners();
  }

  Future<void> _startDiscovery() async {
    final d = discovery ??= config.discoveryFactory?.call(() => localInfo) ??
        UdpMulticastDiscovery(
          localInfo: () => localInfo,
          onBeforeStart: config.onDiscoveryStart,
          onAfterStop: config.onDiscoveryStop,
        );
    d.addListener(_onDiscoveryChanged);
    try {
      await d.start();
    } catch (_) {
      // Discovery is best-effort (e.g. port in use, no network); manual IP
      // connection still works.
    }
  }

  void _onDiscoveryChanged() {
    final d = discovery;
    if (d == null) return;
    for (final dev in d.devices) {
      final trusted = trustedDevices.get(dev.id);
      if (trusted != null && trusted.fingerprint == dev.info.fingerprint) {
        final client = _clients[dev.id];
        if (client != null) {
          client.hosts = _hostsFor(trusted);
          client.port = dev.info.port;
        }
      }
    }
    notifyListeners();
  }

  /// Applies a settings change, restarting services where needed.
  Future<void> updateSettings(AppSettings Function(AppSettings) change) async {
    final before = settings.value;
    await settings.update(change);
    final after = settings.value;
    pairing.requireApprovalForQr = after.requireApprovalForQr;
    if (before.servicePort != after.servicePort) {
      await server.stop();
      await server.start(preferredPort: after.servicePort, address: config.bindAddress);
    }
    if (config.enableDiscovery && before.discoveryEnabled != after.discoveryEnabled) {
      if (after.discoveryEnabled) {
        await _startDiscovery();
      } else {
        await discovery?.stop();
      }
    } else if (before.deviceName != after.deviceName || before.servicePort != after.servicePort) {
      await discovery?.announce();
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // Pairing

  /// Creates a fresh QR pairing code for this device.
  Future<QrPairingPayload> createQrPayload() async {
    final token = pairing.createQrToken(Duration(minutes: settings.value.qrTokenTtlMinutes));
    final addresses = await NetworkService.localAddresses();
    return QrPairingPayload(
      deviceId: identity.deviceId,
      name: settings.value.deviceName,
      addresses: addresses.isEmpty ? ['127.0.0.1'] : addresses,
      port: server.port,
      fingerprint: identity.fingerprint,
      token: token.token,
    );
  }

  /// Pairs with the device described by a scanned QR code.
  Future<TrustedDevice> pairWithQr(QrPairingPayload payload) async {
    final client = PeerClient(
      hosts: payload.addresses,
      port: payload.port,
      expectedFingerprint: payload.fingerprint,
      localInfo: () => localInfo,
    );
    try {
      final result = await client.pairWithToken(payload.token);
      return await _storePairing(result, client);
    } catch (e) {
      client.close();
      throw classifyError(e);
    }
  }

  /// Step 1 of PIN pairing: asks [host]:[port] (fingerprint [fingerprint],
  /// from discovery or a direct-IP probe) to display a PIN.
  Future<PinPairingSession> startPinPairing(String host, int port, String fingerprint) async {
    final client = PeerClient(
      hosts: [host],
      port: port,
      expectedFingerprint: fingerprint,
      localInfo: () => localInfo,
    );
    try {
      final nonce = await client.requestPin();
      return PinPairingSession._(this, client, nonce);
    } on PeerApiException catch (e) {
      client.close();
      throw e.toLanBeam();
    } catch (e) {
      client.close();
      throw classifyError(e);
    }
  }

  Future<TrustedDevice> _storePairing(PairingResult result, PeerClient client) async {
    final active = client.activeHost;
    final trusted = TrustedDevice(
      info: result.device,
      secret: result.secret,
      pairedAt: DateTime.now(),
      lastAddresses: [?active, ...client.hosts.where((h) => h != active)],
    );
    await trustedDevices.put(trusted);
    _clients[trusted.id]?.close();
    client.secret = result.secret;
    _clients[trusted.id] = client;
    notifyListeners();
    return trusted;
  }

  /// Probes a manually entered address (direct IP).
  Future<DeviceInfo> probe(String host, int port) async {
    final (info, _) = await PeerClient.probe(host, port);
    return info;
  }

  /// Removes a paired device on both sides (remote side best effort).
  Future<void> unpair(String deviceId) async {
    final client = _clients.remove(deviceId) ?? _clientFor(deviceId);
    try {
      await client?.revoke().timeout(const Duration(seconds: 4));
    } catch (_) {}
    client?.close();
    auth.revokeDevice(deviceId);
    await trustedDevices.remove(deviceId);
    notifyListeners();
  }

  Future<void> setDeviceAutoAccept(String deviceId, bool? value) async {
    final d = trustedDevices.get(deviceId);
    if (d == null) return;
    d.autoAccept = value;
    await trustedDevices.put(d);
  }

  // -------------------------------------------------------------------
  // Sending

  List<String> _hostsFor(TrustedDevice d) {
    final discovered = discovery?.find(d.id);
    final hosts = <String>[];
    if (discovered != null && discovered.info.fingerprint == d.fingerprint) {
      hosts.add(discovered.address);
    }
    for (final h in d.lastAddresses) {
      if (!hosts.contains(h)) hosts.add(h);
    }
    return hosts;
  }

  PeerClient? _clientFor(String deviceId) {
    final d = trustedDevices.get(deviceId);
    if (d == null) return null;
    final existing = _clients[deviceId];
    final discovered = discovery?.find(deviceId);
    final port = (discovered != null && discovered.info.fingerprint == d.fingerprint)
        ? discovered.info.port
        : d.info.port;
    if (existing != null) {
      existing.hosts = _hostsFor(d);
      existing.port = port;
      return existing;
    }
    final c = PeerClient(
      hosts: _hostsFor(d),
      port: port,
      expectedFingerprint: d.fingerprint,
      localInfo: () => localInfo,
      secret: d.secret,
    );
    _clients[deviceId] = c;
    return c;
  }

  /// Scans [selections] and starts sending them to a paired device.
  Future<OutgoingTransfer> send(String deviceId, List<SendSelection> selections) async {
    final scan = await _scanner.scan(selections);
    if (scan.files.isEmpty) {
      throw const LanBeamException(FailureKind.fileMissing, 'Nothing to send');
    }
    return sendScanned(deviceId, scan);
  }

  Future<OutgoingTransfer> sendScanned(String deviceId, ScanResult scan, {String? transferId}) async {
    final trusted = trustedDevices.get(deviceId);
    final client = _clientFor(deviceId);
    if (trusted == null || client == null) {
      throw const LanBeamException(FailureKind.unauthorized);
    }
    final t = buildOutgoing(
      transferId: transferId ?? const Uuid().v4(),
      scan: scan,
      peer: trusted.info,
      client: client,
      checksums: checksums,
      concurrency: settings.value.maxConcurrentFiles,
      resolveHosts: () async => _hostsFor(trustedDevices.get(deviceId) ?? trusted),
      onSettled: _onOutgoingSettled,
    );
    _register(t);
    return t;
  }

  void _register(OutgoingTransfer t) {
    _outgoing[t.id] = t;
    unawaited(history.record(t.toHistory(resumable: true, resumeData: t.resumeData())));
    _queue.enqueue(t);
    notifyListeners();
  }

  void _onOutgoingSettled(OutgoingTransfer t) {
    final resumable = t.status == TransferStatus.failed || t.status == TransferStatus.paused;
    unawaited(history.record(t.toHistory(
      resumable: resumable,
      resumeData: resumable ? t.resumeData() : null,
    )));
    notifyListeners();
  }

  /// Re-creates and resumes an outgoing transfer from a history record
  /// (e.g. after the app was restarted mid-transfer).
  Future<OutgoingTransfer> resumeFromHistory(HistoryRecord record) async {
    final live = _outgoing[record.transferId];
    if (live != null) {
      if (live.status == TransferStatus.failed) unawaited(live.retry());
      if (live.status == TransferStatus.paused) live.resume();
      return live;
    }
    final data = record.resumeData;
    if (data == null) throw const LanBeamException(FailureKind.fileMissing, 'no resume data');
    final manifest = TransferManifest.fromJson((data['manifest'] as Map).cast());
    final rawSources = (data['sources'] as Map).cast<String, Object?>();
    final files = <OutgoingFile>[];
    for (final f in manifest.files) {
      final src = sources.fromJson((rawSources[f.id] as Map).cast());
      if (src == null) throw const LanBeamException(FailureKind.fileMissing);
      files.add(OutgoingFile(id: f.id, relativePath: f.path, source: src, size: f.size, modified: f.modified, mime: f.mime));
    }
    return sendScanned(record.peerId, ScanResult(files, manifest.kind), transferId: manifest.transferId);
  }

  OutgoingTransfer? outgoingById(String id) => _outgoing[id];

  /// Removes a finished transfer from the active list (stays in history).
  void dismiss(String transferId) {
    final o = _outgoing[transferId];
    if (o != null && !o.isRunning) {
      _outgoing.remove(transferId);
      _queue.remove(o);
    }
    receiver.dismiss(transferId);
    notifyListeners();
  }

  void pauseTransfer(TransferTask t) => t is OutgoingTransfer ? t.pause() : receiver.pause(t.id);
  void resumeTransfer(TransferTask t) {
    if (t is OutgoingTransfer) {
      t.status == TransferStatus.failed ? unawaited(t.retry()) : t.resume();
    } else {
      receiver.resume(t.id);
    }
  }

  Future<void> cancelTransfer(TransferTask t) =>
      t is OutgoingTransfer ? t.cancel() : receiver.cancel(t.id);

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    discovery?.removeListener(_onDiscoveryChanged);
    await discovery?.stop();
    for (final t in _outgoing.values) {
      if (t.isRunning) t.pause();
    }
    await server.stop();
    await receiver.dispose();
    pairing.dispose();
    for (final c in _clients.values) {
      c.close();
    }
    await checksums.dispose();
    await Future.wait([settings.flush(), trustedDevices.flush(), history.flush()]);
  }
}

/// In-progress PIN pairing (after the remote device displays its PIN).
class PinPairingSession {
  PinPairingSession._(this._engine, this._client, this._nonce);
  final LanBeamEngine _engine;
  final PeerClient _client;
  final String _nonce;

  Future<TrustedDevice> submit(String pin) async {
    try {
      final result = await _client.pairWithPin(_nonce, pin.trim());
      return await _engine._storePairing(result, _client);
    } catch (e) {
      throw classifyError(e);
    }
  }

  void cancel() => _client.close();
}
