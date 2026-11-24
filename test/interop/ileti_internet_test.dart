// LifeOS İleti over the internet, AnyWhere ↔ LifeOS's own code, through the
// REAL LifeOS server (its mailbox). Opt-in, it opens two boxes there:
//
//   ILETI_SUNUCU=1 LIFEOS_ARCH=../lifeOSArch flutter test test/interop/ileti_internet_test.dart
//
// AnyWhere opens its box with its own key (lifeos-ileti-ac, no shared key);
// the two learn each other's box on the network, then talk while "away".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/data/ileti_posta.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/pairing_client.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/transfer/data/file_server.dart';

final String? lifeosArch = Platform.environment['LIFEOS_ARCH'];
final bool optedIn = Platform.environment['ILETI_SUNUCU'] == '1';
final String peerScript = '${Directory.current.path}/test/interop/lifeos_peer.py';

Future<void> until(bool Function() ok, String what, {int seconds = 120}) async {
  for (var i = 0; i < seconds * 4; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('$what did not happen in ${seconds}s');
}

void main() {
  test(
    'text both ways through the LifeOS server, with delivery receipts',
    () async {
      final temp = await Directory.systemTemp.createTemp('anywhere_posta_');
      addTearDown(() => temp.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final store = TrustStore(await SharedPreferences.getInstance());
      PeerTls.instance.trustStore = store;
      await TlsIdentity.load(Directory('${temp.path}/tls'));
      const phoneId = 'telefon-posta';

      Future<Map<String, dynamic>> peer(List<String> args) async {
        final run = await Process.run('python3', [peerScript, ...args], environment: {'LIFEOS_ARCH': lifeosArch!});
        expect(run.exitCode, 0, reason: '${run.stderr}');
        return jsonDecode((run.stdout as String).trim().split('\n').where((l) => l.startsWith('{')).last)
            as Map<String, dynamic>;
      }

      final lifeos = await Process.start('python3', [peerScript, 'server', '${temp.path}/lifeos'],
          environment: {'LIFEOS_ARCH': lifeosArch!});
      addTearDown(lifeos.kill);
      // read to the end: LifeOS writes pairing codes there too (a closed pipe would break it)
      final lines = lifeos.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.startsWith('{'))
          .asBroadcastStream();
      final info = jsonDecode(await lines.first) as Map<String, dynamic>;
      lines.listen((_) {});
      final lifeosId = info['id'] as String;

      var lifeosHere = true;
      final got = <IletiMessage>[];
      final delivered = <String>[];
      final lan = IletiLan(
        trustStore: store,
        myId: phoneId,
        myName: () => 'Telefon',
        addressOf: (d) => d == lifeosId && lifeosHere ? ('127.0.0.1', info['port'] as int) : null,
        certDir: Directory('${temp.path}/ileti/sertifikalar'),
        incomingDir: (_) async => Directory('${temp.path}/gelen'),
      )..onMessage = got.add;
      final posta = IletiPosta(lan: lan, trustStore: store, stateFile: File('${temp.path}/ileti/posta.json'))
        ..onMessage = got.add
        ..onDelivered = ((d, ids) => delivered.addAll(ids));
      lan
        ..myBox = (() => posta.myBox)
        ..onPeerBox = posta.peerBox;
      final server = FileServer(
        localDevice: Device(id: phoneId, name: 'Telefon', ip: '127.0.0.1', port: 0, platform: 'android',
            version: '1.1', lastSeen: DateTime.now(), capabilities: const ['pairing-token', kTlsCapability, 'ileti']),
        trustStore: store,
        downloadPath: '${temp.path}/indirilen',
      )
        ..onPairingRequest = ((_) async => PairingDecision.trust)
        ..ileti = lan;
      await server.start(0);
      addTearDown(server.dispose);
      expect(
        await PairingClient(store).requestPairing(
            ip: '127.0.0.1', port: info['port'] as int, localId: phoneId, localName: 'Telefon', localPlatform: 'android'),
        PairingResult.paired,
      );

      // AnyWhere opens its own box, without any shared key
      posta.start();
      addTearDown(posta.stop);
      await until(() => posta.myBox != null, 'opening the box');
      expect(posta.myBox, posta.expectedAddress);

      // on the network: LifeOS opens its box and the two tell each other theirs
      final met = await peer(['posta-tanis', '${temp.path}/lifeos', '${server.boundPort}', phoneId]);
      expect(met['theirs'], posta.myBox, reason: '$met');
      expect(posta.boxOf(lifeosId), met['adres']);
      expect(lan.pairKeyFor(store.byId(lifeosId)!), isNotNull);
      await Future<void>.delayed(const Duration(seconds: 3)); // izin reaches the server

      // away: AnyWhere → LifeOS through the server
      lifeosHere = false;
      final text = IletiMessage(id: IletiNotifier.newId(), device: lifeosId, outgoing: true, time: DateTime.now(),
          text: 'İnternetten merhaba LifeOS');
      expect(posta.canReach(lifeosId), isTrue);
      expect((await posta.deliver(text)).status, IletiStatus.onServer);
      final there = ((await peer(['posta-al', '${temp.path}/lifeos', phoneId]))['conversation'] as Map)['messages'] as List;
      expect(there.map((m) => m['text']), contains('İnternetten merhaba LifeOS'));
      await until(() => delivered.contains(text.id), 'the delivery receipt');

      // LifeOS → AnyWhere through the server
      await peer(['posta-yaz', '${temp.path}/lifeos', phoneId, 'Sunucudan selam telefon']);
      await until(() => got.any((m) => m.text == 'Sunucudan selam telefon'), 'the message from LifeOS');
      expect(got.firstWhere((m) => m.text == 'Sunucudan selam telefon').via, IletiVia.internet);
      // ignore: avoid_print
      print('BOXES ${posta.myBox} ${met['adres']}');
      await lifeos.stdin.close();
    },
    skip: lifeosArch == null || !optedIn ? 'needs LIFEOS_ARCH and ILETI_SUNUCU=1 (uses the real server)' : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
