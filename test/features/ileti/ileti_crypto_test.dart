// İleti's cryptography against Python's `cryptography` (what LifeOS uses):
// the same pair key from the same two certificates, and boxes either side
// can open. Skipped where python3 has no `cryptography`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/ileti/data/ileti_crypto.dart';

const _python = r'''
import base64, json, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
a_key, b_cert, a_fp, b_fp, box = sys.argv[1:6]
mine = serialization.load_pem_private_key(open(a_key, "rb").read(), None)
theirs = x509.load_pem_x509_certificate(open(b_cert, "rb").read()).public_key()
salt = "".join(sorted([a_fp, b_fp])).encode()
key = HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=b"lifeos-ileti-1").derive(mine.exchange(ec.ECDH(), theirs))
blob = base64.b64decode(box)
try:
    opened = ChaCha20Poly1305(key).decrypt(blob[:12], blob[12:], b"id|from").decode()
except Exception as error:
    opened = repr(error)
nonce = b"\x01" * 12
mine_box = base64.b64encode(nonce + ChaCha20Poly1305(key).encrypt(nonce, "Python'dan".encode(), b"id|from")).decode()
print(json.dumps({"key": key.hex(), "opened": opened, "box": mine_box}))
''';

void main() {
  final hasCrypto = Process.runSync('python3', ['-c', 'import cryptography']).exitCode == 0;

  test('pair key and boxes match LifeOS (Python cryptography)', () async {
    final temp = await Directory.systemTemp.createTemp('ileti_crypto_');
    addTearDown(() => temp.delete(recursive: true));
    final a = TlsIdentity.generate(commonName: 'a');
    final b = TlsIdentity.generate(commonName: 'b');
    File('${temp.path}/a.key').writeAsStringSync(a.privateKeyPem);
    File('${temp.path}/b.crt').writeAsStringSync(b.certificatePem);
    final bDer = base64.decode(b.certificatePem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join());
    final key = IletiCrypto.pairKey(
      myPrivate: IletiCrypto.privateScalarFromPem(a.privateKeyPem),
      peerCertDer: bDer,
      myFingerprint: a.fingerprint,
      peerFingerprint: b.fingerprint,
    );
    final box = IletiCrypto.seal(key, utf8.encode("Dart'tan"), utf8.encode('id|from'));
    final run = await Process.run('python3', [
      '-c', _python, '${temp.path}/a.key', '${temp.path}/b.crt', a.fingerprint, b.fingerprint, base64.encode(box),
    ]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final out = jsonDecode(run.stdout as String) as Map;
    expect(out['key'], key.map((x) => x.toRadixString(16).padLeft(2, '0')).join());
    expect(out['opened'], "Dart'tan");
    expect(
      utf8.decode(IletiCrypto.open(key, base64.decode(out['box'] as String), utf8.encode('id|from'))),
      "Python'dan",
    );
  }, skip: hasCrypto ? false : 'python3 cryptography is not installed');
}
