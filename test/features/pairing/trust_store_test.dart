import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('stores a pairing and finds it by token, persisted', () async {
    final store = TrustStore(prefs);
    final token = store.newToken();
    expect(token.length, greaterThanOrEqualTo(43)); // 32 bytes, base64url

    await store.trust(
      id: 'peer',
      name: 'Telefon',
      platform: 'android',
      token: token,
      ip: '192.168.1.20',
    );

    expect(store.byToken(token)?.id, 'peer');
    expect(store.byToken('${token}x'), isNull);
    expect(store.tokenFor('peer'), token);
    expect(store.authHeaders('peer')[kPairTokenHeader], token);
    expect(store.authHeaders('other').containsKey(kPairTokenHeader), isFalse);
    expect(store.authHeaders('other')[kProtocolHeader], '1.1');

    final reloaded = TrustStore(prefs);
    expect(reloaded.byToken(token)?.name, 'Telefon');

    await reloaded.remove('peer');
    expect(TrustStore(prefs).isTrusted('peer'), isFalse);
  });

  test('legacy pairing is trusted by IP only and has no token', () async {
    final store = TrustStore(prefs);
    await store.trust(
      id: 'old',
      name: 'Eski PC',
      platform: 'windows',
      token: null,
      ip: '10.0.0.5',
    );
    expect(store.byId('old')!.isLegacy, isTrue);
    expect(store.tokenFor('old'), isNull);
    expect(store.legacyByIp('10.0.0.5')?.id, 'old');
    expect(store.legacyByIp('10.0.0.6'), isNull);
  });

  test('QR pairing codes are single use', () {
    final store = TrustStore(prefs);
    final code = store.issuePairCode();
    expect(store.consumePairCode('wrong'), isFalse);
    expect(store.consumePairCode(code), isTrue);
    expect(store.consumePairCode(code), isFalse);
  });

  test('portal key is stable and checked', () {
    final store = TrustStore(prefs);
    final key = store.portalKey;
    expect(TrustStore(prefs).portalKey, key);
    expect(store.checkPortalKey(key), isTrue);
    expect(store.checkPortalKey(''), isFalse);
    expect(store.checkPortalKey(null), isFalse);
  });

  test('Device JSON only adds the capabilities key', () {
    final device = Device(
      id: 'a',
      name: 'A',
      ip: '1.2.3.4',
      port: 48739,
      platform: 'linux',
      version: '1.1',
      lastSeen: DateTime(2026),
      capabilities: const ['pairing-token'],
    );
    final json = device.toJson();
    expect(json['capabilities'], ['pairing-token']);
    expect(Device.fromJson(json).supportsPairingToken, isTrue);

    // A 1.0.x device JSON (no capabilities) still parses.
    json.remove('capabilities');
    expect(Device.fromJson(json).supportsPairingToken, isFalse);
  });
}
