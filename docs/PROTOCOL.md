# LanBeam Protocol v1

All multi-byte values are JSON unless stated otherwise. All HTTP traffic is
HTTPS (TLS 1.2+) using each device's self-signed ECDSA P-256 certificate.
Clients **must** pin the server certificate fingerprint (SHA-256 of the DER
certificate, lowercase hex) obtained from a QR code, a trusted-device record,
or — for PIN pairing only — the discovery announcement, verified by the PIN
proof.

Default ports: discovery UDP `45871`, transfer service TCP `45872` (falls back
to an ephemeral port if busy; the real port is always advertised).

---

## 1. Discovery (UDP)

Multicast group `224.0.0.179:45871`, also sent to `255.255.255.255:45871`.
Packets are UTF-8 JSON, ≤ 1400 bytes.

```json
{
  "proto": "lanbeam", "v": 1,
  "type": "announce",            // announce | query | bye
  "id": "8f0c…",                 // device id (UUID v4)
  "name": "John's Pixel",
  "deviceType": "phone",         // phone | tablet | desktop | laptop
  "os": "android",               // android | ios | windows | macos | linux
  "appVersion": "1.0.0",
  "protocols": ["lanbeam-https/1"],
  "port": 45872,
  "fp": "3b9a…"                  // certificate SHA-256 fingerprint
}
```

* On start a device sends `query` then `announce`, and re-announces every 15 s.
* On receiving `query` a device replies with a unicast `announce` to the sender.
* Devices not heard from for 45 s are removed. `bye` removes immediately.
* Announcements are **hints only**; identity is established by TLS pinning.

## 2. HTTP API

Base path: `/api/v1`. Errors use

```json
{ "error": "<code>", "message": "Human readable" }
```

| Code | HTTP | Meaning |
|------|------|---------|
| `bad_request` | 400 | malformed body / invalid path in manifest |
| `unauthorized` | 401 | missing/expired session token |
| `forbidden` | 403 | not trusted / pairing rejected |
| `not_found` | 404 | unknown transfer or file |
| `offset_mismatch` | 409 | upload offset ≠ committed offset (body has `offset`) |
| `gone` | 410 | transfer cancelled |
| `checksum_mismatch` | 422 | digest verification failed |
| `paused` | 423 | receiver paused the transfer |
| `rate_limited` | 429 | too many attempts |
| `disk_full` | 507 | insufficient storage |
| `internal` | 500 | unexpected error |

### 2.1 Public endpoints

`GET /api/v1/info` → device info object (same fields as the announcement minus
`proto/type`).

### 2.2 Pairing

**QR code payload** (displayed by the device being paired *to*):

```
lanbeam://pair?v=1&id=<deviceId>&n=<urlencoded name>&a=<ip1>,<ip2>&p=<port>&fp=<fingerprint>&t=<token>
```

`t` is a 256-bit random token (base64url), single use, valid for 5 minutes by
default (configurable 1–30 min).

**PIN**: a 6-digit code displayed by the device being paired to, valid for
2 minutes, 5 attempts.

`POST /api/v1/pair/pin` `{ "device": DeviceInfo }` → `{ "nonce": "<b64>", "expiresIn": 120 }`
— asks the server to display a PIN. Only one PIN session is active at a time.

`POST /api/v1/pair/request`

```json
{
  "method": "qr",                 // qr | pin
  "token": "<qr token>",          // method = qr
  "nonce": "<from /pair/pin>",    // method = pin
  "proof": "<hex>",               // method = pin
  "device": { "id", "name", "deviceType", "os", "appVersion", "port", "fp" }
}
```

PIN proof = `HMAC-SHA256(key = utf8(PIN), msg = "lanbeam-pin-v1|" + nonce + "|" + clientId + "|" + clientFp + "|" + serverFp)`.
A man-in-the-middle presents a different `serverFp`, so the proof fails at the
real server.

The request is held open (≤ 120 s) until the server's user approves (QR) or
the PIN verifies. Response on success:

```json
{
  "status": "approved",
  "secret": "<base64 32 bytes>",   // shared pairing secret
  "device": DeviceInfo
}
```

Both devices store a TrustedDevice `{id, name, deviceType, os, fp, secret, lastAddresses, lastPort, pairedAt}`.

`POST /api/v1/pair/revoke` (authenticated) → the server forgets the caller.

### 2.3 Authentication

1. `POST /api/v1/auth/challenge {"deviceId"}` → `{"nonce": "<b64>"}` (single use, 30 s)
2. `POST /api/v1/auth/session {"deviceId", "nonce", "proof"}`
   where `proof = HMAC-SHA256(secret, "lanbeam-auth-v1|client|" + nonce + "|" + clientId + "|" + serverId)`
   → `{"token": "<b64>", "expiresIn": 3600, "serverProof": HMAC(secret, "lanbeam-auth-v1|server|" + nonce + "|" + clientId + "|" + serverId)}`

The client verifies `serverProof` (mutual authentication on top of TLS pinning).
All endpoints below require `Authorization: Bearer <token>`. Unknown devices,
bad proofs, and expired nonces all return the same `401` to avoid oracles.
Repeated failures from one IP trigger `429`.

### 2.4 Transfers

**Offer** — `POST /api/v1/transfers`

```json
{
  "transferId": "uuid",            // chosen by the sender; reused to resume
  "kind": "files",                 // files | folder | mixed
  "totalSize": 123456,
  "files": [
    { "id": "f1", "path": "DCIM/Camera/IMG001.jpg", "size": 4096,
      "modified": 1700000000000, "mime": "image/jpeg" }
  ]
}
```

* `path` uses `/`, is relative, and must not contain `.`/`..` segments, empty
  segments, drive letters, NUL or control characters. Violations → `400`.
* Limits: 100 000 files, 16 MiB manifest.

Response `202 {"transferId", "state": "pending"}`; or `200` with a decision
when the receiver already accepted (auto-accept or resume of a known transfer).

**Status** — `GET /api/v1/transfers/{id}` → `{"state", "files": {"f1": {"offset", "skip", "state"}}}`

**Events** — `GET /api/v1/transfers/{id}/events` (WebSocket upgrade, same
bearer token). Server → client:

```json
{"type":"decision","accepted":true,"files":{"f1":{"offset":0,"skip":false}}}
{"type":"decision","accepted":false,"reason":"rejected"}
{"type":"progress","received":123456}
{"type":"file","fileId":"f1","state":"verified"}
{"type":"paused"} {"type":"resumed"} {"type":"cancelled","by":"receiver"}
```

Client → server: `{"type":"pause"}`, `{"type":"resume"}`, `{"type":"cancel"}`
(equivalent to the REST commands below).

**Upload** — `PUT /api/v1/transfers/{id}/files/{fileId}?offset=N`
Body: raw bytes from offset `N` to end of file (`Content-Length` = size − N).
`N` must equal the receiver's committed offset (always a 16 MiB block boundary)
or `409 {"error":"offset_mismatch","offset":M}` is returned.
Response `200 {"received": <bytes committed>}`.

**Complete** — `POST /api/v1/transfers/{id}/files/{fileId}/complete {"digest":"<hex>"}`
→ `200 {"state":"verified","name":"<final file name>"}` or `422 checksum_mismatch`
(partial data discarded; sender restarts the file from 0).

**Commands** — `POST /api/v1/transfers/{id}/pause|resume|cancel`.

**Finish** — `POST /api/v1/transfers/{id}/finish` → receiver closes the session
and records history.

## 3. Checksums

Block size `B = 16 MiB`. For a file of size `S` split into blocks
`b₀ … bₙ₋₁` (last may be short; `n = 0` for empty files):

```
digest = SHA-256( utf8("lanbeam-blocks-v1:" + S + ":" + B + ":") ‖ SHA-256(b₀) ‖ … ‖ SHA-256(bₙ₋₁) )
```

The receiver stores `SHA-256(bᵢ)` (hex, one per line) in
`<staging>/<fileId>.blocks` as each block is committed. On resume it truncates
the partial file to `⌊len / B⌋ · B` bytes (bounded by the number of stored
hashes) and reports that offset.

## 4. State machines

Receiver transfer: `pending → accepted → active ⇄ paused → completed | failed | cancelled | rejected`.

Sender transfer: `preparing → awaitingApproval → active ⇄ paused → completed | failed | cancelled | rejected`.
`failed` is resumable via Retry (same `transferId`).

Per file: `queued → uploading → verifying → done | skipped | failed`.
