// AnyWhere against LifeOS's own Yakındakiler code (lifeos_store/yakin.py),
// both ways, over TLS. Needs a lifeOSArch checkout:
//
//   LIFEOS_ARCH=../lifeOSArch flutter test test/interop
//
// Skipped without it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/pairing/data/pairing_client.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/transfer/data/file_sender.dart';
import 'package:anyware/features/transfer/data/file_server.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';

final String? lifeosArch = Platform.environment['LIFEOS_ARCH'];
final String peerScript = '${Directory.current.path}/test/interop/lifeos_peer.py';

Future<Process> startPeer(List<String> args) => Process.start(
  'python3',
  [peerScript, ...args],
  environment: {'LIFEOS_ARCH': lifeosArch!},
);

Device phone(String id) => Device(
  id: id,
  name: 'Telefon',
  ip: '127.0.0.1',
  port: 0,
  platform: 'android',
  version: '1.1',
  lastSeen: DateTime.now(),
  capabilities: const ['pairing-token', kTlsCapability],
);

void main() {
  late Directory temp;
  late TrustStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('anywhere_interop_');
    SharedPreferences.setMockInitialValues({});
    store = TrustStore(await SharedPreferences.getInstance());
    PeerTls.instance.trustStore = store;
    expect(await TlsIdentity.load(Directory('${temp.path}/tls')), isNotNull);
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'AnyWhere pairs with LifeOS over TLS, sends a file, and plain HTTP is refused after',
    () async {
      final peer = await startPeer(['server', '${temp.path}/lifeos']);
      addTearDown(peer.kill);
      final lines = peer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          // LifeOS writes its journal lines there too: only the JSON ones
          .where((l) => l.startsWith('{'))
          .asBroadcastStream();
      final info = jsonDecode(await lines.first) as Map<String, dynamic>;
      final port = info['port'] as int;
      final lifeosCode = lines.firstWhere((l) => l.contains('"code"'));

      final mine = TlsIdentity.current!.fingerprint;
      final result = await PairingClient(store).requestPairing(
        ip: '127.0.0.1',
        port: port,
        localId: 'telefon-1',
        localName: 'Telefon',
        localPlatform: 'android',
      );
      expect(result, PairingResult.paired);
      final code = (jsonDecode(await lifeosCode) as Map)['code'];
      expect(code, TlsIdentity.pairingCode(mine, info['fingerprint'] as String));
      // each side pinned the other's certificate
      expect(store.byId(info['id'] as String)?.fingerprint, info['fingerprint']);
      final trust = await Process.run('python3', [
        peerScript,
        'trust',
        '${temp.path}/lifeos',
      ], environment: {'LIFEOS_ARCH': lifeosArch!});
      final lifeosTrust =
          (jsonDecode((trust.stdout as String).trim().split('\n').last)
                  as Map)['trust']
              as Map;
      expect((lifeosTrust['telefon-1'] as Map)['fingerprint'], mine);

      // a file, encrypted, arrives whole
      final lifeos = Device(
        id: info['id'] as String,
        name: 'LifeOS',
        ip: '127.0.0.1',
        port: port,
        platform: 'linux',
        version: '1.1',
        lastSeen: DateTime.now(),
        capabilities: const ['pairing-token', kTlsCapability],
      );
      final file = File('${temp.path}/telefondan.txt')
        ..writeAsStringSync('Telefondan merhaba, şifreli');
      final sent = await FileSender(
        localDevice: phone('telefon-1'),
        trustStore: store,
      ).sendFile(lifeos, file.path);
      expect(sent.status, TransferStatus.completed, reason: sent.error);
      final got = File('${temp.path}/lifeos/gelen/telefondan.txt');
      expect(got.readAsStringSync(), 'Telefondan merhaba, şifreli');

      // the same token over plain HTTP: refused (pinned to TLS)
      final plain = await http.post(
        Uri.http('127.0.0.1:$port', '/api/send-request'),
        headers: {'Content-Type': 'application/json', ...store.authHeaders(lifeos.id)},
        body: jsonEncode({
          'fileName': 'x.txt',
          'fileSize': 1,
          'senderId': 'telefon-1',
          'senderName': 'Telefon',
        }),
      );
      expect((jsonDecode(plain.body) as Map)['accepted'], false);
      await peer.stdin.close();
    },
    skip: lifeosArch == null ? 'LIFEOS_ARCH is not set' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'LifeOS pairs with AnyWhere over TLS and sends it a file',
    () async {
      final prompts = <PairingRequest>[];
      final server = FileServer(
        localDevice: phone('telefon-2'),
        trustStore: store,
        downloadPath: '${temp.path}/indirilen',
      )..onPairingRequest = (request) async {
          prompts.add(request);
          return PairingDecision.trust;
        };
      await server.start(0);
      addTearDown(server.dispose);

      final run = await Process.run('python3', [
        peerScript,
        'client',
        '${temp.path}/lifeos',
        '${server.boundPort}',
        'telefon-2',
      ], environment: {'LIFEOS_ARCH': lifeosArch!});
      expect(run.exitCode, 0, reason: '${run.stderr}');
      final out = jsonDecode((run.stdout as String).trim().split('\n').last)
          as Map<String, dynamic>;
      expect(out['paired'], true);
      expect(out['pin'], TlsIdentity.current!.fingerprint);
      expect(prompts.single.code, out['code']);
      expect(prompts.single.code, isNotEmpty);
      final pinned = store.devices.single;
      expect(pinned.fingerprint, out['fingerprint']);

      final got = File('${temp.path}/indirilen/lifeos-den.txt');
      for (var i = 0; i < 50 && !got.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(got.readAsStringSync(), "LifeOS'tan merhaba");

      // LifeOS's token over plain HTTP: refused here too (pinned to TLS)
      final plain = await http.post(
        Uri.http('127.0.0.1:${server.boundPort}', '/api/clipboard'),
        headers: {
          'Content-Type': 'application/json',
          kProtocolHeader: '1.1',
          kPairTokenHeader: pinned.token!,
        },
        body: jsonEncode({'text': 'x', 'senderDeviceId': pinned.id}),
      );
      expect(plain.statusCode, isNot(200));
    },
    skip: lifeosArch == null ? 'LIFEOS_ARCH is not set' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
