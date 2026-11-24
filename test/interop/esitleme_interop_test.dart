// Folder sync between AnyWhere and LifeOS's own code (lifeos_store/
// yakin_esitle.py), both ways, through two real Syncthing instances on this
// computer. Needs a lifeOSArch checkout and syncthing on PATH:
//
//   LIFEOS_ARCH=../lifeOSArch flutter test test/interop/esitleme_interop_test.dart
//
// Nothing touches the computer's own Syncthing: each side has its own home,
// ports and key under a temporary folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/esitleme/data/esitleme_service.dart';
import 'package:anyware/features/esitleme/data/syncthing.dart';
import 'package:anyware/features/pairing/data/pairing_client.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/transfer/data/file_server.dart';

final String? lifeosArch = Platform.environment['LIFEOS_ARCH'];
final String peerScript = '${Directory.current.path}/test/interop/lifeos_peer.py';
final bool hasSyncthing = Process.runSync('which', ['syncthing']).exitCode == 0;

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<void> waitFor(File file, String content, {int seconds = 90}) async {
  for (var i = 0; i < seconds * 4; i++) {
    if (file.existsSync() && file.readAsStringSync() == content) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('${file.path} did not arrive in ${seconds}s');
}

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
  late Map<String, String> lifeosEnv;
  late Syncthing syncthing;
  late EsitlemeService esitleme;

  Future<ProcessResult> peer(List<String> args) =>
      Process.run('python3', [peerScript, ...args], environment: lifeosEnv);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('anywhere_esitle_');
    SharedPreferences.setMockInitialValues({});
    store = TrustStore(await SharedPreferences.getInstance());
    PeerTls.instance.trustStore = store;
    expect(await TlsIdentity.load(Directory('${temp.path}/tls')), isNotNull);
    lifeosEnv = {
      'LIFEOS_ARCH': lifeosArch ?? '',
      'LIFEOS_ESITLE_GUI': '${await freePort()}',
      'LIFEOS_ESITLE_PORT': '${await freePort()}',
    };
    syncthing = Syncthing(
      home: Directory('${temp.path}/st'),
      listenPort: await freePort(),
    );
    esitleme = EsitlemeService(
      syncthing: syncthing,
      trustStore: store,
      settingsFile: File('${temp.path}/esitleme.json'),
      incomingRoot: Directory('${temp.path}/Eşitlenen'),
    )..askPermission = (_) async => true;
  });

  tearDown(() async {
    await syncthing.stop();
    await peer(['kapat', '${temp.path}/lifeos']);
    await temp.delete(recursive: true);
  });

  final skip = lifeosArch == null
      ? 'LIFEOS_ARCH is not set'
      : !hasSyncthing
          ? 'syncthing is not installed'
          : false;

  test(
    'AnyWhere shares a folder with LifeOS; files go both ways',
    () async {
      final server = await Process.start(
        'python3',
        [peerScript, 'server', '${temp.path}/lifeos'],
        environment: lifeosEnv,
      );
      addTearDown(server.kill);
      final lines = server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.startsWith('{'))
          .asBroadcastStream();
      final info = jsonDecode(await lines.first) as Map<String, dynamic>;
      final port = info['port'] as int;

      final paired = await PairingClient(store).requestPairing(
        ip: '127.0.0.1',
        port: port,
        localId: 'telefon-e1',
        localName: 'Telefon',
        localPlatform: 'android',
      );
      expect(paired, PairingResult.paired);
      final lifeos = store.byId(info['id'] as String)!;
      expect(lifeos.isPinned, isTrue);

      final folder = Directory('${temp.path}/Belgeler')..createSync();
      File('${folder.path}/telefondan.txt').writeAsStringSync('telefondan');
      final remote = await esitleme.syncFolder(
        peer: lifeos,
        ip: '127.0.0.1',
        port: port,
        path: folder.path,
      );
      expect(remote, contains('Eşitlenen'));
      await waitFor(File('$remote/telefondan.txt'), 'telefondan');

      File('$remote/lifeosdan.txt').writeAsStringSync('lifeosdan');
      await waitFor(File('${folder.path}/lifeosdan.txt'), 'lifeosdan');

      final rows = await esitleme.folders();
      expect(rows.single.device, lifeos.id);

      await esitleme.stop(rows.single.id, ip: '127.0.0.1', port: port);
      expect(await esitleme.folders(), isEmpty);
      await server.stdin.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'LifeOS shares a folder with AnyWhere; it lands under Eşitlenen',
    () async {
      final server = FileServer(
        localDevice: phone('telefon-e2'),
        trustStore: store,
        downloadPath: '${temp.path}/indirilen',
      )
        ..onPairingRequest = ((_) async => PairingDecision.trust)
        ..esitleme = esitleme;
      await server.start(0);
      addTearDown(server.dispose);

      final folder = Directory('${temp.path}/lifeos-klasor/Proje')
        ..createSync(recursive: true);
      File('${folder.path}/lifeosdan.txt').writeAsStringSync('merhaba');
      final run = await peer([
        'esitle',
        '${temp.path}/lifeos',
        '${server.boundPort}',
        'telefon-e2',
        folder.path,
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      final out = jsonDecode((run.stdout as String).trim().split('\n').last)
          as Map<String, dynamic>;
      expect(out['paired'], true);
      final here = out['remotePath'] as String;
      expect(here, '${temp.path}/Eşitlenen/Proje');
      await waitFor(File('$here/lifeosdan.txt'), 'merhaba');

      File('$here/telefondan.txt').writeAsStringSync('selam');
      await waitFor(File('${folder.path}/telefondan.txt'), 'selam');
      expect(esitleme.permission(store.devices.single.id), isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
