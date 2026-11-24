// Files over the internet between AnyWhere and LifeOS's own code, through the
// REAL LifeOS server (it passes them on; nothing is stored there): the two
// paired by code, never on the same network. Opt-in, it opens boxes there:
//
//   ILETI_SUNUCU=1 LIFEOS_ARCH=../lifeOSArch flutter test test/interop/ileti_dosya_internet_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/data/ileti_posta.dart';
import 'package:anyware/features/ileti/data/ileti_uzak.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

final String? lifeosArch = Platform.environment['LIFEOS_ARCH'];
final bool optedIn = Platform.environment['ILETI_SUNUCU'] == '1';
final String peerScript = '${Directory.current.path}/test/interop/lifeos_peer.py';

Future<void> until(bool Function() ok, String what, {int seconds = 150}) async {
  for (var i = 0; i < seconds * 4; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('$what did not happen in ${seconds}s');
}

void main() {
  test('a file each way through the server, the two online, never on one network', () async {
    final temp = await Directory.systemTemp.createTemp('anywhere_dosya_');
    addTearDown(() => temp.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final store = TrustStore(await SharedPreferences.getInstance());
    PeerTls.instance.trustStore = store;
    await TlsIdentity.load(Directory('${temp.path}/tls'));
    final env = {'LIFEOS_ARCH': lifeosArch!};
    final root = '${temp.path}/lifeos';

    final got = <IletiMessage>[];
    final files = <String, String>{};
    final sent = <String>[];
    final presence = <String, (bool, DateTime?)>{};
    final lan = IletiLan(
      trustStore: store,
      myId: 'telefon-dosya',
      myName: () => 'Nubia telefon',
      addressOf: (_) => null,
      certDir: Directory('${temp.path}/ileti/sertifikalar'),
      incomingDir: (_) async => Directory('${temp.path}/gelen'),
    )
      ..onMessage = got.add
      ..onFileDone = ((d, id, path) => files[id] = path);
    final posta = IletiPosta(lan: lan, trustStore: store, stateFile: File('${temp.path}/ileti/posta.json'))
      ..onMessage = got.add
      ..onFileSent = ((d, id) => sent.add(id))
      ..onPresence = presence.addAll;
    lan
      ..myBox = (() => posta.myBox)
      ..onPeerBox = posta.peerBox;
    final uzak = IletiUzak(posta: posta, lan: lan, trustStore: store, platform: 'android');

    // paired by code
    final (:code, :token) = await uzak.invite();
    final joining = Process.run('python3', [peerScript, 'posta-katil', root, code], environment: env);
    final lifeos = (await uzak.wait(code, token))!;
    expect((await joining).exitCode, 0);
    posta.start();
    addTearDown(posta.stop);

    // LifeOS online, sending a photo to the phone (away); the phone sends one back
    final photo = File('${temp.path}/foto.jpg')..writeAsBytesSync(List.generate(1500000, (i) => (i * 7) % 256));
    final running = Process.start('python3', [peerScript, 'posta-calis', root, '110', 'telefon-dosya', photo.path],
        environment: env);
    final proc = await running;
    final out = StringBuffer();
    proc.stdout.transform(utf8.decoder).listen(out.write);
    proc.stderr.transform(utf8.decoder).listen((_) {});

    await until(() => presence[lifeos.deviceId]?.$1 == true, 'LifeOS online (presence)', seconds: 90);
    final back = File('${temp.path}/rapor.pdf')..writeAsBytesSync(List.generate(2300000, (i) => (i * 13) % 256));
    final m = IletiMessage(id: IletiNotifier.newId(), device: lifeos.deviceId, outgoing: true, time: DateTime.now(),
        text: 'rapor ekte', fileName: 'rapor.pdf', fileSize: back.lengthSync(), filePath: back.path);
    expect((await posta.deliver(m)).status, IletiStatus.onServer);

    await until(() => sent.contains(m.id), 'the phone\'s file arriving at LifeOS (dosya-tamam)');
    await until(() => files.values.any((p) => p.endsWith('foto.jpg')), 'LifeOS\'s photo arriving at the phone');
    final fromLifeos = got.firstWhere((x) => x.fileName == 'foto.jpg');
    expect(File(files[fromLifeos.id]!).readAsBytesSync(), photo.readAsBytesSync());
    expect(fromLifeos.text, 'internetten dosya');

    expect(await proc.exitCode, 0);
    final conv = (jsonDecode(out.toString().trim().split('\n').where((l) => l.startsWith('{')).last)
        as Map)['conversation'] as Map;
    final inFile = (conv['messages'] as List).firstWhere((x) => x['id'] == m.id) as Map;
    expect((inFile['ek'] as Map)['state'], 'tamam');
    expect(File((inFile['ek'] as Map)['path'] as String).readAsBytesSync(), back.readAsBytesSync());
    // ignore: avoid_print
    print('BOXES ${posta.myBox} ${posta.boxOf(lifeos.deviceId)}');
  },
      skip: lifeosArch == null || !optedIn ? 'needs LIFEOS_ARCH and ILETI_SUNUCU=1 (uses the real server)' : false,
      timeout: const Timeout(Duration(minutes: 5)));
}
