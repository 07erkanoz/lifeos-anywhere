import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math';

import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/ileti/data/ileti_crypto.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/data/ileti_posta.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

/// What a remote pairing made: the device, and the 6-digit code both screens
/// must show alike.
class RemotePairing {
  const RemotePairing({required this.deviceId, required this.name, required this.code});
  final String deviceId;
  final String name;
  final String code;
}

class RemotePairingException implements Exception {
  const RemotePairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Pairing with a device that was never on the same network, by a 16-letter
/// code (LifeOS İleti's ileti_uzak.py; docs/ileti-protokol.md §5). The first 4
/// letters are the tag the server finds the invitation by; the other 12 never
/// leave the two devices and seal each one's identity, certificate, mailbox
/// and token. The server passes the sealed offer and answer on and cannot read
/// them. Afterwards the two are paired as on a network (pinned certificates).
class IletiUzak {
  IletiUzak({required this.posta, required this.lan, required this.trustStore, required this.platform});

  final IletiPosta posta;
  final IletiLan lan;
  final TrustStore trustStore;

  /// This device's platform, told to the other side.
  final String platform;

  static const String letters = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford base32
  static const Duration lifetime = Duration(minutes: 10);

  /// A new code, `XXXX-XXXX-XXXX-XXXX`.
  static String newCode() {
    final r = Random.secure();
    final raw = List.generate(16, (_) => letters[r.nextInt(letters.length)]).join();
    return [for (var i = 0; i < 16; i += 4) raw.substring(i, i + 4)].join('-');
  }

  /// (tag, secret) of what a person typed; throws when it is not a code.
  static (String, String) clean(String code) {
    var text = code.toUpperCase().replaceAll('-', '').replaceAll(' ', '');
    text = text.replaceAll('O', '0').replaceAll('I', '1').replaceAll('L', '1').replaceAll('U', 'V');
    if (text.length != 16 || text.split('').any((c) => !letters.contains(c))) {
      throw const RemotePairingException('Kod 16 harf ve rakamdan oluşur, örneğin K7Q2-9MXA-4TPE-H3WD.');
    }
    return (text.substring(0, 4), text.substring(4));
  }

  static List<int> _key(String tag, String secret, String box) =>
      IletiCrypto.hkdf(utf8.encode(secret), info: utf8.encode('lifeos-ileti-davet-1|$tag|$box'));

  static String _seal(String tag, String secret, String box, Map<String, dynamic> value) => base64.encode(
        IletiCrypto.seal(Uint8List.fromList(_key(tag, secret, box)), utf8.encode(jsonEncode(value)), utf8.encode(tag)),
      );

  static Map<String, dynamic> _open(String tag, String secret, String box, String text) {
    try {
      final plain = IletiCrypto.open(
        Uint8List.fromList(_key(tag, secret, box)),
        base64.decode(text),
        utf8.encode(tag),
      );
      final value = jsonDecode(utf8.decode(plain));
      if (value is Map<String, dynamic>) return value;
    } catch (_) {}
    throw const RemotePairingException('Kod yanlış: davet açılamadı.');
  }

  Map<String, dynamic> _me(String token, String box) => {
        'id': lan.myId,
        'name': lan.myName(),
        'platform': platform,
        'token': token,
        'adres': box,
        'cert': base64.encode(lan.myCertDer),
      };

  /// The other device, paired here as on a network: certificate pinned, its
  /// box known, the token kept.
  Future<RemotePairing> _take(Map<String, dynamic> other, String box) async {
    final id = '${other['id'] ?? ''}';
    final der = base64.decode('${other['cert'] ?? ''}');
    if (id.isEmpty || id == lan.myId || other['adres'] != box) {
      throw const RemotePairingException('Karşı cihazın bilgileri tutarsız; eşleşilmedi.');
    }
    final pin = TlsIdentity.fingerprintOf(der);
    final known = trustStore.byId(id);
    if (known != null && known.isPinned && known.fingerprint != pin) {
      throw RemotePairingException(
          '${known.name}: sertifikası eşleşmedekinden farklı. Önce eşleşmeyi kaldırıp yeniden eşleşin.');
    }
    final name = '${other['name'] ?? id}';
    final shortName = name.length > 80 ? name.substring(0, 80) : name;
    await trustStore.trust(
      id: id,
      name: shortName,
      platform: '${other['platform'] ?? 'linux'}',
      token: '${other['token'] ?? ''}',
      ip: known?.lastIp ?? '',
      fingerprint: pin,
    );
    lan.keepCert(id, der);
    posta
      ..peerBox(id, box)
      ..told(id);
    await posta.syncAllowed();
    final mine = TlsIdentity.current!.fingerprint;
    return RemotePairing(deviceId: id, name: shortName, code: TlsIdentity.pairingCode(mine, pin));
  }

  // ── the inviting side ─────────────────────────────────────────────────

  /// Makes a code and leaves the sealed offer on the server. Then [wait].
  Future<({String code, String token})> invite() async {
    final box = await posta.ensureBox();
    final code = newCode();
    final (tag, secret) = clean(code);
    final token = trustStore.newToken();
    await posta.command('davet $tag', input: _seal(tag, secret, box, _me(token, box)));
    return (code: code, token: token);
  }

  /// Waits (up to [lifetime]) for the other device to answer [code]. Null
  /// when [cancelled] says stop.
  Future<RemotePairing?> wait(String code, String token, {bool Function()? cancelled}) async {
    final (tag, secret) = clean(code);
    final until = DateTime.now().add(lifetime);
    while (DateTime.now().isBefore(until)) {
      if (cancelled?.call() ?? false) return null;
      final answer = await posta.command('davet-bekle $tag 45', timeout: const Duration(seconds: 110));
      if (answer['yanit'] == null) continue;
      final box = '${answer['katilan'] ?? ''}';
      final other = _open(tag, secret, box, '${answer['yanit']}');
      if (other['token'] != token) {
        throw const RemotePairingException('Karşı cihazın yanıtı bu davete ait değil; eşleşilmedi.');
      }
      return _take(other, box);
    }
    throw const RemotePairingException('Kodun süresi doldu (10 dakika).');
  }

  Future<void> cancel(String code) async {
    final (tag, _) = clean(code);
    try {
      await posta.command('davet-iptal $tag');
    } catch (_) {}
  }

  // ── the joining side ──────────────────────────────────────────────────

  /// Pairs with the device that made [code].
  Future<RemotePairing> join(String code) async {
    final (tag, secret) = clean(code);
    final box = await posta.ensureBox();
    final found = await posta.command('davet-al $tag');
    final theirs = '${found['kimden'] ?? ''}';
    final other = _open(tag, secret, theirs, '${found['teklif'] ?? ''}');
    final done = await _take(other, theirs);
    final token = '${other['token'] ?? ''}';
    await posta.command('davet-yanit $tag', input: _seal(tag, secret, box, {..._me(token, box), 'token': token}));
    return done;
  }

  static String platformName() => Platform.isAndroid
      ? 'android'
      : Platform.isWindows
          ? 'windows'
          : Platform.isIOS
              ? 'ios'
              : 'linux';
}
