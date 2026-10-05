import 'dart:async';
import 'dart:io';

/// Categories of failures, each with a human-readable explanation.
enum FailureKind {
  deviceUnreachable(
    'The device could not be reached. Make sure both devices are on the same '
    'Wi-Fi network and LanBeam is open on the other device.',
  ),
  connectionLost(
    'The connection was interrupted. The transfer can be resumed.',
  ),
  timeout('The other device stopped responding.'),
  firewallBlocked(
    'The connection was refused. A firewall may be blocking LanBeam — allow it '
    'on private networks in your firewall settings.',
  ),
  untrustedCertificate(
    'The device identity did not match. Someone may be impersonating it, or it '
    'was reinstalled — remove and pair it again.',
  ),
  unauthorized('This device is not paired, or the pairing was removed.'),
  rejected('The other device declined.'),
  cancelled('The transfer was cancelled.'),
  permissionDenied(
    'Permission denied. LanBeam is not allowed to access this file or folder.',
  ),
  destinationUnavailable(
    'The destination folder is unavailable. It may have been removed or the '
    'drive disconnected.',
  ),
  diskFull('Not enough storage space on the receiving device.'),
  fileChanged('The file was modified while it was being sent. Send it again.'),
  fileMissing('The file no longer exists.'),
  checksumMismatch('The file was corrupted in transit and will be re-sent.'),
  pairingExpired('The pairing code has expired. Generate a new one.'),
  pairingFailed('Pairing failed. Check the code and try again.'),
  rateLimited('Too many attempts. Wait a minute and try again.'),
  protocol('The other device sent an unexpected response. Update both apps.'),
  bluetoothUnavailable('Bluetooth is not available on this device.'),
  unknown('Something went wrong.');

  const FailureKind(this.message);
  final String message;
}

class LanBeamException implements Exception {
  const LanBeamException(this.kind, [this.detail]);

  final FailureKind kind;

  /// Technical detail for logs (not shown as the primary message).
  final String? detail;

  String get userMessage => kind.message;

  bool get isRetryable => switch (kind) {
    FailureKind.deviceUnreachable ||
    FailureKind.connectionLost ||
    FailureKind.timeout ||
    FailureKind.checksumMismatch => true,
    _ => false,
  };

  @override
  String toString() =>
      'LanBeamException(${kind.name}${detail == null ? '' : ': $detail'})';
}

// errno values for disk-full and permission errors across platforms.
const _enospc = {
  28,
  112 /* ERROR_DISK_FULL */,
  39 /* ERROR_HANDLE_DISK_FULL */,
};
const _eacces = {13, 1 /* EPERM */, 5 /* ERROR_ACCESS_DENIED */};
const _enoent = {2, 3 /* ERROR_PATH_NOT_FOUND */};
const _econnrefused = {111, 61, 10061};

/// Converts arbitrary errors from I/O and networking into [LanBeamException].
LanBeamException classifyError(Object error) {
  if (error is LanBeamException) return error;
  if (error is TimeoutException) {
    return LanBeamException(FailureKind.timeout, error.toString());
  }
  if (error is HandshakeException || error is CertificateException) {
    return LanBeamException(FailureKind.untrustedCertificate, error.toString());
  }
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    if (code != null && _econnrefused.contains(code)) {
      return LanBeamException(FailureKind.firewallBlocked, error.toString());
    }
    if (error.message.contains('timed out')) {
      return LanBeamException(FailureKind.timeout, error.toString());
    }
    if (error.message.toLowerCase().contains('reset') ||
        error.message.toLowerCase().contains('closed')) {
      return LanBeamException(FailureKind.connectionLost, error.toString());
    }
    return LanBeamException(FailureKind.deviceUnreachable, error.toString());
  }
  if (error is HttpException || error is WebSocketException) {
    return LanBeamException(FailureKind.connectionLost, error.toString());
  }
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if (code != null && _enospc.contains(code)) {
      return LanBeamException(FailureKind.diskFull, error.toString());
    }
    if (code != null && _eacces.contains(code)) {
      return LanBeamException(FailureKind.permissionDenied, error.toString());
    }
    if (code != null && _enoent.contains(code)) {
      return LanBeamException(FailureKind.fileMissing, error.toString());
    }
    return LanBeamException(FailureKind.unknown, error.toString());
  }
  return LanBeamException(FailureKind.unknown, error.toString());
}
