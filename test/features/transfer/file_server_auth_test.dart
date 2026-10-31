import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/transfer/data/file_server.dart';

void main() {
  late Directory tempDir;
  late TrustStore store;
  late FileServer server;
  late List<PairingRequest> prompts;
  late PairingDecision answer;
  late int clipboardWrites;

  Uri url(String path, [Map<String, String>? query]) =>
      Uri.http('127.0.0.1:${server.boundPort}', path, query);

  Map<String, String> json([Map<String, String> extra = const {}]) => {
    'Content-Type': 'application/json',
    ...extra,
  };

  const newClient = {kProtocolHeader: '1.1'};

  String sendRequestBody(String senderId, {String name = 'a.txt'}) =>
      jsonEncode({
        'fileName': name,
        'fileSize': 3,
        'senderId': senderId,
        'senderName': 'Telefon',
        'senderPlatform': 'android',
      });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = TrustStore(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('lifeos_auth_test_');
    prompts = [];
    answer = PairingDecision.trust;
    clipboardWrites = 0;
    server =
        FileServer(
            localDevice: Device(
              id: 'receiver',
              name: 'Receiver',
              ip: '127.0.0.1',
              port: 0,
              platform: 'linux',
              version: '1.1',
              lastSeen: DateTime.now(),
            ),
            trustStore: store,
            downloadPath: tempDir.path,
          )
          ..onPairingRequest = (request) async {
            prompts.add(request);
            return answer;
          }
          ..onClipboardReceived = (_) => clipboardWrites++;
    await server.start(0);
  });

  tearDown(() async {
    await server.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('discovery endpoints stay open, browse and sync need pairing', () async {
    expect((await http.get(url('/api/info'))).statusCode, 200);
    expect((await http.get(url('/api/ping'))).statusCode, 200);

    final browse = await http.get(url('/api/browse', {'path': '/'}));
    expect(browse.statusCode, 401);
    expect(browse.body, contains('pairing_required'));

    final pull = await http.get(url('/api/sync/pull', {'path': 'x'}));
    expect(pull.statusCode, 401);

    final bogus = await http.get(
      url('/api/browse'),
      headers: {kPairTokenHeader: 'not-a-token'},
    );
    expect(bogus.statusCode, 401);
  });

  test(
    'first send-request pairs once, then the token is used silently',
    () async {
      final first = await http.post(
        url('/api/send-request'),
        headers: json(newClient),
        body: sendRequestBody('phone'),
      );
      final firstJson = jsonDecode(first.body) as Map<String, dynamic>;
      expect(firstJson['accepted'], isTrue);
      expect(prompts, hasLength(1));
      expect(prompts.single.deviceName, 'Telefon');
      expect(prompts.single.platform, 'android');

      final token = firstJson['pairingToken'] as String;
      expect(store.tokenFor('phone'), token);

      final second = await http.post(
        url('/api/send-request'),
        headers: json({...newClient, kPairTokenHeader: token}),
        body: sendRequestBody('phone', name: 'b.txt'),
      );
      final secondJson = jsonDecode(second.body) as Map<String, dynamic>;
      expect(secondJson['accepted'], isTrue);
      expect(secondJson.containsKey('pairingToken'), isFalse);
      expect(prompts, hasLength(1), reason: 'paired devices are not asked');

      final browse = await http.get(
        url('/api/browse', {'path': tempDir.path}),
        headers: {kPairTokenHeader: token},
      );
      expect(browse.statusCode, 200);
    },
  );

  test(
    'a rejected transfer cannot be uploaded and is not asked again',
    () async {
      answer = PairingDecision.reject;
      final response = await http.post(
        url('/api/send-request'),
        headers: json(newClient),
        body: sendRequestBody('stranger'),
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['accepted'], isFalse);
      expect(body.containsKey('pairingToken'), isFalse);
      expect(store.isTrusted('stranger'), isFalse);

      final upload = await http.post(
        url('/api/upload/${body['transferId']}'),
        body: 'abc',
      );
      expect(upload.statusCode, 403);

      await http.post(
        url('/api/send-request'),
        headers: json(newClient),
        body: sendRequestBody('stranger', name: 'c.txt'),
      );
      expect(prompts, hasLength(1), reason: 'rejection cooldown');
    },
  );

  test(
    'allow once accepts the transfer without remembering the device',
    () async {
      answer = PairingDecision.allowOnce;
      final response = await http.post(
        url('/api/send-request'),
        headers: json(newClient),
        body: sendRequestBody('guest'),
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['accepted'], isTrue);
      expect(body.containsKey('pairingToken'), isFalse);
      expect(store.isTrusted('guest'), isFalse);
    },
  );

  test(
    'clipboard from an unpaired device is rejected, never written',
    () async {
      final response = await http.post(
        url('/api/clipboard'),
        headers: json(newClient),
        body: jsonEncode({
          'text': 'gizli',
          'sender': 'Telefon',
          'senderDeviceId': 'phone',
          'type': 'text',
        }),
      );
      expect(response.statusCode, 403);
      expect(response.body, contains('pairing_required'));
      expect(clipboardWrites, 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(prompts.single.reason, PairingReason.clipboard);
    },
  );

  test('old 1.0.x sender (no token support) is trusted by id + IP', () async {
    final response = await http.post(
      url('/api/send-request'),
      headers: json(),
      body: sendRequestBody('old-pc'),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    expect(body['accepted'], isTrue);
    expect(body.containsKey('pairingToken'), isFalse);
    expect(store.byId('old-pc')!.isLegacy, isTrue);
    expect(store.byId('old-pc')!.lastIp, '127.0.0.1');

    // Same IP, no token: allowed (weaker legacy trust).
    final browse = await http.get(url('/api/browse', {'path': tempDir.path}));
    expect(browse.statusCode, 200);

    // Once updated to 1.1 it gets a real token without a new prompt.
    final upgraded = await http.post(
      url('/api/send-request'),
      headers: json(newClient),
      body: sendRequestBody('old-pc', name: 'd.txt'),
    );
    final upgradedJson = jsonDecode(upgraded.body) as Map<String, dynamic>;
    expect(upgradedJson['pairingToken'], isA<String>());
    expect(store.byId('old-pc')!.isLegacy, isFalse);
    expect(prompts, hasLength(1));
  });

  test('QR pairing code pairs without a prompt', () async {
    final code = store.issuePairCode();
    final response = await http.post(
      url('/api/pair'),
      headers: json(newClient),
      body: jsonEncode({
        'id': 'scanner',
        'name': 'Tablet',
        'platform': 'android',
        'pairCode': code,
      }),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    expect(body['paired'], isTrue);
    expect(body['token'], store.tokenFor('scanner'));
    expect((body['device'] as Map)['id'], 'receiver');
    expect(prompts, isEmpty);
  });

  test('web portal needs the key, then a cookie', () async {
    expect((await http.get(url('/portal'))).statusCode, 401);
    expect((await http.get(url('/portal/api/files'))).statusCode, 401);

    final page = await http.get(url('/portal', {'k': store.portalKey}));
    expect(page.statusCode, 200);
    final cookie = page.headers['set-cookie']!.split(';').first;

    final files = await http.get(
      url('/portal/api/files'),
      headers: {'cookie': cookie},
    );
    expect(files.statusCode, 200);
  });

  test('received file names are sanitized', () {
    expect(FileServer.sanitizeFileName('..'), 'file');
    expect(FileServer.sanitizeFileName('a<b>:c?.txt'), 'a_b__c_.txt');
    expect(FileServer.sanitizeFileName('CON.txt'), '_CON.txt');
    expect(FileServer.sanitizeFileName('name. '), 'name');
    expect(FileServer.sanitizeFileName('bad\u0000name'), 'badname');
    expect(
      FileServer.sanitizeRelativePath(r'..\..\etc/./passwd'),
      'etc/passwd',
    );
    expect(FileServer.sanitizeRelativePath('../'), 'file');
  });
}
