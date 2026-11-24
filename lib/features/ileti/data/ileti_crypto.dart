import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// LifeOS İleti's cryptography (docs/ileti-protokol.md §2, lifeos_store/
/// ileti.py): a pair key from ECDH of the two P-256 TLS certificates, HKDF-
/// SHA256 over it, ChaCha20-Poly1305 boxes, and files in sealed 1 MiB pieces.
class IletiCrypto {
  IletiCrypto._();

  static const int chunk = 1 << 20;
  static final ECDomainParameters _curve = ECDomainParameters('prime256v1');

  // ── keys ──────────────────────────────────────────────────────────────

  /// The private scalar of a PEM key ("EC PRIVATE KEY", SEC1; or PKCS#8).
  static BigInt privateScalarFromPem(String pem) {
    var der = _pemBody(pem);
    if (pem.contains('BEGIN PRIVATE KEY')) {
      // PKCS#8: SEQUENCE { INTEGER, AlgorithmIdentifier, OCTET STRING { SEC1 } }
      der = _children(_tlv(der))[2].value;
    }
    // SEC1: SEQUENCE { INTEGER 1, OCTET STRING d, ... }
    final d = _children(_tlv(der))[1];
    if (d.tag != 0x04) throw const FormatException('not an EC private key');
    return _toBigInt(d.value);
  }

  /// The P-256 public point in a certificate (DER).
  static ECPoint publicPointFromCertDer(Uint8List der) {
    // Certificate { tbsCertificate, signatureAlgorithm, signature }
    final tbs = _children(_children(_tlv(der))[0].value);
    for (final item in tbs) {
      if (item.tag != 0x30) continue;
      final spki = _children(item.value);
      if (spki.length == 2 && spki[0].tag == 0x30 && spki[1].tag == 0x03) {
        final bits = spki[1].value; // first byte: unused bits (0)
        return _curve.curve.decodePoint(bits.sublist(1))!;
      }
    }
    throw const FormatException('no public key in the certificate');
  }

  /// The pair key both sides compute (§2.2).
  static Uint8List pairKey({
    required BigInt myPrivate,
    required Uint8List peerCertDer,
    required String myFingerprint,
    required String peerFingerprint,
  }) {
    final shared = (publicPointFromCertDer(peerCertDer) * myPrivate)!.x!.toBigInteger()!;
    final ikm = _fixed(shared, 32);
    final salt = utf8.encode(([myFingerprint, peerFingerprint]..sort()).join());
    return hkdf(ikm, salt: salt, info: utf8.encode('lifeos-ileti-1'));
  }

  /// HKDF-SHA256, one block (32 bytes). A missing salt is 32 zero bytes, as
  /// Python's cryptography does.
  static Uint8List hkdf(List<int> ikm, {List<int>? salt, required List<int> info, int length = 32}) {
    final prk = crypto.Hmac(crypto.sha256, salt ?? List.filled(32, 0)).convert(ikm).bytes;
    final out = <int>[];
    var t = <int>[];
    for (var i = 1; out.length < length; i++) {
      t = crypto.Hmac(crypto.sha256, prk).convert([...t, ...info, i]).bytes;
      out.addAll(t);
    }
    return Uint8List.fromList(out.sublist(0, length));
  }

  // ── boxes ─────────────────────────────────────────────────────────────

  static Uint8List random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// ChaCha20-Poly1305 exactly as RFC 8439 §2.8 (what Python's cryptography
  /// does). pointycastle's own ChaCha20Poly1305 class gave tags Python
  /// rejected, so it is put together here from its ChaCha20 and Poly1305.
  /// Encrypting returns ciphertext || tag; decrypting takes the same.
  static Uint8List _aead(bool encrypt, Uint8List key, Uint8List nonce, Uint8List data, List<int> aad) {
    final chacha = ChaCha7539Engine()..init(true, ParametersWithIV(KeyParameter(key), nonce));
    // block 0: the one-time Poly1305 key; the message starts at block 1
    final block0 = chacha.process(Uint8List(64));
    final otk = block0.sublist(0, 32);
    final Uint8List ciphertext;
    final Uint8List out;
    if (encrypt) {
      ciphertext = chacha.process(data);
      out = ciphertext;
    } else {
      if (data.length < 16) throw InvalidCipherTextException('short');
      ciphertext = data.sublist(0, data.length - 16);
      out = ciphertext;
    }
    final mac = Poly1305()..init(KeyParameter(otk));
    void feed(List<int> bytes) {
      final b = Uint8List.fromList(bytes);
      mac.update(b, 0, b.length);
      final pad = (16 - b.length % 16) % 16;
      if (pad > 0) mac.update(Uint8List(pad), 0, pad);
    }

    feed(aad);
    feed(ciphertext);
    final lens = ByteData(16)
      ..setUint64(0, aad.length, Endian.little)
      ..setUint64(8, ciphertext.length, Endian.little);
    mac.update(lens.buffer.asUint8List(), 0, 16);
    final tag = Uint8List(16);
    mac.doFinal(tag, 0);
    if (encrypt) return Uint8List.fromList([...out, ...tag]);
    final given = data.sublist(data.length - 16);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= tag[i] ^ given[i];
    }
    if (diff != 0) throw InvalidCipherTextException('bad tag');
    return chacha.process(ciphertext);
  }

  /// nonce(12) || ChaCha20-Poly1305(plain) (§2.3).
  static Uint8List seal(Uint8List key, List<int> plain, List<int> aad) {
    final nonce = random(12);
    return Uint8List.fromList([...nonce, ..._aead(true, key, nonce, Uint8List.fromList(plain), aad)]);
  }

  /// Opens a [seal]ed box; throws when it is not genuine.
  static Uint8List open(Uint8List key, Uint8List box, List<int> aad) {
    if (box.length < 28) throw const FormatException('çözülemedi');
    try {
      return _aead(false, key, box.sublist(0, 12), box.sublist(12), aad);
    } on InvalidCipherTextException {
      throw const FormatException('çözülemedi');
    }
  }

  // ── files (§2.4) ─────────────────────────────────────────────────────

  static int pieces(int size) => max(1, (size + chunk - 1) ~/ chunk);
  static int streamLength(int size) => size + pieces(size) * 20;

  static Uint8List _pieceNonce(Uint8List prefix, int n) {
    final b = ByteData(12);
    for (var i = 0; i < 4; i++) {
      b.setUint8(i, prefix[i]);
    }
    b.setUint64(4, n);
    return b.buffer.asUint8List();
  }

  /// One frame: length(4, big-endian) || sealed piece.
  static Uint8List frame(Uint8List key, Uint8List prefix, int n, int total, Uint8List block) {
    final sealed = _aead(true, key, _pieceNonce(prefix, n), block, utf8.encode(n == total - 1 ? 'son' : 'ara'));
    final head = ByteData(4)..setUint32(0, sealed.length);
    return Uint8List.fromList([...head.buffer.asUint8List(), ...sealed]);
  }

  static Uint8List openPiece(Uint8List key, Uint8List prefix, int n, bool last, Uint8List sealed) {
    try {
      return _aead(false, key, _pieceNonce(prefix, n), sealed, utf8.encode(last ? 'son' : 'ara'));
    } on InvalidCipherTextException {
      throw const FormatException('parça çözülemedi');
    }
  }

  // ── DER ───────────────────────────────────────────────────────────────

  static Uint8List _pemBody(String pem) => base64.decode(
        pem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join(),
      );

  /// The content of the one TLV [der] is.
  static Uint8List _tlv(Uint8List der) {
    final (len, hdr) = _len(der, 1);
    return der.sublist(1 + hdr, 1 + hdr + len);
  }

  /// The TLVs one after another in [content] (a SEQUENCE's content).
  static List<({int tag, Uint8List value})> _children(Uint8List content) {
    final out = <({int tag, Uint8List value})>[];
    var i = 0;
    while (i < content.length) {
      final tag = content[i];
      final (len, hdr) = _len(content, i + 1);
      final start = i + 1 + hdr;
      out.add((tag: tag, value: content.sublist(start, start + len)));
      i = start + len;
    }
    return out;
  }

  static (int, int) _len(Uint8List d, int at) {
    final first = d[at];
    if (first < 0x80) return (first, 1);
    final n = first & 0x7f;
    var len = 0;
    for (var k = 0; k < n; k++) {
      len = (len << 8) | d[at + 1 + k];
    }
    return (len, 1 + n);
  }

  static BigInt _toBigInt(List<int> bytes) =>
      bytes.fold(BigInt.zero, (a, b) => (a << 8) | BigInt.from(b));

  static Uint8List _fixed(BigInt v, int n) {
    final out = Uint8List(n);
    var x = v;
    for (var i = n - 1; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x >>= 8;
    }
    return out;
  }

  static String b64(List<int> bytes) => base64.encode(bytes);
}
