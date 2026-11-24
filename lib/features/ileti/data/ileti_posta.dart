import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:pointycastle/digests/md5.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/ileti/data/ileti_crypto.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

final _log = AppLogger('IletiPosta');

/// The LifeOS support server's İleti mailbox (docs/ileti-protokol.md §4).
class IletiServer {
  const IletiServer({
    this.host = '87.121.104.192',
    this.port = 47022,
    this.hostKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVH7XCCIG6E4sGggYK4/l+FAsKGUC47fC682lJGFGdb',
  });

  final String host;
  final int port;

  /// Pinned (catalog/destek/sunucu.json); a server showing another key is refused.
  final String hostKey;
}

/// LifeOS İleti over the internet: written messages through this user's box
/// on the LifeOS server, sealed for the other device alone (the server sees
/// which boxes write to which, never what). The box is opened with the
/// phone's own ed25519 key through `lifeos-ileti-ac`: no shared key is in the
/// app. Files do not go this way (they wait for the same network).
class IletiPosta implements IletiTransport {
  IletiPosta({
    required this.lan,
    required this.trustStore,
    required this.stateFile,
    this.server = const IletiServer(),
    FlutterSecureStorage? secure,
  }) : _secure = secure ?? const FlutterSecureStorage();

  final IletiLan lan;
  final TrustStore trustStore;

  /// posta.json: own address, the peers' addresses, what was told.
  final File stateFile;
  final IletiServer server;
  final FlutterSecureStorage _secure;

  void Function(IletiMessage message)? onMessage;
  void Function(String device, List<String> ids)? onDelivered;
  void Function(String device, List<String> ids)? onRead;

  /// A file of ours arrived there through the server ("dosya-tamam").
  void Function(String device, String id)? onFileSent;

  /// A file is moving through the server (either way): 0..1.
  void Function(String device, String id, double progress)? onFileProgress;

  /// A file came in through the server.
  void Function(String device, String id)? onFileRelayed;

  /// A file of ours cannot go through the server (too big): it waits for the network.
  void Function(String device, String id, String why)? onFileWaits;

  /// Who is online, by device: (online now, last seen).
  void Function(Map<String, (bool, DateTime?)> presence)? onPresence;

  /// The server passes a file on only up to this (sealed size), 100 MiB a day.
  static const int relayLargest = 20 * 1024 * 1024;

  /// Turned off: nothing goes to or comes from the server.
  bool enabled = true;

  late final Map<String, dynamic> _state = _read();
  OpenSSHEd25519KeyPair? _key;
  String? _public;
  bool _running = false;
  int _failures = 0;

  static final RegExp _box = RegExp(r'^[0-9a-f]{32}$');

  @override
  IletiVia get via => IletiVia.internet;

  // ── state ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _read() {
    try {
      if (stateFile.existsSync()) return jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    return {};
  }

  void _save() {
    stateFile.parent.createSync(recursive: true);
    final temp = File('${stateFile.path}.tmp')..writeAsStringSync(jsonEncode(_state), flush: true);
    temp.renameSync(stateFile.path);
  }

  Map<String, dynamic> get _peers => (_state['eslesme'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  /// This device's box address, once opened.
  String? get myBox => _state['adres'] as String?;

  String? boxOf(String device) => (_peers[device] as Map?)?['adres'] as String?;

  String? deviceOf(String box) =>
      _peers.entries.where((e) => (e.value as Map)['adres'] == box).map((e) => e.key).firstOrNull;

  void peerBox(String device, String adres) {
    if (adres.isNotEmpty && !_box.hasMatch(adres)) return;
    final row = (_peers[device] ??= <String, dynamic>{}) as Map<String, dynamic>;
    if (row['adres'] == adres) return;
    row['adres'] = adres;
    _save();
    // it may write here from now on (the waiting fetch would tell the server only after it returns)
    if (_running && myBox != null) unawaited(_syncAllowed().catchError((Object _) {}));
  }

  /// Whether [device] still needs to learn our box or tell us its own.
  bool needsExchange(String device) {
    final row = _peers[device] as Map?;
    return myBox != null && (row == null || row['bildirildi'] != myBox || row['adres'] == null);
  }

  void told(String device) {
    ((_peers[device] ??= <String, dynamic>{}) as Map<String, dynamic>)['bildirildi'] = myBox;
    _save();
  }

  // ── keys and the server ───────────────────────────────────────────────

  Future<void> _ensureKey() async {
    if (_key != null) return;
    String? seed;
    try {
      seed = await _secure.read(key: 'ileti_posta_anahtar');
    } catch (_) {}
    final file = File('${stateFile.parent.path}/.posta-anahtar');
    seed ??= file.existsSync() ? file.readAsStringSync().trim() : null;
    if (seed == null || seed.isEmpty) {
      seed = base64.encode(nacl.SigningKey.generate().seed);
      try {
        await _secure.write(key: 'ileti_posta_anahtar', value: seed);
      } catch (_) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(seed);
        if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
      }
    }
    final signing = nacl.SigningKey.fromSeed(base64.decode(seed));
    final pub = Uint8List.fromList(signing.verifyKey.asTypedList);
    _key = OpenSSHEd25519KeyPair(pub, Uint8List.fromList([...base64.decode(seed), ...pub]), 'lifeos-anywhere');
    final blob = BytesBuilder()
      ..add(_sshString(utf8.encode('ssh-ed25519')))
      ..add(_sshString(pub));
    _public = 'ssh-ed25519 ${base64.encode(blob.toBytes())}';
  }

  static List<int> _sshString(List<int> b) => [
        ...(ByteData(4)..setUint32(0, b.length)).buffer.asUint8List(),
        ...b,
      ];

  /// The address the server gives this key (and only it): sha256(public)[:32].
  String get expectedAddress => crypto.sha256.convert(utf8.encode(_public!)).toString().substring(0, 32);

  bool _hostOk(String type, Uint8List fingerprint) {
    final parts = server.hostKey.split(' ');
    if (type != parts[0]) return false;
    final want = MD5Digest().process(base64.decode(parts[1]));
    if (want.length != fingerprint.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= want[i] ^ fingerprint[i];
    }
    return diff == 0;
  }

  /// One command on the server as [user]: [words], [input] on stdin; the
  /// JSON object it answers (its last line). Throws on `{"hata": …}`.
  Future<Map<String, dynamic>> _run(
    String user,
    String words, {
    String input = '',
    Duration timeout = const Duration(seconds: 40),
  }) async {
    await _ensureKey();
    final socket = await SSHSocket.connect(server.host, server.port, timeout: const Duration(seconds: 15));
    final client = SSHClient(
      socket,
      username: user,
      identities: [_key!],
      onVerifyHostKey: _hostOk,
      keepAliveInterval: const Duration(seconds: 30),
    );
    try {
      final session = await client.execute(words).timeout(timeout);
      session.stdin.add(utf8.encode(input));
      await session.stdin.close();
      final out = await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final last = out.trim().split('\n').where((l) => l.trim().startsWith('{')).lastOrNull;
      if (last == null) throw StateError('sunucu yanıt vermedi');
      final reply = jsonDecode(last) as Map<String, dynamic>;
      if (reply['hata'] != null) throw StateError('${reply['hata']}');
      return reply;
    } finally {
      client.close();
    }
  }

  /// Opens this key's box if need be (no shared key: `lifeos-ileti-ac`).
  Future<String> _ensureBox() async {
    await _ensureKey();
    final known = myBox;
    if (known != null && known == expectedAddress) return known;
    final reply = await _run('lifeos-ileti-ac', 'ac');
    final adres = '${reply['adres'] ?? ''}';
    if (adres != expectedAddress) throw StateError('sunucu başka bir adres verdi');
    _state['adres'] = adres;
    _save();
    return adres;
  }

  /// Boxes that may write here: the paired devices with encryption whose box is known.
  Future<void> _syncAllowed() async {
    final boxes = <String>[
      for (final e in _peers.entries)
        if (trustStore.byId(e.key)?.isPinned ?? false)
          if (_box.hasMatch('${(e.value as Map)['adres'] ?? ''}')) (e.value as Map)['adres'] as String,
    ]..sort();
    final mark = crypto.sha256.convert(utf8.encode(boxes.join(','))).toString();
    if (_state['izin'] == mark) return;
    await _run('lifeos-ileti', 'izin', input: jsonEncode(boxes));
    _state['izin'] = mark;
    _save();
  }

  /// For remote pairing (ileti_uzak.dart): a command as `lifeos-ileti`.
  Future<Map<String, dynamic>> command(String words, {String input = '', Duration? timeout}) =>
      _run('lifeos-ileti', words, input: input, timeout: timeout ?? const Duration(seconds: 40));

  /// This device's box, opened if need be.
  Future<String> ensureBox() => _ensureBox();

  /// Tells the server again which boxes may write here.
  Future<void> syncAllowed() async {
    _state.remove('izin');
    await _syncAllowed();
  }

  // ── sending ───────────────────────────────────────────────────────────

  @override
  bool canReach(String device) {
    if (!enabled || myBox == null || boxOf(device) == null || !_box.hasMatch(boxOf(device)!)) return false;
    final peer = trustStore.byId(device);
    return peer != null && peer.isPinned && lan.pairKeyFor(peer) != null;
  }

  @override
  Future<IletiMessage> deliver(IletiMessage m) async {
    final peer = trustStore.byId(m.device)!;
    final key = lan.pairKeyFor(peer)!;
    // a file: its record (name, size, its own key) goes in the letter; the file itself after, through the server
    final ek = m.isFile ? await IletiLan.fileRecord(m) : null;
    final letter = jsonEncode({'tur': 'ileti', 'zarf': lan.envelopeFor(m, key, ek)});
    if (letter.length > 131072) throw StateError('ileti sunucu için çok büyük');
    await _run('lifeos-ileti', 'gonder ${boxOf(m.device)}', input: letter);
    if (ek != null) {
      _outgoing[m.id] = {'device': m.device, 'path': m.filePath, 'ek': ek};
      _save();
      unawaited(sendFile(m.id));
    }
    return m.copyWith(status: IletiStatus.onServer, via: IletiVia.internet);
  }

  /// Files whose letter went through the server and which still have to go:
  /// id → {device, path, ek}.
  Map<String, dynamic> get _outgoing => (_state['dosyalar'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  /// The waiting file of message [id] (its record), if any: the network can
  /// take it too when the two meet (IletiLan.uploadFile).
  Map<String, dynamic>? waitingFile(String id) => (_outgoing[id] as Map?)?.cast<String, dynamic>();

  /// It went another way (the network): no longer waits here.
  void fileGone(String id) {
    if (_outgoing.remove(id) != null) _save();
  }

  final Set<String> _sending = {};

  /// Passes the file of message [id] on through the server (§6.4): the
  /// sealed pieces stream to it, the other device takes them as they come;
  /// nothing is stored there. Needs the other device online.
  Future<void> sendFile(String id) async {
    final row = waitingFile(id);
    if (row == null || !_sending.add(id)) return;
    final device = '${row['device']}';
    final ek = Map<String, dynamic>.from(row['ek'] as Map);
    try {
      final sealed = IletiCrypto.streamLength((ek['size'] as num).toInt());
      if (sealed > relayLargest) {
        onFileWaits?.call(device, id, 'büyük');
        return;
      }
      final to = boxOf(device);
      if (to == null) return;
      final session = List.generate(16, (_) => (IletiCrypto.random(1)[0]).toRadixString(16).padLeft(2, '0')).join();
      // the server makes the way and waits up to 45 s for the reader; the other side is told to read
      final sending = _stream(
        'lifeos-ileti',
        'dosya-gonder $to $session $sealed',
        IletiLan.sealedFrames('${row['path']}', ek, onProgress: (p) => onFileProgress?.call(device, id, p)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tell(device, 'aktarim', {'oturum': session, 'ileti': id}, live: true);
      final done = await sending;
      if (done['durum'] != 'aktarildi') throw StateError('$done');
      // it counts as there when the other side says so (dosya-tamam)
    } catch (e) {
      _log.info('file $id through the server: $e (again when it is online)');
    } finally {
      _sending.remove(id);
    }
  }

  /// A command whose stdin is [input] streamed (a file): its JSON answer.
  Future<Map<String, dynamic>> _stream(String user, String words, Stream<List<int>> input) async {
    await _ensureKey();
    final socket = await SSHSocket.connect(server.host, server.port, timeout: const Duration(seconds: 15));
    final client = SSHClient(socket, username: user, identities: [_key!], onVerifyHostKey: _hostOk);
    try {
      final session = await client.execute(words);
      final out = session.stdout.cast<List<int>>().transform(utf8.decoder).join();
      await for (final chunk in input) {
        session.stdin.add(Uint8List.fromList(chunk));
      }
      await session.stdin.close();
      final text = await out.timeout(const Duration(minutes: 10));
      final last = text.trim().split('\n').where((l) => l.trim().startsWith('{')).lastOrNull;
      if (last == null) throw StateError('sunucu yanıt vermedi');
      final reply = jsonDecode(last) as Map<String, dynamic>;
      if (reply['hata'] != null) throw StateError('${reply['hata']}');
      return reply;
    } finally {
      client.close();
    }
  }

  /// Takes a file the server passes on (`dosya-al`), into IletiLan's checks.
  Future<void> _receiveRelay(TrustedDevice peer, String session, String id) async {
    await _ensureKey();
    final socket = await SSHSocket.connect(server.host, server.port, timeout: const Duration(seconds: 15));
    final client = SSHClient(socket, username: 'lifeos-ileti', identities: [_key!], onVerifyHostKey: _hostOk);
    try {
      final run = await client.execute('dosya-al $session');
      await run.stdin.close();
      final (status, why) = await lan.receiveFile(peer, id, run.stdout.cast<List<int>>(), progressOf: onFileProgress);
      if (status == 200) {
        onFileRelayed?.call(peer.id, id);
        await tell(peer.id, 'dosya-tamam', [id]);
      } else {
        _log.info('file $id from the server: $status $why');
      }
    } finally {
      client.close();
    }
  }

  /// A sealed control letter (§4.5): iletildi, okundu.
  Future<void> tell(String device, String kind, Object value, {bool live = false}) async {
    final peer = trustStore.byId(device);
    final to = boxOf(device);
    final key = peer == null ? null : lan.pairKeyFor(peer);
    if (!enabled || to == null || key == null || myBox == null) return;
    final box = IletiCrypto.seal(key, utf8.encode(jsonEncode(value)), utf8.encode('$kind|${lan.myId}'));
    await _run('lifeos-ileti', 'gonder $to${live ? ' canli' : ''}',
        input: jsonEncode({'tur': kind, 'from': lan.myId, 'box': IletiCrypto.b64(box)}));
  }

  // ── receiving: the fetch loop ─────────────────────────────────────────

  /// Keeps one `al 45` waiting while [enabled] (LifeOS does the same): the
  /// device counts as online, and letters come within a second or two.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
    _presence = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(checkPresence()));
    unawaited(Future<void>.delayed(const Duration(seconds: 3), checkPresence));
  }

  void stop() {
    _running = false;
    _presence?.cancel();
  }

  Timer? _presence;
  final Map<String, DateTime> _toldReady = {};

  /// Who is online now (the server answers only for boxes that allow this
  /// one). Waiting files go to whoever is; files expected from them are
  /// asked for ("hazir").
  Future<void> checkPresence() async {
    if (!_running || !enabled || myBox == null) return;
    final byBox = <String, String>{
      for (final e in _peers.entries)
        if ((trustStore.byId(e.key)?.isPinned ?? false) && _box.hasMatch('${(e.value as Map)['adres'] ?? ''}'))
          (e.value as Map)['adres'] as String: e.key,
    };
    if (byBox.isEmpty) return;
    try {
      final reply = await _run('lifeos-ileti', 'durum', input: jsonEncode(byBox.keys.toList()));
      final seen = (reply['kutular'] as Map? ?? const {}).cast<String, dynamic>();
      final presence = <String, (bool, DateTime?)>{};
      for (final MapEntry(key: box, value: device) in byBox.entries) {
        final row = seen[box] as Map?;
        final last = (row?['son'] as num?)?.toInt() ?? 0;
        presence[device] = (row?['cevrimici'] == true, last > 0 ? DateTime.fromMillisecondsSinceEpoch(last * 1000) : null);
      }
      onPresence?.call(presence);
      for (final MapEntry(key: device, value: (online, _)) in presence.entries) {
        if (!online) continue;
        for (final e in _outgoing.entries.where((e) => (e.value as Map)['device'] == device)) {
          unawaited(sendFile(e.key));
        }
        final expected = lan.expectedFrom(device);
        final last = _toldReady[device];
        if (expected.isNotEmpty && (last == null || DateTime.now().difference(last).inSeconds > 300)) {
          _toldReady[device] = DateTime.now();
          unawaited(tell(device, 'hazir', expected.take(50).toList(), live: true).catchError((Object _) {}));
        }
      }
    } catch (e) {
      _log.debug('presence: $e');
    }
  }

  Future<void> _loop() async {
    var done = <String>[];
    while (_running) {
      // nobody to hear from (no device paired with encryption): no server, no battery
      if (!enabled || !trustStore.devices.any((d) => d.isPinned)) {
        await Future<void>.delayed(const Duration(seconds: 15));
        continue;
      }
      try {
        await _ensureBox();
        await _syncAllowed();
        final got = await _run(
          'lifeos-ileti',
          'al 45',
          input: jsonEncode({'sil': done}),
          timeout: const Duration(seconds: 135),
        );
        done = [];
        for (final env in (got['zarflar'] as List? ?? const [])) {
          final e = env as Map<String, dynamic>;
          done.add('${e['id']}');
          try {
            await _take(e);
          } catch (err) {
            _log.info('letter not taken: $err'); // acknowledged anyway: never fetched twice
          }
        }
        _failures = 0;
      } catch (e) {
        _failures++;
        final wait = Duration(seconds: (15 * (1 << (_failures > 5 ? 5 : _failures))).clamp(15, 300));
        _log.info('mailbox: $e (again in ${wait.inSeconds}s)');
        await Future<void>.delayed(wait);
      }
    }
  }

  Future<void> _take(Map<String, dynamic> env) async {
    final device = deviceOf('${env['kimden'] ?? ''}');
    final peer = device == null ? null : trustStore.byId(device);
    if (peer == null || !peer.isPinned) return; // an unknown box: dropped
    final letter = jsonDecode(utf8.decode(base64.decode('${env['veri']}'))) as Map<String, dynamic>;
    final kind = '${letter['tur'] ?? ''}';
    if (kind == 'ileti') {
      final zarf = letter['zarf'] as Map<String, dynamic>;
      if ('${zarf['box'] ?? ''}'.length > 200000) return;
      final (status, _) = await lan.receiveEnvelope(peer, zarf, via: IletiVia.internet);
      if (status == 200) await tell(peer.id, 'iletildi', [zarf['id']]);
      return;
    }
    if (letter['from'] != peer.id) return;
    final key = lan.pairKeyFor(peer);
    if (key == null) return;
    final value = jsonDecode(utf8.decode(IletiCrypto.open(
      key,
      base64.decode('${letter['box']}'),
      utf8.encode('$kind|${peer.id}'),
    )));
    final ids = value is List ? value.map((x) => '$x').toList() : const <String>[];
    final map = value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};
    switch (kind) {
      case 'iletildi':
        onDelivered?.call(peer.id, ids);
      case 'okundu':
        onRead?.call(peer.id, ids);
      case 'hazir': // it waits for these files of ours: now
        for (final id in ids.where((id) => waitingFile(id)?['device'] == peer.id)) {
          unawaited(sendFile(id));
        }
      case 'dosya-tamam': // our file arrived there
        for (final id in ids.where((id) => waitingFile(id)?['device'] == peer.id)) {
          fileGone(id);
          onFileSent?.call(peer.id, id);
        }
      case 'bulus':
        // a direct connection asked: none from a phone (no shared local port in Dart, carrier NAT); an empty
        // answer, and the sender passes the file through the server instead
        final session = '${map['oturum'] ?? ''}';
        if (RegExp(r'^[0-9a-f]{32}$').hasMatch(session)) {
          await tell(peer.id, 'bulus-yanit', {'oturum': session, 'adaylar': <Object>[]}, live: true);
        }
      case 'aktarim': // the server passes a file on to us now
        final session = '${map['oturum'] ?? ''}';
        final id = '${map['ileti'] ?? ''}';
        if (RegExp(r'^[0-9a-f]{32}$').hasMatch(session) && lan.expects(peer.id, id)) {
          unawaited(_receiveRelay(peer, session, id).catchError((Object e) => _log.info('relay: $e')));
        }
      default:
        break; // arama: calls are not here
    }
  }
}
