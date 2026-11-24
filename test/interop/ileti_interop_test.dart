// LifeOS İleti between AnyWhere and LifeOS's own code (lifeos_store/
// ileti.py) on the local network, both ways: text, a file, read receipts.
// Needs a lifeOSArch checkout:
//
//   LIFEOS_ARCH=../lifeOSArch flutter test test/interop/ileti_interop_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/pairing_client.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/transfer/data/file_server.dart';

final String? lifeosArch = Platform.environment['LIFEOS_ARCH'];
final String peerScript = '${Directory.current.path}/test/interop/lifeos_peer.py';

void main() {
  late Directory temp;
  late TrustStore store;

  Future<Map<String, dynamic>> peer(List<String> args) async {
    final run = await Process.run('python3', [peerScript, ...args], environment: {'LIFEOS_ARCH': lifeosArch ?? ''});
    expect(run.exitCode, 0, reason: '${run.stderr}');
    return jsonDecode((run.stdout as String).trim().split('\n').where((l) => l.startsWith('{')).last)
        as Map<String, dynamic>;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('anywhere_ileti_');
    SharedPreferences.setMockInitialValues({});
    store = TrustStore(await SharedPreferences.getInstance());
    PeerTls.instance.trustStore = store;
    expect(await TlsIdentity.load(Directory('${temp.path}/tls')), isNotNull);
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'chat with LifeOS İleti: text, a file and read receipts, both ways',
    () async {
      const phoneId = 'telefon-ileti';
      // LifeOS
      final lifeos = await Process.start('python3', [peerScript, 'server', '${temp.path}/lifeos'],
          environment: {'LIFEOS_ARCH': lifeosArch!});
      addTearDown(lifeos.kill);
      final lines = lifeos.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.startsWith('{'))
          .asBroadcastStream();
      final info = jsonDecode(await lines.first) as Map<String, dynamic>;
      final lifeosPort = info['port'] as int;
      final lifeosId = info['id'] as String;

      // AnyWhere: its İleti and its server
      final got = <IletiMessage>[];
      final files = <String, String>{};
      final read = <String>[];
      final lan = IletiLan(
        trustStore: store,
        myId: phoneId,
        myName: () => 'Telefon',
        addressOf: (d) => d == lifeosId ? ('127.0.0.1', lifeosPort) : null,
        certDir: Directory('${temp.path}/sertifikalar'),
        incomingDir: (_) async => Directory('${temp.path}/gelen'),
      )
        ..onMessage = got.add
        ..onFileDone = ((d, id, path) => files[id] = path)
        ..onRead = ((d, ids) => read.addAll(ids));
      final server = FileServer(
        localDevice: Device(
          id: phoneId,
          name: 'Telefon',
          ip: '127.0.0.1',
          port: 0,
          platform: 'android',
          version: '1.1',
          lastSeen: DateTime.now(),
          capabilities: const ['pairing-token', kTlsCapability, 'ileti'],
        ),
        trustStore: store,
        downloadPath: '${temp.path}/indirilen',
      )
        ..onPairingRequest = ((_) async => PairingDecision.trust)
        ..ileti = lan;
      await server.start(0);
      addTearDown(server.dispose);
      final awPort = '${server.boundPort}';

      expect(
        await PairingClient(store).requestPairing(
          ip: '127.0.0.1',
          port: lifeosPort,
          localId: phoneId,
          localName: 'Telefon',
          localPlatform: 'android',
        ),
        PairingResult.paired,
      );

      // AnyWhere → LifeOS: text, then a file with a caption
      final text = IletiMessage(
        id: IletiNotifier.newId(),
        device: lifeosId,
        outgoing: true,
        time: DateTime.now(),
        text: 'Merhaba LifeOS, şifreli 🙂',
      );
      expect((await lan.deliver(text)).status, IletiStatus.sent);
      final sample = File('${temp.path}/rapor.txt')..writeAsStringSync('telefondan dosya\n' * 70000); // > 1 MiB
      final file = IletiMessage(
        id: IletiNotifier.newId(),
        device: lifeosId,
        outgoing: true,
        time: DateTime.now(),
        text: 'rapor bu',
        fileName: 'rapor.txt',
        fileSize: sample.lengthSync(),
        filePath: sample.path,
      );
      expect((await lan.deliver(file)).status, IletiStatus.sent);

      final there = ((await peer(['oku', '${temp.path}/lifeos', phoneId]))['conversation'] as Map)['messages'] as List;
      final inText = there.firstWhere((m) => m['id'] == text.id) as Map;
      expect(inText['out'], false);
      expect(inText['text'], 'Merhaba LifeOS, şifreli 🙂');
      final inFile = there.firstWhere((m) => m['id'] == file.id) as Map;
      expect(inFile['text'], 'rapor bu');
      expect((inFile['ek'] as Map)['state'], 'tamam');
      expect(File((inFile['ek'] as Map)['path'] as String).readAsStringSync(), sample.readAsStringSync());

      // LifeOS read them: its receipt reaches AnyWhere
      await peer(['okundu', '${temp.path}/lifeos', awPort, phoneId]);
      expect(read, containsAll([text.id, file.id]));

      // LifeOS → AnyWhere: text, then a file
      final photo = File('${temp.path}/foto.jpg')..writeAsBytesSync(List.generate(300000, (i) => i % 251));
      final sent = await peer(['yaz', '${temp.path}/lifeos', awPort, phoneId, 'Selam telefon', photo.path]);
      final states = ((sent['conversation'] as Map)['messages'] as List)
          .where((m) => m['out'] == true)
          .map((m) => m['state'])
          .toList();
      expect(states, everyElement(isIn(['iletildi', 'okundu'])), reason: '$sent');
      expect(got.map((m) => m.text), contains('Selam telefon'));
      final incoming = got.firstWhere((m) => m.fileName == 'foto.jpg');
      expect(incoming.fileSize, 300000);
      expect(File(files[incoming.id]!).readAsBytesSync(), photo.readAsBytesSync());
      await lifeos.stdin.close();
    },
    skip: lifeosArch == null ? 'LIFEOS_ARCH is not set' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
