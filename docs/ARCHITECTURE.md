# LanBeam — Architecture

LanBeam moves files and folders directly between devices on the same local
network. There is no cloud relay, no account and no Internet requirement:
two devices on the same Wi-Fi (even one with no upstream connection) are
enough.

This document covers the requirements analysis, the architecture, the main
technical decisions and the milestone plan. The wire protocol is specified in
[PROTOCOL.md](PROTOCOL.md), platform-specific constraints in
[PLATFORMS.md](PLATFORMS.md) and the threat model in [SECURITY.md](SECURITY.md).

---

## 1. Requirements analysis

| Area | What it really requires | Consequence for the design |
|------|-------------------------|----------------------------|
| Serverless / offline | Each device must *be* a server. Discovery cannot rely on DNS or the Internet. | Every device runs an embedded HTTPS server and a UDP multicast responder. |
| Five platforms | One codebase, but networking, file access and permissions differ wildly. | A pure-Dart **core** (only `dart:io`) holds all protocol and transfer logic; Flutter UI and platform adapters sit on top. |
| Security | A LAN is hostile (cafés, dorms, guest Wi-Fi). An open upload endpoint is a remote file-write primitive. | TLS with certificate pinning, explicit pairing, per-request authentication, per-transfer user authorization, strict path validation. |
| Multi-GB files, resume | Files never fit in RAM; Wi-Fi drops mid-transfer. | Streaming I/O with backpressure, block-level checksums persisted on disk so resume never re-hashes data. |
| Folders | Arbitrary trees from an untrusted sender. | Manifest of relative paths; every segment sanitized and re-validated against the destination root (including symlinks). |
| Consumer-grade UX | Progress, speed, ETA, pause/resume/cancel, history, notifications. | The engine exposes observable state (`ChangeNotifier`-friendly) and a typed event stream. |

## 2. High-level architecture

```
┌──────────────────────────────── Flutter app ────────────────────────────────┐
│  features/  (UI + controllers)                                             │
│   home · devices · pairing · transfers · history · settings · destinations │
│                               │                                            │
│  app/AppController  ──────────┤  (wires engine + platform adapters)        │
│                               ▼                                            │
│  platform/  notifications · permissions · pickers · android SAF · startup  │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │  interfaces only
┌───────────────────────────────▼──────── core/ (pure Dart, dart:io) ──────────┐
│ LanBeamEngine (facade)                                                       │
│  ├─ discovery/   DeviceDiscoveryService ← UdpMulticastDiscovery              │
│  ├─ security/    DeviceIdentity · PairingService · AuthenticationService     │
│  │               CertificatePinning · PathSafety                             │
│  ├─ networking/  LanServer (HTTPS + WebSocket) · PeerClient · NetworkService │
│  ├─ transfer/    TransferService (sender) · TransferReceiver · TransferQueue │
│  │               FileScanner · FileSource/FileChunkReader · FileChunkWriter  │
│  │               ChecksumService (worker isolate) · SpeedMeter               │
│  ├─ destinations/DestinationManager (file-type rules, conflict resolution)   │
│  └─ storage/     JsonStore · SettingsStore · TrustedDeviceStore              │
│                  TransferHistoryService · InboxStore (resume state)          │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Rule:** nothing in `lib/core` imports Flutter. The whole protocol, pairing,
and transfer engine run under plain `dart test`/`flutter test` against real
sockets on loopback. Platform code only provides implementations of small
interfaces (`FileSource`, `NotificationService`, `PermissionService`,
`FilePickerService`, `DiskSpaceService`, `BluetoothService`).

### 2.1 Symmetric peers

Every device runs the same engine: an HTTPS server (receive side) and an HTTP
client (send side). **Whoever sends is the HTTP client of the receiver.** A
phone sending to a PC calls the PC's server; the PC sending to the phone calls
the phone's server. This removes "desktop mode" vs "mobile mode" from the
protocol entirely — only the UI differs.

### 2.2 Components (mapping to the requested list)

| Requested component | Implementation |
|---|---|
| DeviceDiscoveryService | `core/discovery/discovery_service.dart` (interface), `udp_multicast_discovery.dart` |
| ConnectionService / NetworkService | `core/networking/peer_client.dart`, `network_service.dart` (interfaces, local addresses, reachability, error mapping) |
| PairingService | `core/security/pairing_service.dart` (QR tokens, PINs, approval) |
| AuthenticationService | `core/security/auth_service.dart` (challenge/response, session tokens) |
| TransferService | `core/transfer/transfer_service.dart` (outgoing) |
| TransferQueue | `core/transfer/transfer_queue.dart` |
| FileScanner | `core/transfer/file_scanner.dart` |
| FileChunkReader / FileChunkWriter | `core/transfer/file_source.dart`, `chunk_writer.dart` |
| ChecksumService | `core/transfer/checksum.dart` (block hashing, isolate-backed) |
| DestinationManager | `core/destinations/destination_manager.dart` |
| TransferHistoryService | `core/storage/history_service.dart` |
| NotificationService | `core/platform_interfaces.dart` + `platform/notifications.dart` |
| BluetoothService | `core/platform_interfaces.dart` (interface; see §6) |

## 3. Key technical decisions

### 3.1 Flutter + pure-Dart core
`dart:io` provides TLS servers, HTTP, WebSockets, UDP multicast and random-access
files on every target platform, so no native networking code is required. Native
code is used only where the OS forces it: Android Storage Access Framework
(content URIs), Wi-Fi multicast locks, media scanning.

### 3.2 HTTPS + WebSocket, not a custom TCP protocol
* HTTP gives us request framing, keep-alive and debuggability for free.
* File bytes go over plain streaming `PUT` requests — one per file, starting at
  a byte offset, so resuming is just "PUT from offset N".
* A per-transfer WebSocket carries real-time events (accept/reject, receiver
  progress, pause/resume/cancel, per-file verification) in both directions.
* REST equivalents exist for every command so a dropped WebSocket never
  wedges a transfer.

### 3.3 Self-signed certificates + pinning instead of a PKI
Each device generates an ECDSA P-256 key and self-signed certificate on first
launch. Its SHA-256 fingerprint *is* the device's cryptographic identity. The QR
code carries the fingerprint, so the phone verifies it is talking to the PC it
scanned, not to a man-in-the-middle. After pairing, both sides pin each other's
fingerprints forever (until unpaired).

We evaluated mutual TLS. `dart:io` servers reject self-signed client
certificates without a verification hook, so instead pairing establishes a
256-bit shared secret, and clients authenticate with an HMAC challenge/response
that yields a short-lived bearer token. All of this runs inside the pinned TLS
channel.

### 3.4 Block-level checksums
Files are hashed in 16 MiB blocks with SHA-256 while they stream. The receiver
appends each completed block hash to a side file next to the partial data. The
file digest is `SHA-256(header ‖ blockHash₀ ‖ blockHash₁ ‖ …)`.

* **Resume never re-reads data**: the receiver truncates the partial file to the
  last completed block and continues; previously computed block hashes are read
  from the side file. Worst-case re-send is one block (16 MiB).
* **Integrity**: the sender sends its digest when a file finishes; on mismatch
  the receiver discards the file and the sender retries from zero.
* **CPU**: hashing runs in a dedicated worker isolate fed with
  `TransferableTypedData`, keeping the UI isolate smooth during 100 MB/s
  transfers.

### 3.5 Streaming with backpressure
* Sender: `RandomAccessFile` reads 1 MiB chunks from an `async*` generator piped
  into `HttpClientRequest.addStream`, which pauses the generator while the
  socket is busy.
* Receiver: the request stream is paused while each coalesced 1 MiB buffer is
  written with `RandomAccessFile.writeFrom`, propagating TCP backpressure back to
  the sender.
* Memory per active file is bounded (~2–3 MiB) regardless of file size.

### 3.6 Receiver-side authority
The sender never chooses where files go. It sends only *relative* paths; the
receiver's user (or its rules) chooses destination roots, the receiver resolves
conflicts, and every final path is validated to be inside an approved root.

### 3.7 Discovery: UDP multicast first
UDP multicast (group `224.0.0.179`, port `45871`) plus limited broadcast works on
every platform from pure Dart and needs no daemon. The same JSON packet carries
everything the UI needs (name, type, OS, version, protocols, port, fingerprint).
Manual `host:port` connection is the fallback when multicast is filtered (common
on corporate/guest Wi-Fi with client isolation). An mDNS provider can be added
behind the same `DeviceDiscoveryService` interface.

## 4. Project structure

```
lib/
  main.dart                      entry point
  app/                           AppController, theme, root widget, routing
  core/                          pure Dart — no Flutter imports
    models/                      DeviceInfo, TrustedDevice, Manifest, TransferState, …
    protocol/                    constants, endpoints, error codes, JSON helpers
    discovery/                   DeviceDiscoveryService, UDP multicast implementation
    security/                    identity/certs, pairing, auth, pinning, path safety
    networking/                  LanServer, PeerClient, NetworkService
    transfer/                    sender, receiver, queue, scanner, checksums, I/O
    destinations/                DestinationManager, file categories, conflicts
    storage/                     JSON stores, settings, trusted devices, history, inbox
    engine.dart                  LanBeamEngine facade
    platform_interfaces.dart     interfaces implemented by platform/
  platform/                      Flutter/native adapters (pickers, notifications, …)
  features/                      UI by feature
    home/ devices/ pairing/ transfers/ history/ settings/ destinations/ receive/
  ui/                            shared widgets, formatting
test/
  core/                          unit + loopback networking/protocol tests
  widget/                        widget smoke tests
integration_test/                on-device tests (Android/iOS/desktop runners)
docs/                            this documentation
```

## 5. Data flow: sending a folder from phone to PC

1. Phone `FileScanner` walks the chosen folder (or Android SAF tree) and builds
   a manifest: `{id, relativePath, size, modified}` per file. Nothing is read yet.
2. Phone authenticates to the PC (`/auth/challenge` → `/auth/session`).
3. Phone `POST /transfers` with the manifest and opens the transfer WebSocket.
4. PC validates every path, computes the destination plan and conflicts, and
   asks its user (or auto-accepts for trusted devices with rules enabled).
5. PC sends `decision` with a per-file start offset (non-zero when resuming) and
   skip list (conflict "Skip").
6. Phone uploads files (up to 3 concurrently) as streaming `PUT`s from the given
   offsets; both sides hash blocks as data flows.
7. After each file: `POST …/complete {digest}` → PC verifies, atomically moves the
   file from staging to its final path (applying the conflict choice) and
   restores the modification time.
8. Both sides record history; notifications fire.

If the Wi-Fi drops at step 6, the phone retries with backoff, rediscovering the
PC's possibly-new IP address. On reconnection the PC reports each file's
committed offset and the upload continues.

## 6. Bluetooth and direct IP

* **Direct IP** (implemented): the user types `host:port`; the app fetches
  `/info`, shows the remote fingerprint as a short verification code, and pairs
  via PIN. The PIN proof binds both certificate fingerprints, so a MITM on the
  path is detected.
* **Bluetooth** (Phase 4, interface defined, not implemented in this iteration):
  raw Bluetooth throughput (~0.1–2 Mbit/s for BLE, ~2 Mbit/s for RFCOMM) is far
  too slow for the stated goals, and iOS does not allow RFCOMM to non-MFi
  devices. The planned design, matching Nearby Share, uses BLE only to
  *bootstrap*: advertise presence, exchange the LAN address or a Wi-Fi Direct /
  hotspot credential, then run the normal HTTPS protocol over Wi-Fi. That needs
  a BLE peripheral implementation per platform; `BluetoothService` reserves the
  integration point and the Settings screen reports availability honestly.

## 7. Milestones

| Phase | Scope | Status |
|------|-------|--------|
| 1 | Discovery, pairing (QR + PIN), send/receive, destination folder, progress | ✅ implemented |
| 2 | Multiple files, folders, resume, retry, history, drag & drop, conflicts | ✅ implemented |
| 3 | iOS, macOS, Linux runners, permissions, entitlements | ✅ implemented (CI-built) |
| 4 | Direct IP ✅, advanced device management ✅, Bluetooth bootstrap ⏳ | partial |
| 5 | Security hardening ✅, performance ✅, automated tests ✅, packaging (CI) ✅ | implemented; store signing is per-publisher |
