import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/ileti/data/ileti_crypto.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

final _log = AppLogger('IletiLan');

/// Where a paired device is on this network right now: (ip, port), or null.
typedef IletiAddress = (String, int)? Function(String device);

/// LifeOS İleti on the local network (docs/ileti-protokol.md §3), both ways:
/// sealed envelopes to `/api/ileti`, files as sealed pieces to
/// `/api/ileti/ek/<id>`, read receipts to `/api/ileti/okundu`. Only with a
/// device paired with encryption, over pinned TLS.
class IletiLan implements IletiTransport {
  IletiLan({
    required this.trustStore,
    required this.myId,
    required this.myName,
    required this.addressOf,
    required this.certDir,
    required this.incomingDir,
  });

  final TrustStore trustStore;
  final String myId;
  final String Function() myName;
  final IletiAddress addressOf;

  /// Paired devices' certificates (their public keys make the pair key).
  final Directory certDir;

  /// Where files of [device] land.
  final Future<Directory> Function(TrustedDevice device) incomingDir;

  // what the app does with what comes in
  void Function(IletiMessage message)? onMessage;
  void Function(String device, String id, double progress)? onFileProgress;
  void Function(String device, String id, String path)? onFileDone;
  void Function(String device, String id, String error)? onFileFailed;
  void Function(String device, List<String> ids)? onRead;

  /// Incoming files' keys until the file comes (envelope → /ek). Kept on
  /// disk: a file announced over the internet comes later, on the network.
  late final Map<String, Map<String, dynamic>> _expected = _loadExpected();

  File get _expectedFile => File('${certDir.parent.path}/beklenen-dosyalar.json');

  Map<String, Map<String, dynamic>> _loadExpected() {
    try {
      final raw = jsonDecode(_expectedFile.readAsStringSync()) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      return {};
    }
  }

  void _saveExpected() {
    _expectedFile.parent.createSync(recursive: true);
    _expectedFile.writeAsStringSync(jsonEncode(_expected));
  }

  static final RegExp uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  @override
  IletiVia get via => IletiVia.lan;

  @override
  bool canReach(String device) =>
      (trustStore.byId(device)?.isPinned ?? false) && addressOf(device) != null;

  // ── keys ──────────────────────────────────────────────────────────────

  TlsIdentity get _me {
    final me = TlsIdentity.current;
    if (me == null) throw StateError('no TLS identity');
    return me;
  }

  static Uint8List _derOfPem(String pem) => base64.decode(
        pem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join(),
      );

  File _certFile(String device) =>
      File('${certDir.path}/${device.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.der');

  /// The peer's certificate, only when it is the pinned one.
  Uint8List? _peerCert(TrustedDevice peer) {
    final pin = peer.fingerprint;
    if (pin == null) return null;
    final f = _certFile(peer.id);
    if (f.existsSync()) {
      final der = f.readAsBytesSync();
      if (TlsIdentity.fingerprintOf(der) == pin) return der;
    }
    final met = PeerTls.instance.certFor(pin);
    if (met != null) _keepCert(peer.id, met);
    return met;
  }

  /// Keeps [device]'s certificate (remote pairing hands it over sealed).
  void keepCert(String device, Uint8List der) => _keepCert(device, der);

  void _keepCert(String device, Uint8List der) {
    certDir.createSync(recursive: true);
    _certFile(device).writeAsBytesSync(der);
  }

  final Map<String, Uint8List> _keys = {};

  Uint8List _pairKey(TrustedDevice peer, Uint8List peerCert) {
    return _keys[peer.id] ??= IletiCrypto.pairKey(
      myPrivate: IletiCrypto.privateScalarFromPem(_me.privateKeyPem),
      peerCertDer: peerCert,
      myFingerprint: _me.fingerprint,
      peerFingerprint: peer.fingerprint!,
    );
  }

  // ── sending ───────────────────────────────────────────────────────────

  Map<String, String> _headers(String device, [String type = 'application/json']) => {
        'Content-Type': type,
        ...trustStore.authHeaders(device),
      };

  Uri _uri(TrustedDevice peer, String path) {
    final (ip, port) = addressOf(peer.id)!;
    return PeerTls.instance.uriFor(ip, port, path, deviceId: peer.id, tls: true);
  }

  Future<Uint8List> _ensureCert(TrustedDevice peer) async {
    var cert = _peerCert(peer);
    if (cert != null) return cert;
    // any TLS request meets its certificate (checked against the pin)
    await PeerTls.instance.shared.get(_uri(peer, '/api/info')).timeout(const Duration(seconds: 6));
    cert = _peerCert(peer);
    if (cert == null) throw StateError('${peer.name}: certificate not met');
    return cert;
  }

  @override
  Future<IletiMessage> deliver(IletiMessage m) async {
    final peer = trustStore.byId(m.device);
    if (peer == null || !peer.isPinned) throw StateError('not paired with encryption');
    final key = _pairKey(peer, await _ensureCert(peer));

    final ek = m.isFile ? await fileRecord(m) : null;
    final envelope = envelopeFor(m, key, ek);
    final r = await PeerTls.instance.shared
        .post(_uri(peer, '/api/ileti'), headers: _headers(peer.id), body: jsonEncode(envelope))
        .timeout(const Duration(seconds: 10));
    _check(r, peer);
    if (ek != null) await uploadFile(m, ek);
    return m.copyWith(status: IletiStatus.sent, via: IletiVia.lan, clearProgress: true);
  }

  /// The `ek` record of a file message (§1.3): its own random key and nonce
  /// prefix, size, kind and hash. The same record goes with the envelope and
  /// seals the pieces, whichever way the file then travels.
  static Future<Map<String, dynamic>> fileRecord(IletiMessage m) async {
    final file = File(m.filePath ?? '');
    if (!file.existsSync()) throw StateError('file gone: ${m.filePath}');
    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    return {
      'name': m.fileName,
      'size': await file.length(),
      'mime': mime,
      'tur': mime.startsWith('image/')
          ? 'gorsel'
          : mime.startsWith('video/')
              ? 'video'
              : mime.startsWith('audio/')
                  ? 'ses'
                  : 'dosya',
      'key': IletiCrypto.b64(IletiCrypto.random(32)),
      'nonce': IletiCrypto.b64(IletiCrypto.random(4)),
      // a whole file through sha256: not on the UI isolate
      'sha256': await _sha256Of(file.path),
    };
  }

  static Future<String> _sha256Of(String path) =>
      Isolate.run(() async => (await crypto.sha256.bind(File(path).openRead()).first).toString());

  /// The file's sealed pieces (§2.4), as one stream; [onProgress] 0..1.
  /// Each piece is sealed on another isolate while the one before it goes.
  static Stream<List<int>> sealedFrames(String path, Map<String, dynamic> ek, {void Function(double)? onProgress}) async* {
    final key = base64.decode('${ek['key']}');
    final prefix = base64.decode('${ek['nonce']}');
    final file = File(path);
    final total = IletiCrypto.pieces(await file.length());
    final raf = await file.open();
    Future<Uint8List>? ahead;
    try {
      for (var n = 0; n < total; n++) {
        final block = await raf.read(IletiCrypto.chunk);
        final sealing = IletiCrypto.frameAsync(key, prefix, n, total, block);
        if (ahead != null) {
          yield await ahead;
          onProgress?.call(n / total);
        }
        ahead = sealing;
      }
      if (ahead != null) {
        final last = ahead;
        ahead = null;
        yield await last;
        onProgress?.call(1);
      }
    } finally {
      ahead?.ignore();
      await raf.close();
    }
  }

  /// `POST /api/ileti/ek/<id>`: the file of [m] to its device on this network.
  Future<void> uploadFile(IletiMessage m, Map<String, dynamic> ek) async {
    final peer = trustStore.byId(m.device)!;
    final size = (ek['size'] as num).toInt();
    final request = http.StreamedRequest('POST', _uri(peer, '/api/ileti/ek/${m.id}'))
      ..headers.addAll(_headers(peer.id, 'application/octet-stream'))
      ..contentLength = IletiCrypto.streamLength(size);
    final sending = PeerTls.instance.shared.send(request).timeout(const Duration(seconds: 600));
    await sealedFrames(m.filePath!, ek, onProgress: (p) => onFileProgress?.call(m.device, m.id, p))
        .forEach(request.sink.add);
    await request.sink.close();
    _check(await http.Response.fromStream(await sending), peer);
  }

  /// The sealed envelope of [m] (§3.3): the same on the LAN and in a mailbox letter.
  Map<String, dynamic> envelopeFor(IletiMessage m, Uint8List key, [Map<String, dynamic>? ek]) {
    final wire = {
      'text': m.text,
      'sent': m.time.millisecondsSinceEpoch / 1000.0,
      'ek': ?ek,
    };
    return {
      'v': 1,
      'id': m.id,
      'from': myId,
      'name': myName(),
      'cert': IletiCrypto.b64(myCertDer),
      'box': IletiCrypto.b64(IletiCrypto.seal(key, utf8.encode(jsonEncode(wire)), utf8.encode('${m.id}|$myId'))),
    };
  }

  /// This device's certificate (DER).
  Uint8List get myCertDer => _derOfPem(_me.certificatePem);

  /// The pair key with [peer], when its certificate is known here (met on a
  /// network or sent in a message); null otherwise.
  Uint8List? pairKeyFor(TrustedDevice peer) {
    final cert = _peerCert(peer);
    return cert == null ? null : _pairKey(peer, cert);
  }

  void _check(http.Response r, TrustedDevice peer) {
    if (r.statusCode == 200) return;
    final why = utf8.decode(r.bodyBytes, allowMalformed: true);
    throw StateError('${peer.name}: ${r.statusCode} $why');
  }

  /// Tells [device] these messages were read here.
  Future<void> sendRead(String device, List<String> ids) async {
    final peer = trustStore.byId(device);
    if (peer == null || !peer.isPinned || ids.isEmpty || addressOf(device) == null) return;
    try {
      await PeerTls.instance.shared
          .post(_uri(peer, '/api/ileti/okundu'), headers: _headers(device), body: jsonEncode({'ids': ids}))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      _log.debug('read receipt to ${peer.name}: $e');
    }
  }

  // ── receiving (the server's /api/ileti*) ──────────────────────────────

  /// `POST /api/ileti`: a sealed message from [peer] (authenticated).
  Future<(int, Object)> receiveEnvelope(
    TrustedDevice peer,
    Map<String, dynamic> env, {
    IletiVia via = IletiVia.lan,
  }) async {
    final id = '${env['id'] ?? ''}';
    if (!uuid.hasMatch(id) || env['from'] != peer.id) return (400, 'gecersiz zarf');
    final cert = base64.decode('${env['cert'] ?? ''}');
    if (TlsIdentity.fingerprintOf(cert) != peer.fingerprint) return (400, 'sertifika tutmuyor');
    _keepCert(peer.id, cert);
    final Map<String, dynamic> wire;
    try {
      final plain = IletiCrypto.open(
        _pairKey(peer, cert),
        base64.decode('${env['box']}'),
        utf8.encode('$id|${peer.id}'),
      );
      wire = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      return (400, 'çözülemedi');
    }
    final text = '${wire['text'] ?? ''}';
    final sent = (wire['sent'] as num?)?.toDouble();
    final ek = wire['ek'] as Map<String, dynamic>?;
    if (ek != null) {
      _expected['${peer.id}|$id'] = ek;
      _saveExpected();
    }
    onMessage?.call(IletiMessage(
      id: id,
      device: peer.id,
      outgoing: false,
      time: sent == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch((sent * 1000).round()),
      text: text.length > 16000 ? text.substring(0, 16000) : text,
      fileName: ek == null ? null : _safeName('${ek['name'] ?? 'dosya'}'),
      fileSize: (ek?['size'] as num?)?.toInt(),
      status: IletiStatus.unread,
      via: via,
      progress: ek == null || via != IletiVia.lan ? null : 0,
    ));
    return (200, {'ok': true});
  }

  static String _safeName(String name) {
    final last = name.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
    return last.isEmpty || last == '.' || last == '..' ? 'dosya' : last;
  }

  /// `POST /api/ileti/ek/<id>`: the file of a message, as sealed pieces.
  /// Whether the file of message [id] from [device] is still expected here.
  bool expects(String device, String id) => _expected.containsKey('$device|$id');

  /// The messages from [device] whose file is still expected.
  List<String> expectedFrom(String device) => [
        for (final k in _expected.keys)
          if (k.startsWith('$device|')) k.substring(device.length + 1),
      ];

  Future<(int, Object)> receiveFile(
    TrustedDevice peer,
    String id,
    Stream<List<int>> body, {
    void Function(String device, String id, double progress)? progressOf,
  }) async {
    final progress = progressOf ?? onFileProgress;
    final ek = _expected['${peer.id}|$id'];
    if (ek == null) {
      await body.drain<void>();
      return (404, 'ileti yok');
    }
    final size = (ek['size'] as num).toInt();
    final key = base64.decode('${ek['key']}');
    final prefix = base64.decode('${ek['nonce']}');
    final total = IletiCrypto.pieces(size);
    final dir = await incomingDir(peer);
    await dir.create(recursive: true);
    final part = File('${dir.path}/.ileti-$id.part');
    final sink = part.openWrite();
    final digest = _Sha256Sink();
    final hasher = crypto.sha256.startChunkedConversion(digest);
    // the bytes not yet taken; joined only once a whole frame is in (joining
    // on every network chunk copied each 1 MiB piece a dozen times)
    final buffer = BytesBuilder(copy: false);
    int? need; // 4 + the next frame's length, once its head is in
    var n = 0;
    var written = 0;
    try {
      await for (final chunk in body) {
        buffer.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        while (true) {
          if (need == null) {
            if (buffer.length < 4) break;
            final bytes = buffer.takeBytes();
            final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
            if (len < 16 || len > IletiCrypto.chunk + 16) throw const FormatException('parça boyu yanlış');
            need = 4 + len;
            buffer.add(bytes);
          }
          final frameLength = need!;
          if (buffer.length < frameLength) break;
          if (n >= total) throw const FormatException('fazla parça');
          final bytes = buffer.takeBytes();
          if (bytes.length > frameLength) buffer.add(Uint8List.sublistView(bytes, frameLength));
          need = null;
          final plain = await IletiCrypto.openPieceAsync(
            key,
            prefix,
            n,
            n == total - 1,
            Uint8List.sublistView(bytes, 4, frameLength),
          );
          sink.add(plain);
          hasher.add(plain);
          written += plain.length;
          n++;
          progress?.call(peer.id, id, n / total);
        }
      }
      if (buffer.isNotEmpty || need != null) throw const FormatException('eksik parça');
      await sink.close();
      hasher.close();
      if (n != total || written != size) throw const FormatException('eksik dosya');
      final want = '${ek['sha256'] ?? ''}';
      if (want.isNotEmpty && digest.value.toString() != want) throw const FormatException('özet tutmuyor');
      final target = _freeName(dir, _safeName('${ek['name'] ?? 'dosya'}'));
      await part.rename(target.path);
      _expected.remove('${peer.id}|$id');
      _saveExpected();
      onFileDone?.call(peer.id, id, target.path);
      return (200, {'ok': true});
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (part.existsSync()) await part.delete();
      onFileFailed?.call(peer.id, id, '$e');
      return (422, '$e');
    }
  }

  static File _freeName(Directory dir, String name) {
    var f = File('${dir.path}/$name');
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 2; f.existsSync(); i++) {
      f = File('${dir.path}/$stem ($i)$ext');
    }
    return f;
  }

  /// `POST /api/ileti/okundu`
  (int, Object) receiveRead(TrustedDevice peer, Map<String, dynamic> body) {
    final ids = (body['ids'] as List? ?? const []).map((e) => '$e').take(2000).toList();
    onRead?.call(peer.id, ids);
    return (200, {'ok': true});
  }

  /// `POST /api/ileti/posta`: the peer's certificate (and mailbox address,
  /// when this device has one; the internet route is not here yet).
  (int, Object) receivePosta(TrustedDevice peer, Map<String, dynamic> body) {
    final cert = base64.decode('${body['cert'] ?? ''}');
    if (TlsIdentity.fingerprintOf(cert) != peer.fingerprint) return (400, 'sertifika tutmuyor');
    _keepCert(peer.id, cert);
    final adres = '${body['adres'] ?? ''}';
    if (adres.isNotEmpty && !RegExp(r'^[0-9a-f]{32}$').hasMatch(adres)) return (400, 'adres gecersiz');
    onPeerBox?.call(peer.id, adres);
    return (200, {'ok': true, 'adres': myBox?.call() ?? ''});
  }

  /// This device's mailbox address ('' / null when it has none).
  String? Function()? myBox;

  /// A peer told its mailbox address.
  void Function(String device, String adres)? onPeerBox;

  /// Tells [device] this device's mailbox and certificate, learns its own
  /// (`POST /api/ileti/posta`, §3.7). Returns its address ('' if none).
  Future<String> exchangeBoxes(String device) async {
    final peer = trustStore.byId(device);
    if (peer == null || !peer.isPinned || addressOf(device) == null) throw StateError('not here');
    await _ensureCert(peer);
    final r = await PeerTls.instance.shared
        .post(
          _uri(peer, '/api/ileti/posta'),
          headers: _headers(device),
          body: jsonEncode({'adres': myBox?.call() ?? '', 'cert': IletiCrypto.b64(myCertDer)}),
        )
        .timeout(const Duration(seconds: 10));
    _check(r, peer);
    final theirs = '${(jsonDecode(utf8.decode(r.bodyBytes)) as Map)['adres'] ?? ''}';
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(theirs)) onPeerBox?.call(device, theirs);
    return theirs;
  }
}

class _Sha256Sink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
