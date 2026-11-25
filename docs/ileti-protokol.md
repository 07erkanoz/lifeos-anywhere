# LifeOS İleti — wire protocol spec for an AnyWhere implementation

Source: LifeOS checkout `/home/erkanoz/projeler/lifeOSArch` (read 24.11.2026). All `file:line` references are
to that tree. `[inferred]` marks conclusions drawn from reading the code, not stated in it or tested.

Paths used below:

| Short | File |
|---|---|
| `ileti.py` | `lifeos_store/ileti.py` |
| `posta.py` | `lifeos_store/ileti_posta.py` |
| `uzak.py` | `lifeos_store/ileti_uzak.py` |
| `delik.py` | `lifeos_store/ileti_delik.py` |
| `yakin.py` | `lifeos_store/yakin.py` |
| `paylas.py` | `lifeos_store/yakin_paylas.py` |
| `destek.py` | `lifeos_store/destek.py` |
| `araci.py` | `sunucu/destek/araci.py` (server side) |

---

## 0. Most important finding: LifeOS already treats a pinned AnyWhere 1.2 phone as a chat peer

LifeOS decides "chat or clipboard" with `paylas._secure_peer(device_id)` (`paylas.py:61-64`): paired **and** a
`fingerprint` pinned in `yakin-guven.json`. It does **not** look at the `"ileti"` capability or the platform:

- `send_text` (`ileti.py:354-357`): `if found and not _secure_peer(found): return _to_clipboard(...)`.
- `send_files` (`ileti.py:465-467`): non-secure → `yakin.send_files` (old `/api/send-request` path).
- `overview()` sets `canMessage = secure and mesaj != False` (`ileti.py:1125`).

AnyWhere 1.2.0 pairs over TLS and sends its fingerprint (`lib/features/pairing/data/pairing_client.dart:91`,
header `X-LifeOS-Fingerprint`), and LifeOS pins it (`yakin.py:157-164`, `yakin.py:507-516`, `yakin.py:1051-1052`).
So, **[inferred]**, for a phone paired with AnyWhere 1.2:

- Text and files written to the phone in LifeOS İleti now go through the chat path: `POST /api/ileti` to the phone.
  AnyWhere answers 404, and LifeOS marks the message `hata`: "Karşı bilgisayarda LifeOS İleti yok; LifeOS'un
  güncellenmesi gerekir." (`ileti.py:576-577`). The clipboard fallback described in `docs/ileti.md:48-52` only
  still applies to unpinned (AnyWhere 1.1) phones.
- Every 60 s, while the phone is "here", the pump `POST`s `/api/ileti/posta` to the phone and gets a 404
  (`ileti.py:1370-1374`, `posta.py:246-253`, `ileti.py:810-825`). Each request wakes the phone.

The `"ileti"` capability is recorded when a device is heard (`yakin.py:811-813`, `849-851`, `965-967`). It is only
used for a hint in the UI (`apps/ileti/lifeos_ileti/qml/Konusma.qml:70`). Advertising it from AnyWhere changes
nothing about routing. Once AnyWhere implements the endpoints below, LifeOS will chat with it without any change.
§9 lists the LifeOS changes that would still be worth making.

---

## 1. Message model

### 1.1 Identifiers and time

- **Message id**: a UUID4 string, lowercase, matching
  `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` (`ileti.py:61`; made at `ileti.py:338`). The
  sender makes it. The receiver keys its row by `(id, direction)` (`ileti.py:55-58`), so the same id can exist once
  as `giden` (outgoing) and once as `gelen` (incoming).
- **Device id**: Yakındakiler's `identity()["id"]` (UUID4 on LifeOS, `yakin.py:85-92`). AnyWhere uses its own
  device id. Only these rules apply to it: it must equal the paired trust-store key, and `_der_path` strips it to
  `[A-Za-z0-9_.-]` (`ileti.py:207`).
- **Timestamps**: Unix epoch **seconds as a float** (`time.time()`), both in `sent` and in local rows. The server's
  envelope ids use `time.time_ns()` (19 digits).

### 1.2 What is sealed and sent: `wire`

The plaintext inside the sealed box (`ileti.py:589-590`):

```json
{
  "text": "string, may be empty when a file is attached",
  "sent": 1764000000.123,
  "ek": { ...optional file record, §1.3... }
}
```

Unknown keys are ignored on receipt. The receiver keeps `text[:16000]`, `sent` and a cleaned `ek`
(`ileti.py:904-911`).

### 1.3 File record `ek` (attachment)

Fields sent: `WIRE_FILE = ("name", "size", "mime", "tur", "key", "nonce", "sha256", "sure")` (`ileti.py:54`).
They are built at `ileti.py:475-478`.

| field | type | meaning |
|---|---|---|
| `name` | str | file name. The receiver sanitises it with `yakin._safe_name(...)[-1]` (`ileti.py:907`, `yakin.py:390-392`) |
| `size` | int | bytes, exact |
| `mime` | str | e.g. `image/jpeg`, `application/octet-stream`. Receiver keeps `[:120]` |
| `tur` | str | kind: `gorsel` (image/\*), `video` (video/\*), `ses` (audio/\*), `dosya` (anything else) (`ileti.py:62`, `159-161`). The receiver recomputes it from name+mime (`ileti.py:909`) |
| `key` | str | base64 (standard, padded) of 32 random bytes: the file's own ChaCha20-Poly1305 key |
| `nonce` | str | base64 of **4** random bytes: the nonce prefix for every piece (§2.4) |
| `sha256` | str | lowercase hex SHA-256 of the plaintext file. The receiver checks it if it is non-empty (`ileti.py:991`) |
| `sure` | int | optional: a voice message's length in seconds. Kept only if `str(sure).isdigit()` (`ileti.py:911`) |

Local-only keys, never sent: `path`, `durum`, `yol`.

### 1.4 Kinds of message

There is one message type. The kind follows from the content:

- **text**: `text` non-empty, no `ek`. Limit `TEXT_LIMIT = 16000` characters (`ileti.py:49`). The sender refuses
  longer text (`ileti.py:352`); the receiver truncates (`ileti.py:904`). Empty text without a file is refused by
  the sender (`ileti.py:350`).
- **file / image / video / voice**: `ek` present. A voice message is `tur:"ses"` plus `sure`. LifeOS records Ogg
  Opus (`ileti.py:401-451`). Each file is its own message; the caption goes only with the first
  (`ileti.py:479`).
- **clipboard** (`pano: true`): local only. It is a row LifeOS writes for clipboard traffic with a non-chat
  device (`ileti.py:364-398`). It never travels as an İleti message.
- **call log** (`arama`): local only (`ileti_arama.py`).
- **read receipt / delivered receipt**: not messages. They are separate requests or letters (§3.4, §4.6).
- **typing indicator, edit, remote delete, reply/quote, reactions**: **do not exist**. `delete_message` and
  `delete_chat` are local only (`ileti.py:1152-1165`).

### 1.5 States (local; for UI parity)

- Outgoing `durum` values:
  - `bekliyor`: queued.
  - `gonderiliyor`: claimed by a sender. It goes back to `bekliyor` after `STALE = 90` s without progress
    (`ileti.py:50`, `512`).
  - `iletildi`: delivered.
  - `sunucuda`: left in the mailbox.
  - `okundu`: read.
  - `hata`: failed; the reason is in `body.hata`.
- Incoming: `yeni` (unread) and `okundu`.
- File `ek.durum`:
  - sender side: `bekliyor`, then `tamam`.
  - receiver side: `geliyor`, then `tamam` or `hata`.
  - `ek.yol` tells how a file came: `dogrudan` (direct internet connection) or `sunucu` (server relay).

---

## 2. Cryptography

AnyWhere has `pointycastle ^4.0.0`, which provides `ECDHBasicAgreement`, `HKDFKeyDerivator` and
`ChaCha20Poly1305` (ChaCha7539, 12-byte nonce, 16-byte tag), plus `crypto`. `dartssh2` pulls in `pinenacl`
(Ed25519). There is no `cryptography` package. Everything below can be done with what is already in `pubspec.yaml`.

### 2.1 Identity keys

- Each LifeOS computer has a self-signed **EC P-256** certificate (`openssl req -x509 -newkey ec
  ec_paramgen_curve:prime256v1`, `yakin.py:95-107`). AnyWhere's `TlsIdentity` is P-256 as well
  (`lib/core/tls/tls_identity.dart:81`), so ECDH is possible.
- Fingerprint = lowercase hex SHA-256 of the certificate DER (`yakin.py:119-120`). This is the value pinned as
  `fingerprint` in the trust store.
- The 6-digit pairing code = `int(sha256("".join(sorted([fpA, fpB]))).hexdigest(), 16) % 1_000_000`, shown as
  `"%03d %03d"` (`yakin.py:123-129`).

### 2.2 Pair key (messages, receipts, mailbox control letters)

`_pair_key` (`ileti.py:246-255`) and `_derive` (`ileti.py:187-189`):

```
shared = ECDH(my P-256 private key, peer certificate public key)   # cryptography's exchange(): the raw 32-byte X coordinate
salt   = ASCII( "".join(sorted([my_fingerprint_hex, peer_fingerprint_hex])) )   # 128 ASCII chars
key    = HKDF-SHA256(ikm=shared, salt=salt, info=b"lifeos-ileti-1", length=32)
```

Dart pitfalls:
- `ECDHBasicAgreement.calculateAgreement` returns a `BigInt`. Encode it **big-endian, left-padded to exactly 32
  bytes**.
- The peer's public key comes from the certificate the peer presents. Over LAN, take it from the envelope's `cert`
  or from the TLS peer certificate, but only after its SHA-256 equals the pinned fingerprint (`ileti.py:210-221`,
  `224-243`).

### 2.3 Seal / open (all boxes)

`_seal` / `_open` (`ileti.py:258-268`):

```
blob = nonce(12 random bytes) || ChaCha20-Poly1305(key).encrypt(nonce, plaintext, aad)   # ciphertext || 16-byte tag
```

On JSON, blobs are base64 encoded (standard alphabet, padded; Python `base64.b64encode`).

| Box | key | AAD (UTF-8) | plaintext |
|---|---|---|---|
| message envelope `box` | pair key | `"<message_id>\|<sender_device_id>"` (`ileti.py:593`, `900-901`) | JSON `wire` (§1.2) |
| mailbox control letter `box` | pair key | `"<kind>\|<sender_device_id>"` (`ileti.py:888`, `850`) | JSON value (§4.6) |
| invitation offer / answer | invite key (§5) | `"<TAG>"` (`uzak.py:51`, `57`) | JSON identity (§5) |
| file piece | file key | `b"son"` for the last piece, `b"ara"` otherwise | 1 MiB block (§2.4) |
| storage row (local) | storage key (§2.5) | empty | JSON body |

JSON is encoded with `ensure_ascii=False` (UTF-8) for envelopes and with Python defaults for control values. Both
are fine for a JSON parser.

### 2.4 File stream framing (same on LAN, direct internet and relay)

`_sealed_pieces` / `_upload` / `_take_file` (`ileti.py:634-646`, `715-755`, `961-1008`), `CHUNK = 1 MiB`
(`ileti.py:48`):

```
pieces = max(1, ceil(size / 1048576))          # an empty file is 1 piece of 0 bytes
for n in 0..pieces-1:
    nonce_n = nonce_prefix(4 bytes, from ek.nonce) || n as 8-byte big-endian
    sealed  = ChaCha20-Poly1305(ek.key).encrypt(nonce_n, block_n, aad = n == pieces-1 ? "son" : "ara")
    frame   = len(sealed) as 4-byte big-endian || sealed       # len = len(block)+16
stream length = size + pieces * 20
```

The receiver (`ileti.py:920-942`):
- rejects a frame length outside `16 ..= CHUNK+16`;
- rejects more pieces than announced;
- requires `count == pieces` and the total equal to `size`;
- checks the SHA-256.

A partial file is written to `~/.cache/lifeos/ileti-<id>.part` and moved into place at the end.

### 2.5 Storage at rest (LifeOS's own; not a wire matter)

`_storage_key` (`ileti.py:197-203`):

```
storage_key = HKDF-SHA256(ikm = the raw bytes of the TLS key file anahtar.pem, salt = None (32 zero bytes), info = b"lifeos-ileti-depo-1")
```

Rows live in SQLite `~/.local/share/lifeos/ileti/ileti.db`, table `ileti(id, yon, cihaz, zaman, durum, govde,
deneme)` (`ileti.py:55-60`). `govde` is a sealed JSON body. AnyWhere does **not** need to match this, because
nothing reads another device's database. A sensible equivalent: a random 32-byte key in `flutter_secure_storage`,
or HKDF over the PEM of AnyWhere's own TLS key with the same info string.

### 2.6 HKDF with `salt=None`

Python's `cryptography` HKDF with `salt=None` uses 32 zero bytes. **[inferred, verify]** Check that pointycastle's
`HKDFKeyDerivator` treats a null salt the same way, or pass `Uint8List(32)` explicitly. This matters for the
invitation key (§5), where `salt=None`. Before implementing, write an interop test with fixed vectors from Python
(`test/interop/lifeos_peer.py` is a good place).

---

## 3. LAN transport

### 3.1 Channel and authentication

- The channel is Yakındakiler's port **48739**, TLS (the first byte tells TLS apart from plain HTTP), with the
  certificates from §2.1. There is no client certificate. LifeOS's server does not ask for one (`yakin.py:872`,
  `885`).
- As a **client**, LifeOS uses TLS 1.2+ with `CERT_NONE` and then compares the SHA-256 of the server certificate
  DER with the pinned value. A mismatch refuses the connection (`yakin.py:1023-1060`).
- Request headers (`yakin.py:1063-1068`):
  - `X-AnyWhere-Token: <token from the trust entry>`
  - `X-AnyWhere-Protocol: 1.1`
  - `X-LifeOS-Fingerprint: <own fingerprint>`, sent when over TLS
  - `Content-Type: application/json`
- How the server authenticates a request to `/api/ileti*` (`paylas.py:121-131`, `134-158`):
  - the request must be over TLS, **and**
  - `X-AnyWhere-Token` must equal the `token` of a trust entry that has a `fingerprint`.
  - That entry's key is the authenticated sender device id. Otherwise the answer is `403 "yalniz sifreli eslesmis
    cihaz"`.
  - If `izinler.mesaj == false` the answer is `403 "izin yok: mesajlaşma"`.
  - Messaging is on by default and is never asked about.
- LifeOS accepts `Content-Length` or chunked bodies (`yakin.py:453-495`). It sends `Content-Length` itself.

### 3.2 Endpoints (all `POST`; others → 405)

The dispatcher is `ileti.handle` (`ileti.py:759-782`). If `cryptography` is missing the answer is
`501 "ileti yok"`; an unknown subpath gets `404 "yok"`. A `ValueError`/`OSError` while handling becomes
`400 <reason>` as text/plain (`paylas.py:155-158`).

| Path | Request body | Response | Limit |
|---|---|---|---|
| `/api/ileti` | envelope (§3.3) | `200 {"ok": true}` | body ≤ 1 MiB (`ileti.py:769`) |
| `/api/ileti/ek/<message_id>` | octet-stream, §2.4 frames | `200 {"ok":true}`; `404 "ileti yok"` (no such incoming message from this device); `422 <reason>` (decrypt/size/hash failure) | none |
| `/api/ileti/okundu` | `{"ids": [message_id, ...]}` | `200 {"ok": true}` | ≤ 2000 ids used (`ileti.py:787`) |
| `/api/ileti/posta` | `{"adres": "<32 hex or ''>", "cert": "<b64 DER of own cert>"}` | `200 {"ok": true, "adres": "<my box or ''>"}` | 64 KiB |
| `/api/ileti/arama` | voice-call signal (skip, §10) | `{"ok": ...}` | 64 KiB |

### 3.3 Envelope (`/api/ileti` body, and the `zarf` inside a mailbox letter)

`_envelope` (`ileti.py:586-596`):

```json
{
  "v": 1,
  "id": "<message uuid>",
  "from": "<sender device id>",
  "name": "<sender display name>",
  "cert": "<base64 DER of the sender's TLS certificate>",
  "box": "<base64(nonce||ct||tag)>  sealed wire, AAD = id|from"
}
```

What the receiver does (`_receive`, `ileti.py:895-917`):
1. Checks that `id` matches the UUID regex and that `from` equals the authenticated device. Otherwise it raises
   `ValueError`, which becomes 400.
2. Checks that `sha256(cert)` equals the pinned fingerprint of `from`, and stores the DER
   (`config/lifeos/ileti-anahtar/<id>.der`). On a mismatch it raises `ValueError`, which becomes 400.
3. Opens `box` with the pair key. A failure raises `ValueError("çözülemedi")`, which becomes 400.
4. If `(id, gelen)` already exists, returns `200 ok`. Delivery is idempotent, so a retry after a broken connection
   is safe.
5. Inserts the row with `durum=yeni`. If `ek` is present, the file's `durum` is `geliyor`, and the notification
   waits for the file.

`v` and `name` are not checked.

### 3.4 Sending, retries, and the pending queue ("pump")

- `send_text`/`send_files` queue a row (`bekliyor`) and call `flush(device)` (`ileti.py:337-343`, `347-361`,
  `454-482`).
- `flush` (`ileti.py:509-526`) does three things:
  - resets `gonderiliyor` rows idle for more than 90 s;
  - sends `bekliyor` rows oldest first, one device at a time (a lock per device);
  - stops for a device on its first "away" result.
- `_deliver` (`ileti.py:535-583`), per message:
  1. Claims the row (`gonderiliyor`). If another process got there first, it skips the row.
  2. Picks the internet route when the mailbox route is ready, the peer was not heard on the LAN within `HERE = 45`
     s (`yakin.py:47`), and the peer's certificate is known. That path is §4.
  3. If the peer has no IP (paired remotely, never met on a LAN), the message waits.
  4. Otherwise it sends `POST /api/ileti` with a 20 s timeout. If the message has a file, it then uploads the file
     right away (§3.5) and marks it `tamam`.
  5. Errors:
     - `"... yanıt vermedi"` (a network failure, the text LifeOS gives an unreachable peer): falls back to the
       internet route if it is ready, else back to `bekliyor`. The device counts as away.
     - HTTP 404 or 501: `hata` "the other side has no İleti".
     - 403: `hata` "refused".
     - Any other ≥ 400: `hata` with the text.
     - A `_Failed` (file gone, pairing removed): `hata`.
  6. On success: `iletildi`. For LAN delivery, the receiver's HTTP 200 counts as the delivery receipt. No separate
     "delivered" message is sent.
- `retry(id)`: puts the row back to `bekliyor` and flushes (`ileti.py:495-506`).
- `pump` runs in `lifeos-yakin.service`, every 4 s (`ileti.py:1350-1376`):
  - **files waiting**: files of messages that went through the mailbox and still need to go. If the peer is on the
    LAN now, they are uploaded via `/api/ileti/ek` (`_send_file_here`, `ileti.py:699-712`). Otherwise, if the
    mailbox route is ready, the pump tries a direct internet send every 300 s.
  - **waiting messages**: if the peer is on the LAN now, `flush`. Else, if the mailbox route is ready, `flush`
    every 30 s.
  - **box exchange**: for each pinned peer that is here and still `needs_exchange` (§4.4), call `exchange()`.

### 3.5 Files in chat on the LAN

- Chat files use their **own endpoint**, `POST /api/ileti/ek/<message_id>`, sent right after the envelope (whose
  `ek` carries `key`, `nonce`, `size` and `sha256`). They do **not** reuse `/api/send-request` or `/api/upload`.
- Request details:
  - one request, `Content-Type: application/octet-stream`, `Content-Length: size + pieces*20`;
  - the body is the concatenated §2.4 frames;
  - the connection timeout is 600 s;
  - the sender updates progress and a liveness stamp every 0.4 s (`ileti.py:715-755`).
- If the file was already received (`durum=tamam`), the receiver drains the body and answers 200
  (`ileti.py:951-953`).
- On failure the receiver sets the file's `durum=hata` and answers 422 with the reason (`ileti.py:993-998`,
  `954-957`). The sender's `_upload` raises `SourceError`; a 422 makes the outgoing message `hata`. A broken
  connection (`yanıt vermedi`) puts it back to `bekliyor`, and both envelope and file are sent again. The
  envelope is idempotent.
- **Where incoming files land on LifeOS**: `incoming_dir(device)` = `~/Paylaşım/<device folder>/Gelenler`, or
  `~/Downloads/AnyWhere` when the setting `gelenler=indirilenler` (`ileti.py:121-148`, `999-1002`). Name clashes
  get ` (n)` added. The same folder receives files the phone sends via the old `/api/send-request` path
  (`yakin.py:383-387`, `605`).
- Files that came through Yakındakiler's ordinary transfer (history file `yakin-gecmis.json`) are **already shown
  in the LifeOS conversation** as `transfer: true` items (`ileti.py:1076-1086`). So a phone can send files to LifeOS
  today, without İleti, and they appear in the chat. They are just not İleti messages: no caption, no receipt.

### 3.6 Read receipts

- When the LifeOS user opens a conversation, `mark_read` changes `yeni` to `okundu` and, if the setting
  `okundu=true`, calls `_tell_read` (`ileti.py:1012-1037`).
- Route for the receipt:
  - If the peer is here: `POST /api/ileti/okundu {"ids":[...]}` (timeout 8 s), plain JSON inside TLS, **not
    sealed** (`docs/ileti.md` "Sınırlar").
  - If it is away: a sealed `okundu` letter via the mailbox; if that is impossible, LAN anyway.
  - If both fail, the receipt is dropped.
- What the receiving side does (`_mark_theirs`, `ileti.py:785-794`): for each id, only outgoing rows from that
  device change state, and only along these steps:
  - `okundu`: from `iletildi` or `sunucuda`;
  - `iletildi`: only from `sunucuda`.
- There is no batching beyond the list and no retry queue.

### 3.7 `/api/ileti/posta` (learning mailbox addresses on the LAN)

Server side (`_exchange_answer`, `ileti.py:798-807`):
1. Checks that the request's `cert` matches the pin and stores it. A failure raises `ValueError`, which becomes
   400.
2. Stores the caller's `adres`. It must be 32 lowercase hex characters or `""`; anything else is 400
   (`posta.py:223-235`).
3. Answers with its own box, registering one if internet is enabled. Then it pushes the new allow list to the
   server (§4.3).

Client side (`exchange`, `ileti.py:810-829`): sends its own `adres` and `cert`, stores the answer's `adres`, and
records `bildirildi`.

---

## 4. Internet: the per-user mailbox (`ileti_posta.py` + `araci.py ileti`)

### 4.1 Server and SSH

- Server config is in `catalog/destek/sunucu.json`, which `/etc/lifeos/destek.json` can override
  (`destek.py:58-64`):
  - `adres`: `87.121.104.192`, `port`: **47022**
  - `sunucu_anahtari`: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVH7XCCIG6E4sGggYK4/l+FAsKGUC47fC682lJGFGdb`
- Host key pinning (`destek.py:67-73`): known_hosts line `[87.121.104.192]:47022 <sunucu_anahtari>`, with
  `StrictHostKeyChecking=yes`.
- The exact client command (`destek.py:76-80`):

  ```
  ssh -p 47022 -i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=<file>
      -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 [extra] <user>@87.121.104.192 <words...>
  ```

- The server runs its own sshd (`sunucu/destek/sshd_config`): publickey only, no TTY, no forwarding except the
  support tunnel, `MaxSessions 4`, and `AuthorizedKeysCommand araci.py anahtarlar %u`. Every key is
  `restrict,command="araci.py <role> <arg>"` (`araci.py:248-273`). **The words you send arrive as
  `SSH_ORIGINAL_COMMAND`, split on whitespace** (`araci.py:151-153`), so this is an exec request, not a shell.
- Output format: every command prints **one JSON object on stdout** and exits 0. On failure it prints
  `{"hata": "..."}` and exits 1 (`araci.py:142-148`). The client parses **the last stdout line** and raises on
  `hata` (`posta.py:135-146`).
- With dartssh2: create one `SSHClient` (an `SSHSocket` to port 47022), verify the host key in `onVerifyHostKey`
  against the pinned key, authenticate with an `OpenSSHEd25519KeyPair`, then run each command with
  `client.execute(words)`, writing stdin and closing it. LifeOS starts a new `ssh` process for every call. Reusing
  one connection with up to 4 channels is allowed by the server **[inferred]**.

### 4.2 Mailbox key and address

- Each user has their own key: `ssh-keygen -t ed25519 -N "" -C lifeos-ileti` at
  `~/.config/lifeos/ileti-posta/anahtar` (`posta.py:100-109`).
- `public` = the first two space-separated fields of the `.pub` file, e.g. `ssh-ed25519 AAAAC3...`.
- **The address is `sha256(public.encode()).hexdigest()[:32]`** (`posta.py:169`, `araci.py:525`). The client
  checks that the server returns exactly this.
- To register (open the box), connect as user **`lifeos-kayit`** with the **shared joining key** (§7), with words:

  ```
  ileti <payload>
  payload = base64url( JSON {"anahtar": "<public>"} ) with the "=" padding removed      (destek.py:83-84)
  → {"adres": "<32 hex>"}
  ```

  The server (`araci.py:309-318`, `520-533`, `156-163`) caps string values at 900 characters and checks the key
  with `^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]{40,800}$`. Registering is idempotent. It fails
  with "Posta kutuları dolu" once 50 000 boxes exist.
- From then on, connect as **`lifeos-ileti`** with the user's own key. The forced command is `araci.py ileti
  <adres>`, so the box is bound to the key (`araci.py:260-264`). If a call answers "Posta kutusu yok", LifeOS
  clears its address and registers again (`posta.py:304-305`).

### 4.3 Commands as `lifeos-ileti` (`araci.py:555-664`)

| words | stdin | stdout (success) | notes |
|---|---|---|---|
| `izin` | JSON list of box addresses | `{"izinli": n}` | **replaces** the allow list: boxes that may write here. ≤ 64 KiB stdin, ≤ 500 boxes, own box removed. LifeOS sends its pinned, messaging-enabled peers' boxes (`posta.py:175-193`), re-sent when the list's hash changes |
| `gonder <to>` | the letter bytes (§4.5) | `{"durum":"birakildi"}` | errors: `izin yok: alıcı bu bilgisayarı tanımıyor` (sender not in the recipient's `izinli`); `Zarf boş ya da çok büyük` (> **131072 bytes**); `dolu: ...` (recipient has ≥ 1000 envelopes or > 8 MiB) |
| `gonder <to> canli` | letter | same | also fails `cevrimdisi: ...` unless the recipient ran `al` within `POSTA_CANLI = 75` s (`araci.py:79`). Used for things worth nothing later |
| `al <N>` | `{"sil": [envelope ids]}` | `{"zarflar":[{"id","kimden","zaman","veri"}], "kalan": n}` | first deletes the listed envelopes, then marks the box online (`son = now`), then waits up to `min(N, 50)` s while polling every 1 s. Returns all waiting envelopes, oldest first, ≤ 4 MiB in total (at least one) |
| `ben <N>` | (keep open) | first line `{"ip": "...", "port": n}` | the source address and port of this SSH connection as the server sees them. Held open until stdin closes or `min(N,120)` s. Used for hole punching (§6) |
| `dosya-gonder <to> <session> <bytes>` | the file stream | `{"durum":"aktarildi","bayt":n}` | relay sender (§6.4) |
| `dosya-al <session>` | — | the raw stream | relay receiver (§6.4) |
| `kota` | — | `{"bugun","gunluk","en_cok"}` | relay quota |
| `davet <TAG>` / `davet-al` / `davet-yanit` / `davet-bekle <TAG> <N>` / `davet-iptal` | see §5 | | remote pairing |
| `aktar <to>` | — | `{"aktarim": session, "port": 47023}` | voice relay only |

Envelope storage on the server:
- One file per envelope: `kutu/<to>/<19-digit time_ns>-<from_box>.zarf`.
- The envelope `id` is that stem; `kimden` = characters 20 onward = **the sender's box address**; `zaman` =
  time_ns/1e9; `veri` = base64 of the stored bytes (`araci.py:587-590`, `620-621`).
- Envelopes older than **7 days** (`POSTA_OMUR`) are deleted when the box is next listed (`araci.py:542-552`).
- An envelope is deleted only when the recipient lists its id in the next `al`'s `sil`. Until then, it is
  delivered again on every `al`.

### 4.4 How peers learn each other's mailbox

- **On the LAN**: `POST /api/ileti/posta` (§3.7), triggered by the pump for pinned peers that are here
  (`ileti.py:1370-1374`).
- `needs_exchange` (`posta.py:246-253`) is true until the peer has both been told our current address
  (`bildirildi`) **and** given us its own. Retries come every 60 s after a failure (`bildirildi=""`), or every hour
  when we told ours but did not get theirs.
- **By remote pairing**: the invitation carries `adres` (§5).
- Stored in `~/.config/lifeos/ileti-posta/eslesme.json`: `{device_id: {adres, zaman, bildirildi, denendi}}`.
- `device_of(box)` maps an incoming `kimden` back to a device (`posta.py:81-83`). An envelope from an unknown box,
  or from a device with messaging off, is acknowledged and dropped (`ileti.py:835-838`).
- `ready(device)` = internet enabled, own box known, and peer box known (`posta.py:86-88`).

### 4.5 Letter formats (stdin of `gonder`)

**A message** (`ileti.py:620`):

```json
{"tur": "ileti", "zarf": { ...exactly the §3.3 envelope... }}
```

- The receiver opens it only if `zarf.box` is a string shorter than 200 000 characters (`ileti.py:843`).
- It then calls `_receive(device, zarf)`, where `device` is resolved from the server's `kimden`, not from the
  letter.
- It answers with a sealed `iletildi` letter `[id]` (`ileti.py:841-845`).
- The sender marks the message `sunucuda` once it is dropped in the box, and `iletildi` when that letter arrives
  (`ileti.py:627`, `785-794`).
- The total must be ≤ 128 KiB. That is easily met: 16 000 characters of text plus a ~0.5 KiB certificate, base64
  encoded.
- **Files never travel in a letter**. Only the `ek` record with its key does.

**Control letters** (`_tell_by_internet`, `ileti.py:878-892`):

```json
{"tur": "<kind>", "from": "<sender device id>", "box": "<b64 seal(pair key, JSON(value), aad = kind|from)>"}
```

`<kind>` is one of the kinds in §4.6. The receiver opens it with AAD `"<kind>|<device>"`, where `device` comes
from `kimden`, so `from` must equal the sender's real device id (`ileti.py:846-850`). It opens only when the
peer's certificate is already stored.

### 4.6 Control letter kinds

| kind | value | `canli`? | receiver action |
|---|---|---|---|
| `iletildi` | `[message ids]` | no | outgoing `sunucuda` → `iletildi` |
| `okundu` | `[message ids]` | no | → `okundu` |
| `hazir` | `[≤ 50 message ids]` whose files we still expect | yes | sender starts `delik.send_file` for each (`ileti.py:867-872`). Sent at most every 300 s per device, about 3 s after the box loop starts (`ileti.py:675-683`, `posta.py:269-286`) |
| `bulus` | `{"oturum": 32hex, "ileti": id, "adaylar": [[ip, port], ...]}` | yes | §6. Ignored if older than 60 s (`ileti.py:873-875`) |
| `bulus-yanit` | `{"oturum", "adaylar"}` | yes | §6 |
| `aktarim` | `{"oturum", "ileti"}` | yes | relay receive, §6.4. Ignored if older than 40 s |
| `dosya-tamam` | `[message ids]` | no | the relay file arrived; the sender marks it `tamam` with `yol: sunucu` |
| `arama` | voice signal | yes | ignored if older than 30 s |

### 4.7 The fetch loop ("al 45")

`posta.run` in `lifeos-yakin.service` (`posta.py:264-317`):

```
loop:
  if no box: register
  sync_allowed()                         # "izin", only when the list hash changed
  every 300 s: spawn tell_ready (hazir)
  got = al 45, stdin {"sil": done}       # timeout 45+90 s
  for each envelope: from_server(env); done += env.id   (also when it fails, so a bad one is never fetched twice)
  on error: backoff min(300, 15 * 2^min(failures, 5)) s
```

An online LifeOS keeps one `al` waiting at all times. A box counts as online for `canli` purposes while it fetched
within 75 s. **For a phone**, keeping this loop alive in the background costs an SSH exchange about every 45 s,
plus the radio wakeups. Without it, the phone is "offline" to the server: ordinary messages wait up to 7 days, and
every `canli` letter (bulus, aktarim, hazir, arama) fails with `cevrimdisi`. Android cannot get pushed without FCM,
so a foreground service (AnyWhere already has `flutter_foreground_task`) or periodic `al 0` polling when the app is
open are the realistic options **[inferred]**.

### 4.8 What the server can see

- Box addresses: sender, recipient, time, size.
- IP addresses: the source address is written to `gunluk.jsonl` as `kaynak` for logged events: box opening,
  invites, relays (`araci.py:135-140`). `gonder` and `al` are not logged, but sshd logs connections
  (`LogLevel VERBOSE`).
- Invitation tags.
- `ben` addresses.
- Relay byte counts.

It cannot read texts, names, certificates, file names or keys: all of these are inside sealed boxes.

---

## 5. Remote pairing by code (`ileti_uzak.py`, `araci.py:763-821`)

### 5.1 Code

- 16 characters from the Crockford base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, shown as `XXXX-XXXX-XXXX-XXXX`
  (`uzak.py:27`, `31-33`).
- Input normalisation (`uzak.py:36-41`): uppercase, remove `-` and spaces, map `O→0, I→1, L→1, U→V`, require
  exactly 16 characters from the alphabet.
- `TAG` = the first 4 characters, which the server sees; the server checks it with `^[0-9A-HJKMNP-TV-Z]{4}$`
  (`araci.py:94`).
- `secret` = the remaining **12 characters, as ASCII text** (60 bits). It is never sent anywhere.
- A code lasts `600` s and works once.

### 5.2 Invite key and sealing

`uzak.py:44-62`:

```
key  = HKDF-SHA256(ikm = secret.encode()  (the 12 ASCII chars), salt = None, info = b"lifeos-ileti-davet-1|" + TAG + b"|" + box)
blob = base64( seal(key, JSON(identity), aad = TAG) )          # §2.3 format, standard base64
```

`box` is the **sealer's own** mailbox address: the inviter's for the offer, the joiner's for the answer. The opener
uses the box address the server reports (`kimden` / `katilan`), which binds the box to the sealed contents.

### 5.3 Identity JSON (`_me`, `uzak.py:65-71`)

```json
{"id": "<device id>", "name": "<name>", "platform": "linux", "token": "<token>", "adres": "<own box>", "cert": "<b64 DER of own TLS cert>"}
```

### 5.4 Flow

| Inviter (`invite`, `wait_invite`) | Server | Joiner (`join`) |
|---|---|---|
| `_ready()`: crypto, internet on, own box. `token = secrets.token_urlsafe(24)`. `offer = seal(TAG, secret, myBox, _me(token))` | | |
| `davet <TAG>`, stdin offer (≤ 16 KiB ASCII) | stores `{kimden, teklif, zaman}`; `{"durum":"bekliyor","sure":600}`; error if the tag is in use | |
| | | `davet-al <TAG>` → `{"kimden": inviterBox, "teklif": offer}`. The server records `katilan = joinerBox`; a second joiner, or the inviter itself, is refused |
| | | `other = open(TAG, secret, kimden, teklif)`. A wrong code gives "Kod yanlış". `_take(other, kimden)` |
| | | `answer = seal(TAG, secret, myBox, {..._me(other.token), token: other.token})`, i.e. the **inviter's token** is echoed back |
| | | `davet-yanit <TAG>`, stdin answer → `{"durum":"tamam"}`. **The server adds each box to the other's `izinli`** (`araci.py:798-803`) |
| `davet-bekle <TAG> 45` (repeat): `{"durum":"bekliyor","katildi":bool}`, or `{"katilan": joinerBox, "yanit": answer}` (the invitation is then deleted) | | |
| `other = open(TAG, secret, katilan, yanit)`; require `other.token == my token`; `_take(other, katilan)` | | |
| `davet-iptal <TAG>` (optional) → `{"durum":"iptal"}` | | |

### 5.5 `_take(other, box)` (`uzak.py:84-106`): the resulting trust entry

- Checks: `other.id` is non-empty and is not my own id, and `other.adres == box`.
- `pin = sha256(DER(other.cert))`. If the device is already known with a different pin, the pairing is refused
  with `CHANGED`.
- The trust entry written to `yakin-guven.json` (`yakin.py:149-154`):

  ```json
  {"name": "<other.name[:80]>", "platform": "linux", "ip": "<known ip or ''>", "token": "<other.token>",
   "paired": "<ISO time>", "fingerprint": "<pin>", "uzak": true}
  ```

  Note that **`platform` is hard-coded `"linux"`**; `other.platform` is ignored. Both sides end up with **the same
  token**: the inviter's.
- Also: stores the certificate DER (`ileti-anahtar/<id>.der`), `learn(id, box)`, `told(id, myBox)`, and
  `sync_allowed`.
- Both screens show `pairing_code(myFp, pin)` (§2.1).
- With `uzak: true`, sharing folders and syncing are refused (`paylas.py:109-112`). Messages, files and calls are
  allowed.
- If the two later meet on a LAN, the trust entry already has a token and a pin. Ordinary pinned TLS works, but
  the peer has `ip: ""` until it is heard. `_deliver` waits for an IP or uses the mailbox (`ileti.py:555-557`).

### 5.6 Security notes [inferred]

- The server, or anyone holding a mailbox, can run `davet-al` on a tag it sees or guesses (20 bits). That takes
  the offer, which only allows an **offline** brute force of 60 bits against HKDF plus AEAD. It also blocks the real
  joiner (`katilan` is taken). The 6-digit code comparison is the backstop.

---

## 6. Direct file transfer over the internet (`ileti_delik.py`)

**Correction to the brief:** this is **TCP simultaneous open**, not UDP. UDP is only used by voice calls
(`araci.py:82`, `aktarici.py`).

### 6.1 Step 1: candidates (`delik.py:67-116`)

1. Pick a random local TCP port (40000–60999). Run `ssh ... -o ProxyCommand="python -I ileti_delik.py %h %p
   <port>" lifeos-ileti@server ben 75`. The ProxyCommand opens the TCP connection **from that bound local port**
   (`SO_REUSEADDR` + `SO_REUSEPORT`) and relays stdin/stdout (`delik.py:474-497`).
2. The first stdout line, `{"ip","port"}`, is the NAT mapping. Keep the ssh running, so the mapping stays alive.
3. Candidates = `[[public_ip, public_port]]` plus `[[v6, port]]` for up to 4 global IPv6 addresses (not fc/fd).

### 6.2 Steps 2–3: meeting and punching

Sender (`send_file`, `delik.py:221-283`):
1. Gathers its candidates.
2. Picks `session = 32 hex`.
3. Sends a sealed `bulus {oturum, ileti, adaylar}` with `canli`. If the receiver is not online, it stops; the next
   try comes later.
4. Waits ≤ 25 s for `bulus-yanit`. Without an answer it stops (**no relay fallback in this case**).
5. Runs `punch(port, their_candidates, 30 s, listen=False)`.

Receiver (`called`, `delik.py:424-470`):
1. Checks that the session is 32 hex characters, the message is known, and the file is not done yet.
2. Gathers its candidates.
3. Sends `bulus-yanit {oturum, adaylar}` with `canli`.
4. Runs `punch(..., listen=True)`.

`punch` (`delik.py:133-192`): from the same bound port, repeatedly connects without blocking to every candidate
and, on the receiver, also listens. The first connection that stands wins.

### 6.3 Step 4: transfer over the punched socket

Both sides send `HELLO = b"LIFEOS-ILETI-DOSYA-1 " + session + b"\n"` and require the same line from the other
(`delik.py:195-206`). Then:
1. The sender streams the §2.4 frames and calls `shutdown(SHUT_WR)`.
2. The receiver reads exactly `size + pieces*20` bytes into `_take_file`.
3. The receiver answers `b"OK\n"` or `b"HATA <reason>\n"`.
4. On `OK`, the sender marks the file `tamam`, `yol: dogrudan`.

### 6.4 Relay fallback (`by_server`, `delik.py:293-346`; server `araci.py:688-760`)

- **When it is used**: only when punching failed **after** a `bulus-yanit`.
- **Limits** (since 26.11.2026: 150 MiB per file, 300 MiB a day; AnyWhere `IletiPosta.relayLargest/relayDay`, the server's
  `araci.py` the same; LifeOS's `delik.py` still has the old values below until it is updated): `RELAY_LARGEST = 20 MiB` per file; `RELAY_DAY = 100 MiB` per sending box per UTC day, counted on both
  client and server. The server compares the `<bytes>` argument (= size + pieces*20) with 20 MiB. So a file of
  exactly 20 MiB passes the client's check but fails the server's ("buyuk") **[inferred]**.
- **Sender**:
  1. Starts `dosya-gonder <toBox> <session> <size+pieces*20>`. The server makes a FIFO and waits ≤ 45 s for the
     reader.
  2. Sends a sealed `aktarim {oturum, ileti}` with `canli`.
  3. Writes the frames to the ssh stdin and closes it.
  4. Expects `{"durum":"aktarildi","bayt":n}`.
  5. Marks the file `tamam` (`yol: sunucu`) only when `dosya-tamam [id]` arrives.
- **Receiver** (`take_by_server`, `delik.py:363-402`):
  1. Runs `dosya-al <session>` (stdin closed).
  2. Reads exactly `size+pieces*20` bytes of stdout into `_take_file`.
  3. On success, sends `dosya-tamam [id]`.
- Nothing is stored on the server, and the pieces stay sealed.

### 6.5 Retries and `hazir`

- Files are queued after the message went via the mailbox (`ileti.py:628-630`). The sender also retries every 300
  s while the receiver's box is ready (`ileti.py:1361-1363`).
- The receiver sends `hazir [ids]` when its box loop starts and every 300 s (§4.6), so the sender starts at once.
- If the two meet on the LAN, the pump uploads the file through `/api/ileti/ek` instead (`ileti.py:1359-1360`).

### 6.6 What a phone needs (assessment) [inferred]

Hole punching is the hardest part to port:
- Dart's `Socket.connect` cannot set `SO_REUSEPORT` before connecting, and it is uncertain whether a source port
  can be set at all, so verify `sourcePort` in the SDK you target.
- dartssh2 would need a custom `SSHSocket` built over that bound socket.
- Mobile carriers often use CGNAT, where punching rarely works anyway.

Recommendation:
- **Defer direct punching.**
- **Phone → LifeOS**: skip `bulus` altogether. Start `dosya-gonder`, then send `aktarim`. LifeOS's
  `take_by_server` accepts an `aktarim` for any known incoming message whose file is still `geliyor`
  (`delik.py:363-372`, `ileti.py:863-866`).
- **LifeOS → phone**: answer `bulus` with `bulus-yanit {"oturum": s, "adaylar": []}`. The sender's punch then finds
  nothing for 30 s and falls back to `by_server` (≤ 20 MiB), which sends `aktarim`. The phone then runs `dosya-al`.
  Larger files wait for the LAN.
- All of this needs the phone to be "online" (`al` within 75 s), because `bulus`, `aktarim` and `hazir` are
  `canli`.

---

## 7. SSH credentials and host key

- **Two kinds of key** (`araci.py:7-18`, `248-273`):
  1. **The shared joining key** for user `lifeos-kayit`. It is the same for every LifeOS install. It is an OpenSSH
     ed25519 private key committed in the repository at `catalog/destek/kayit`; the server holds its
     `kayit.pub` (`sunucu/destek/kur.sh:26`). It is shipped in the `lifeos` package and copied to
     `~/.config/lifeos/ileti-posta/kayit` with mode 0600 before use (`posta.py:122-126`; also
     `destek.py:114`, `883`, `1445`).
  2. **A per-user key** for user `lifeos-ileti`, made locally (§4.2). Only the box's own key can act on the box.
- **Host key**: a pinned ed25519 key from `sunucu.json` (§4.1). It is not trust-on-first-use. A phone should embed
  the same key and compare it in `onVerifyHostKey`.
- **What a phone needs to do the same**:
  - It needs the shared joining key, but only to open its box once (`kayit ileti <payload>`). It never needs it
    again unless the server forgets the box.
  - It generates its own ed25519 key (pinenacl, wrapped as dartssh2 `OpenSSHEd25519KeyPair`) and stores it in
    `flutter_secure_storage`.
  - It embeds the host key and the server address.
- **Security concerns with embedding the joining key in an APK**:
  - The key is already distributed with every LifeOS install. If `github.com/07erkanoz/LifeOSLinux` is public, it
    is in git history too; that was not checked. So an APK adds little new exposure. The real issue is that the
    key is effectively public.
  - What the joining key allows today: the `lifeos-kayit` forced command accepts `kayit` (**auto-accepted**
    registration of a "computer" in the remote-support list, `kabul: True`, `araci.py:319-335`), `giris` (a
    support person's email/password login, rate-limited to 5 per 15 min per email and per IP), `katil` (a team
    join request), and `ileti` (open a mailbox).
  - So anyone can create up to 50 000 boxes (filling the server's quota is a denial of service) and up to 5000
    support entries.
  - Rotating the key requires updating every client.
  - An APK is trivially unpacked.
  - **Recommendation (server change)**: a separate account, e.g. `lifeos-ileti-kayit`, whose forced command only
    accepts `ileti`, ideally with rate limiting per source IP in `open_mailbox`. Give AnyWhere that key instead of
    the support enrolment key. Alternatively, accept self-registration of a box: the box key proves possession on
    its first `lifeos-ileti` login. That would need an `AuthorizedKeysCommand` change, because unknown keys are
    currently rejected.
- **Other phone concerns**: the per-user key is a long-lived secret that identifies the box, so keep it in the
  keystore. Backups of app data would carry it.

---

## 8. Minimal compatible implementation checklist (by value)

### (a) LAN text chat both ways

1. Advertise `"ileti"` in Device JSON capabilities (`/api/info` and the UDP announce), next to `tls`. LifeOS does
   not need it today; it helps once §9.1 lands.
2. Pair key derivation (§2.2) and seal/open (§2.3), with Python-generated test vectors in
   `test/interop/lifeos_peer.py`.
3. Server: `POST /api/ileti` on the TLS listener.
   - Authenticate by `X-AnyWhere-Token` against a **pinned** trust entry; otherwise 403.
   - Validate `id` and `from == authenticated id` and the certificate against the pin; open the box with AAD
     `id|from`.
   - Store the message idempotently by id, answer `200 {"ok":true}`, and notify.
   - Answer 400 on any validation failure.
4. Server: `POST /api/ileti/okundu` → update outgoing states (`iletildi`/`sunucuda` → `okundu`), 200.
5. Server: `POST /api/ileti/posta`. A minimal answer is `{"ok":true,"adres":""}` after checking and storing
   `cert`. LifeOS then records `bildirildi = its box`, and `needs_exchange` drops from every 60 s (the 404 case)
   to once an hour, because the peer's `adres` is still empty (`ileti.py:826-827`, `posta.py:251-253`)
   **[inferred]**.
6. Server: `POST /api/ileti/arama` → `200 {"ok": false}` (no calls).
7. Client: queue (`bekliyor`) → `POST /api/ileti` to the peer over pinned TLS, with token and fingerprint headers.
   - 200 → `iletildi`.
   - Network error → retry when the peer is heard again (on a discovery packet or a periodic probe).
   - 403 / 404 / 400 → `hata`.
8. Client: when the user views the chat, `POST /api/ileti/okundu {"ids":[...]}` (optional setting).
9. Local encrypted store (§2.5) and UI states (§1.5). Text limit 16 000 characters.

### (b) LAN files in chat

1. Client: put the `ek` record (§1.3; random 32-byte key, 4-byte nonce prefix, sha256, mime, tur, optional `sure`)
   in the envelope. After 200, `POST /api/ileti/ek/<id>` with the §2.4 frames and an exact `Content-Length`.
2. Server: `POST /api/ileti/ek/<id>`.
   - Look up the incoming message from that device: 404 if missing; drain and 200 if already done.
   - Decrypt frame by frame (nonce = prefix‖n BE64, AAD `son`/`ara`), check the count, size and SHA-256.
   - Save, then 200; or 422 with the reason.
3. Shortcut until then: phone → LifeOS files can keep using `/api/send-request` + `/api/upload`. LifeOS shows them
   in the chat as transfers (§3.5). LifeOS → phone chat files **require** this endpoint while the phone is pinned
   (§0), unless §9.1 is applied.

### (c) Internet text via the mailbox

1. Embed the server address, port and host key (§4.1).
2. Joining key: see §7. Prefer a dedicated `ileti`-only key.
3. Generate an ed25519 box key, register (`lifeos-kayit`, `ileti <b64url {"anahtar"}>`), and check
   `adres == sha256(pub)[:32]`.
4. Answer `POST /api/ileti/posta` with the real box address, and call it on LifeOS peers when they are here (send
   `{adres, cert}`, store their `adres`).
5. Keep the allow list up to date: `izin` with the boxes of pinned, messaging-enabled peers.
6. Fetch loop: `al 45` with `{"sil": done}`. For each envelope, resolve `kimden` to a device; handle
   `tur:"ileti"`, then send `iletildi [id]`. Handle `iletildi` and `okundu`. Acknowledge every envelope, even ones
   that fail.
7. Send: if the peer is not here and both boxes are known, `gonder <peerBox>` with `{"tur":"ileti","zarf":envelope}`
   (≤ 128 KiB) → `sunucuda`. `okundu` receipts go as sealed letters when the peer is away.
8. Decide the background policy (a foreground service vs polling while the app is open).

### (d) Remote pairing by code

1. Code generation and normalisation, invite key (§5.2), identity JSON (§5.3, with the phone's own
   `platform`, e.g. `"android"`; LifeOS ignores it, §9.5).
2. Both roles: `davet`/`davet-bekle`/`davet-iptal` (inviter) and `davet-al`/`davet-yanit` (joiner).
3. `_take` equivalent: pin the certificate, store the token (the inviter's), the box, `uzak: true`, and the stored
   DER. Show the 6-digit code.

### (e) Internet files

1. Relay only (§6.6): `dosya-gonder` + `aktarim` as sender; `bulus-yanit` with empty candidates, then
   `aktarim` → `dosya-al` as receiver; `dosya-tamam`. Send `hazir` for files still expected.
2. Later, if ever: TCP simultaneous open with `ben` over a bound port (§6.1–6.3).

Voice calls (`ileti_arama.py`), skipped:
- Ringing goes as `POST /api/ileti/arama` (plain JSON inside TLS) or a sealed `arama` letter with `canli`, carrying
  a per-call 32-byte key and UDP candidates.
- Media: one UDP socket, the server's `aktarici.py` on 47023/udp for address discovery (`LIA?`) and relay
  (`aktar`), Opus at 32–40 kbit/s in RTP, each packet sealed with ChaCha20-Poly1305 under the call key, the nonce
  made of direction and packet number.
- A phone would need: a UDP socket with STUN-like discovery against `aktarici.py`, an Opus encoder/decoder with echo
  cancellation (`flutter_webrtc` is already a dependency, but its own SRTP/ICE stack is not wire-compatible, so
  raw audio capture plus an Opus codec would be needed), a jitter buffer, and the same `canli` reachability. This
  is a large separate project.

---

## 9. LifeOS-side changes worth making (not made)

1. **Route phones by capability, not only by pin.**
   - `ileti.py:356`, `466`: treat a peer as a chat peer only if it is `_secure_peer` **and** (platform not in
     `yakin.MOBILE` **or** it advertises `"ileti"`).
   - The capability is only in memory (`_State.peers`, `yakin.py:811-813`, `849-851`). Persist it in the trust
     entry when heard, e.g. `ileti: true`, so that away or remote phones still route correctly.
   - Until then, pinned AnyWhere 1.2 phones get `hata` instead of clipboard or file delivery (§0).
2. `ileti.py:576-577`: on 404/501 from a peer whose platform is in `MOBILE`, fall back to `_to_clipboard` /
   `yakin.send_files` instead of failing.
3. `ileti.py:1370-1374` with `posta.py:246-253`: do not run `exchange()` against peers that do not advertise
   `"ileti"`. Today it means a 404 every 60 s to the phone. Also consider `MOBILE_EVERY`-style throttling
   (`yakin.py:51-55`).
4. `ileti.py:1125` (`canMessage`) and `apps/ileti/lifeos_ileti/qml/Konusma.qml:17`, `68-70`: base the chat UI on
   the same rule as item 1. The phone-specific UI branch (`chat.phone`) already exists.
5. `uzak.py:70` and `uzak.py:95`: use `other.get("platform")` instead of the hard-coded `"linux"`, so a remotely
   paired phone is labelled and throttled as mobile.
6. `ileti_arama.py:549-559` and the call button: offer calls only to peers that support them. A phone without
   calls should answer `/api/ileti/arama` with `{"ok": false}`. A capability such as `"ileti-arama"` would be
   cleaner.
7. Server (`araci.py:309-318`, `248-253`): a dedicated `ileti`-only enrolment account and key for AnyWhere, and
   rate limiting in `open_mailbox` (§7).
8. `docs/ileti.md:48-52`: describes phones as clipboard-only, which is no longer what the code does for pinned
   phones.
9. Optional: `delik.py:242-243`: fall back to `by_server` when `bulus-yanit` never comes. Today a receiver that
   cannot answer means no transfer at all.
10. Optional: `delik.py:299` vs `araci.py:695`: compare the same quantity (raw size vs size + overhead) at the 20
    MiB boundary.
