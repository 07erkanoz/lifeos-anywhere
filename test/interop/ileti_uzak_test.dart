// Remote pairing by code (no shared network) between AnyWhere and LifeOS's own
// code, both ways, through the REAL LifeOS server; then a message over the
// internet. Opt-in, it opens boxes there:
//
//   ILETI_SUNUCU=1 LIFEOS_ARCH=../lifeOSArch flutter test test/interop/ileti_uzak_test.dart
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
final boxes = <String>[];

void main() {
  late Directory temp;
  late TrustStore store;
  late IletiLan lan;
  late IletiPosta posta;
  late IletiUzak uzak;

  Future<Map<String, dynamic>> peer(List<String> args) async {
    final run = await Process.run('python3', [peerScript, ...args], environment: {'LIFEOS_ARCH': lifeosArch!});
    expect(run.exitCode, 0, reason: '${run.stderr}');
    return jsonDecode((run.stdout as String).trim().split('\n').where((l) => l.startsWith('{')).last)
        as Map<String, dynamic>;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('anywhere_uzak_');
    SharedPreferences.setMockInitialValues({});
    store = TrustStore(await SharedPreferences.getInstance());
    PeerTls.instance.trustStore = store;
    await TlsIdentity.load(Directory('${temp.path}/tls'));
    lan = IletiLan(
      trustStore: store,
      myId: 'telefon-uzak',
      myName: () => 'Nubia telefon',
      addressOf: (_) => null, // never on the same network
      certDir: Directory('${temp.path}/ileti/sertifikalar'),
      incomingDir: (_) async => Directory('${temp.path}/gelen'),
    );
    posta = IletiPosta(lan: lan, trustStore: store, stateFile: File('${temp.path}/ileti/posta.json'));
    lan
      ..myBox = (() => posta.myBox)
      ..onPeerBox = posta.peerBox;
    uzak = IletiUzak(posta: posta, lan: lan, trustStore: store, platform: 'android');
  });

  tearDown(() async {
    if (posta.myBox != null) boxes.add(posta.myBox!);
    await temp.delete(recursive: true);
  });

  tearDownAll(() {
    // ignore: avoid_print
    print('BOXES ${boxes.join(' ')}');
  });

  final skip = lifeosArch == null || !optedIn ? 'needs LIFEOS_ARCH and ILETI_SUNUCU=1 (uses the real server)' : false;

  test('AnyWhere makes the code, LifeOS joins; then a message over the internet', () async {
    final (:code, :token) = await uzak.invite();
    expect(code, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$')));
    final joining = peer(['posta-katil', '${temp.path}/lifeos', code.toLowerCase().replaceAll('-', ' ')]);
    final mine = await uzak.wait(code, token);
    final theirs = await joining;
    final done = theirs['done'] as Map;
    expect(mine, isNotNull);
    expect(done['code'], mine!.code); // the same 6 digits on both screens
    expect(done['id'], 'telefon-uzak');
    final there = (theirs['trust'] as Map)['telefon-uzak'] as Map;
    expect(there['platform'], 'android'); // not "linux": LifeOS keeps what the device says
    expect(there['uzak'], true);
    expect(there['fingerprint'], TlsIdentity.current!.fingerprint);
    final lifeos = store.byId(mine.deviceId)!;
    expect(lifeos.isPinned, isTrue);
    expect(lifeos.token, there['token']); // one token on both sides (the inviter's)
    boxes.add(posta.boxOf(lifeos.id)!);

    // they never met on a network, yet a message goes
    expect(posta.canReach(lifeos.id), isTrue);
    final m = IletiMessage(id: IletiNotifier.newId(), device: lifeos.id, outgoing: true, time: DateTime.now(),
        text: 'Hiç aynı ağda olmadık, merhaba');
    expect((await posta.deliver(m)).status, IletiStatus.onServer);
    final conv = ((await peer(['posta-al', '${temp.path}/lifeos', 'telefon-uzak']))['conversation'] as Map)['messages'] as List;
    expect(conv.map((x) => x['text']), contains('Hiç aynı ağda olmadık, merhaba'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));

  test('LifeOS makes the code, AnyWhere joins', () async {
    final code = (await peer(['posta-davet', '${temp.path}/lifeos']))['code'] as String;
    final paired = await uzak.join(code);
    final waited = await peer(['posta-bekle', '${temp.path}/lifeos', code]);
    final done = waited['done'] as Map;
    expect(done['paired'], true, reason: '$waited');
    expect(done['code'], paired.code);
    expect(((waited['trust'] as Map)['telefon-uzak'] as Map)['platform'], 'android');
    expect(store.byId(paired.deviceId)!.isPinned, isTrue);
    boxes.add(posta.boxOf(paired.deviceId)!);

    // a wrong code is refused, without pairing anything
    expect(() => IletiUzak.clean('K7Q2-9MXA'), throwsA(isA<RemotePairingException>()));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));
}
