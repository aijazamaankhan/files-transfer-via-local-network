/// Wire-level constants for LanBeam protocol v1. See docs/PROTOCOL.md.
library;

abstract final class Protocol {
  static const String name = 'lanbeam';
  static const int version = 1;
  static const String transferProtocolId = 'lanbeam-https/1';

  static const String appVersion = '1.0.0';

  /// UDP discovery.
  static const String multicastGroup = '224.0.0.179';
  static const int discoveryPort = 45871;

  /// Preferred TCP port for the HTTPS service.
  static const int defaultServicePort = 45872;

  static const String apiBase = '/api/v1';

  static const Duration announceInterval = Duration(seconds: 15);
  static const Duration deviceTimeout = Duration(seconds: 45);

  static const Duration qrTokenDefaultTtl = Duration(minutes: 5);
  static const Duration pinTtl = Duration(minutes: 2);
  static const int pinMaxAttempts = 5;
  static const Duration pairingApprovalTimeout = Duration(seconds: 120);

  static const Duration authNonceTtl = Duration(seconds: 30);
  static const Duration sessionTokenTtl = Duration(hours: 1);

  /// Checksum block size. Resume points are always multiples of this.
  static const int blockSize = 16 * 1024 * 1024;

  /// I/O chunk size for reads and coalesced writes.
  static const int ioChunkSize = 1024 * 1024;

  static const int maxManifestFiles = 100000;
  static const int maxManifestBytes = 16 * 1024 * 1024;
  static const int maxJsonBodyBytes = 1024 * 1024;
  static const int maxPathDepth = 64;
}

/// Error codes returned in `{"error": code}` bodies.
abstract final class ErrorCodes {
  static const badRequest = 'bad_request';
  static const unauthorized = 'unauthorized';
  static const forbidden = 'forbidden';
  static const notFound = 'not_found';
  static const offsetMismatch = 'offset_mismatch';
  static const gone = 'gone';
  static const checksumMismatch = 'checksum_mismatch';
  static const paused = 'paused';
  static const rateLimited = 'rate_limited';
  static const diskFull = 'disk_full';
  static const timeout = 'timeout';
  static const rejected = 'rejected';
  static const internal = 'internal';

  static int httpStatus(String code) => switch (code) {
    badRequest => 400,
    unauthorized => 401,
    forbidden || rejected => 403,
    notFound => 404,
    timeout => 408,
    offsetMismatch => 409,
    gone => 410,
    checksumMismatch => 422,
    paused => 423,
    rateLimited => 429,
    diskFull => 507,
    _ => 500,
  };
}
