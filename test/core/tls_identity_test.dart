import 'dart:convert';
import 'dart:io';

import 'package:anyware/core/tls/tls_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the certificate is valid X.509 and serves TLS with its fingerprint', () async {
    final id = TlsIdentity.generate(commonName: 'anywhere-test');
    final dir = await Directory.systemTemp.createTemp('tls');
    final cert = File('${dir.path}/c.pem')..writeAsStringSync(id.certificatePem);
    final key = File('${dir.path}/k.pem')..writeAsStringSync(id.privateKeyPem);
    final verify = await Process.run('openssl', ['verify', '-CAfile', cert.path, cert.path]);
    expect(verify.stdout.toString(), contains('OK'), reason: '${verify.stderr}');
    final keyCheck = await Process.run('openssl', ['ec', '-in', key.path, '-check', '-noout']);
    expect(keyCheck.exitCode, 0, reason: '${keyCheck.stderr}');

    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, id.serverContext());
    server.listen((s) async { s.write('hi'); await s.close(); });
    String? seen;
    final client = await SecureSocket.connect(InternetAddress.loopbackIPv4, server.port,
        onBadCertificate: (c) { seen = TlsIdentity.fingerprintOf(c.der); return true; });
    expect(await utf8.decodeStream(client), 'hi');
    expect(seen, id.fingerprint);
    await server.close();
  });

  test('the pairing code is the one LifeOS shows', () async {
    const a = 'aa11', b = 'ff00';
    final py = await Process.run('python3', ['-c', '''
import hashlib
a, b = "aa11", "ff00"
n = int(hashlib.sha256("".join(sorted((a, b))).encode()).hexdigest(), 16) % 1_000_000
print(f"{n // 1000:03d} {n % 1000:03d}")''']);
    expect(TlsIdentity.pairingCode(b, a), py.stdout.toString().trim());
    expect(TlsIdentity.pairingCode('', a), '');
  });
}
