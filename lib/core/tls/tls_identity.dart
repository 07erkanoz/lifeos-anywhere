import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import 'package:anyware/core/logger.dart';

/// This device's own TLS certificate, as LifeOS's Yakındakiler has one
/// (lifeos_store/yakin.py `_tls_files`): EC P-256, self-signed, made once.
///
/// Nobody vouches for it. The other side pins its [fingerprint] (SHA-256 of
/// the certificate's DER) when the two pair, and both screens show the same
/// [pairingCode] made of the two fingerprints: when they match, nobody sits
/// in between.
class TlsIdentity {
  TlsIdentity._(this.certificatePem, this.privateKeyPem, this.fingerprint);

  static final _log = AppLogger('TlsIdentity');

  /// The certificate (PEM) and its key (SEC1 "EC PRIVATE KEY", PEM).
  final String certificatePem;
  final String privateKeyPem;

  /// SHA-256 of the certificate's DER, lowercase hex (LifeOS's format).
  final String fingerprint;

  static TlsIdentity? _current;

  /// The identity loaded by [load], or `null` when none could be made: the
  /// app then speaks plain HTTP only, as protocol 1.1.
  static TlsIdentity? get current => _current;

  /// A context that serves this certificate.
  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  /// Loads the certificate from [folder] (made there the first time).
  static Future<TlsIdentity?> load(Directory folder, {String name = ''}) async {
    try {
      final certFile = File(p.join(folder.path, 'tls-sertifika.pem'));
      final keyFile = File(p.join(folder.path, 'tls-anahtar.pem'));
      if (!certFile.existsSync() || !keyFile.existsSync()) {
        final made = generate(commonName: 'anywhere-$name');
        await folder.create(recursive: true);
        await keyFile.writeAsString(made.privateKeyPem, flush: true);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['600', keyFile.path]);
        }
        await certFile.writeAsString(made.certificatePem, flush: true);
        _log.info('Made this device\'s TLS certificate');
      }
      final certPem = await certFile.readAsString();
      final identity = TlsIdentity._(
        certPem,
        await keyFile.readAsString(),
        fingerprintOfPem(certPem),
      );
      identity.serverContext(); // a broken pair fails here, not mid-request
      return _current = identity;
    } catch (e) {
      _log.warning('No TLS certificate; plain HTTP only: $e');
      return _current = null;
    }
  }

  /// Makes a new key and a self-signed certificate (valid for 100 years).
  static TlsIdentity generate({String commonName = 'anywhere'}) {
    final random = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(
            List<int>.generate(32, (_) => Random.secure().nextInt(256)),
          ),
        ),
      );
    final domain = ECDomainParameters('prime256v1');
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(ECKeyGeneratorParameters(domain), random),
      );
    final pair = generator.generateKeyPair();
    final privateKey = pair.privateKey;
    final publicKey = pair.publicKey;
    final point = publicKey.Q!.getEncoded(false); // 04 || X || Y

    final now = DateTime.now().toUtc();
    final serial = List<int>.generate(16, (_) => random.nextUint8());
    serial[0] &= 0x7f; // positive
    final name = _seq([
      _set([
        _seq([_oid(_cn), _utf8(commonName)]),
      ]),
    ]);
    final tbs = _seq([
      _tag(0xa0, _int([2])), // v3
      _int(serial),
      _seq([_oid(_ecdsaWithSha256)]),
      name,
      _seq([
        _utcTime(now.subtract(const Duration(days: 1))),
        _generalizedTime(DateTime.utc(now.year + 100, now.month, now.day)),
      ]),
      name,
      _seq([
        _seq([_oid(_ecPublicKey), _oid(_prime256v1)]),
        _bitString(point),
      ]),
    ]);

    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(privateKey));
    final signature = signer.generateSignature(tbs) as ECSignature;
    final certificate = _seq([
      tbs,
      _seq([_oid(_ecdsaWithSha256)]),
      _bitString(_seq([_bigInt(signature.r), _bigInt(signature.s)])),
    ]);

    final key = _seq([
      _int([1]),
      _tag(0x04, _fixed(privateKey.d!, 32)),
      _tag(0xa0, _oid(_prime256v1)),
      _tag(0xa1, _bitString(point)),
    ]);

    final certPem = _pem('CERTIFICATE', certificate);
    return TlsIdentity._(
      certPem,
      _pem('EC PRIVATE KEY', key),
      fingerprintOf(certificate),
    );
  }

  /// SHA-256 of a certificate's DER, lowercase hex.
  static String fingerprintOf(List<int> der) =>
      crypto.sha256.convert(der).toString();

  static String fingerprintOfPem(String pem) {
    final body = pem
        .split('\n')
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return fingerprintOf(base64.decode(body));
  }

  /// The six digits both screens show while pairing, made of the two
  /// fingerprints exactly as LifeOS makes them (`pairing_code`): "123 456".
  static String pairingCode(String a, String b) {
    if (a.isEmpty || b.isEmpty) return '';
    final sorted = [a, b]..sort();
    final digest = crypto.sha256.convert(utf8.encode(sorted.join())).bytes;
    var number = BigInt.zero;
    for (final byte in digest) {
      number = (number << 8) | BigInt.from(byte);
    }
    final n = (number % BigInt.from(1000000)).toInt();
    String three(int v) => v.toString().padLeft(3, '0');
    return '${three(n ~/ 1000)} ${three(n % 1000)}';
  }

  // ── DER, the little of it a certificate needs ───────────────────────

  static const _cn = [2, 5, 4, 3];
  static const _ecPublicKey = [1, 2, 840, 10045, 2, 1];
  static const _prime256v1 = [1, 2, 840, 10045, 3, 1, 7];
  static const _ecdsaWithSha256 = [1, 2, 840, 10045, 4, 3, 2];

  static Uint8List _tag(int tag, List<int> content) {
    final length = content.length;
    final head = <int>[tag];
    if (length < 0x80) {
      head.add(length);
    } else {
      final bytes = <int>[];
      for (var v = length; v > 0; v >>= 8) {
        bytes.insert(0, v & 0xff);
      }
      head
        ..add(0x80 | bytes.length)
        ..addAll(bytes);
    }
    return Uint8List.fromList([...head, ...content]);
  }

  static Uint8List _seq(List<List<int>> items) =>
      _tag(0x30, [for (final i in items) ...i]);

  static Uint8List _set(List<List<int>> items) =>
      _tag(0x31, [for (final i in items) ...i]);

  static Uint8List _int(List<int> bytes) {
    var b = bytes;
    while (b.length > 1 && b[0] == 0 && b[1] < 0x80) {
      b = b.sublist(1);
    }
    if (b.isNotEmpty && b[0] >= 0x80) b = [0, ...b];
    return _tag(0x02, b);
  }

  static Uint8List _bigInt(BigInt v) => _int(_unsigned(v));

  static List<int> _unsigned(BigInt v) {
    final out = <int>[];
    for (var x = v; x > BigInt.zero; x >>= 8) {
      out.insert(0, (x & BigInt.from(0xff)).toInt());
    }
    return out.isEmpty ? [0] : out;
  }

  static List<int> _fixed(BigInt v, int size) {
    final b = _unsigned(v);
    return [...List<int>.filled(size - b.length, 0), ...b];
  }

  static Uint8List _oid(List<int> parts) {
    final out = <int>[parts[0] * 40 + parts[1]];
    for (final part in parts.skip(2)) {
      final chunk = <int>[part & 0x7f];
      for (var v = part >> 7; v > 0; v >>= 7) {
        chunk.insert(0, 0x80 | (v & 0x7f));
      }
      out.addAll(chunk);
    }
    return _tag(0x06, out);
  }

  static Uint8List _utf8(String s) => _tag(0x0c, utf8.encode(s));

  static Uint8List _bitString(List<int> bytes) => _tag(0x03, [0, ...bytes]);

  static String _two(int v) => v.toString().padLeft(2, '0');

  static Uint8List _utcTime(DateTime t) => _tag(
    0x17,
    ascii.encode(
      '${_two(t.year % 100)}${_two(t.month)}${_two(t.day)}'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}Z',
    ),
  );

  static Uint8List _generalizedTime(DateTime t) => _tag(
    0x18,
    ascii.encode(
      '${t.year}${_two(t.month)}${_two(t.day)}'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}Z',
    ),
  );

  static String _pem(String label, List<int> der) {
    final b64 = base64.encode(der);
    final lines = [
      for (var i = 0; i < b64.length; i += 64)
        b64.substring(i, min(i + 64, b64.length)),
    ];
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }
}
