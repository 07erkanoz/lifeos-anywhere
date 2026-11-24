import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:anyware/core/logger.dart';

final _log = AppLogger('Syncthing');

/// Syncthing's own connections (BEP), the port LifeOS uses too
/// (lifeos_store/yakin_esitle.py): its firewall opens it to the local network.
const int kSyncthingPort = 48763;

/// The Syncthing version bundled with the app (tool/syncthing.sh, CI).
const String kSyncthingVersion = 'v2.1.7';

/// AnyWhere's own Syncthing instance, as LifeOS runs its own: a private home,
/// REST on 127.0.0.1 only with a random key, and never the internet — no
/// global discovery, relays, NAT or local announcements. A peer's address is
/// told to it by Yakındakiler. The user never sees Syncthing itself.
///
/// The options are written into config.xml before the first start, so even
/// that first start contacts nothing outside the local network.
class Syncthing {
  Syncthing({required this.home, String? binary, this.listenPort = kSyncthingPort})
      : _binary = binary;

  /// Syncthing's home (config, keys, database).
  final Directory home;

  final String? _binary;

  /// Where Syncthing listens; another free port when this one is taken (a
  /// LifeOS computer running its own Syncthing beside AnyWhere).
  int listenPort;

  Process? _process;
  int? _guiPort;
  String? _apiKey;
  String? _myId;
  Future<String>? _starting;

  /// The binary to run, or `null` where there is none (iOS, macOS, a Linux
  /// without it). Android: packed as a native library so it may be executed.
  static Future<String?> findBinary() async {
    if (Platform.isAndroid) {
      try {
        final dir = await const MethodChannel('com.lifeos.anyware/platform')
            .invokeMethod<String>('nativeLibraryDir');
        if (dir != null && File('$dir/libsyncthing.so').existsSync()) {
          return '$dir/libsyncthing.so';
        }
      } on PlatformException catch (e) {
        _log.warning('nativeLibraryDir: $e');
      }
      return null;
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) {
      final bundled = '$exeDir\\syncthing.exe';
      return File(bundled).existsSync() ? bundled : null;
    }
    if (Platform.isLinux) {
      final bundled = '$exeDir/lib/syncthing';
      if (File(bundled).existsSync()) return bundled;
      for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
        if (dir.isNotEmpty && File('$dir/syncthing').existsSync()) {
          return '$dir/syncthing';
        }
      }
    }
    return null;
  }

  bool get isRunning => _process != null && _myId != null;

  /// This instance's device id once it runs.
  String? get myId => _myId;

  /// Started if need be; this instance's device id.
  Future<String> ensure() {
    if (isRunning) return Future.value(_myId!);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<String> _start() async {
    final binary = _binary ?? await findBinary();
    if (binary == null) {
      throw const SyncthingException('Syncthing bu cihazda yok');
    }
    await home.create(recursive: true);
    final keyFile = File('${home.path}/anywhere-apikey');
    _apiKey = keyFile.existsSync() ? keyFile.readAsStringSync().trim() : '';
    if (_apiKey!.isEmpty) {
      _apiKey = _randomKey();
      keyFile.writeAsStringSync(_apiKey!);
    }
    if (!await _portFree(listenPort)) listenPort = await _freePort();
    _guiPort = await _freePort();
    final config = File('${home.path}/config.xml');
    if (!config.existsSync()) {
      config.writeAsStringSync(_initialConfig(listenPort));
    }
    _log.info('Starting $binary (listen $listenPort)');
    final process = await Process.start(
      binary,
      [
        'serve',
        '--home=${home.path}',
        '--no-browser',
        '--no-restart',
        '--no-upgrade',
        '--gui-address=http://127.0.0.1:$_guiPort',
        '--gui-apikey=$_apiKey',
      ],
      environment: {'STNODEFAULTFOLDER': '1', 'STNOUPGRADE': '1'},
    );
    _process = process;
    process.stdout.transform(utf8.decoder).listen((_) {});
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.debug(line));
    unawaited(process.exitCode.then((code) {
      _log.info('Syncthing exited ($code)');
      if (identical(_process, process)) {
        _process = null;
        _myId = null;
      }
    }));
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (true) {
      if (_process == null) {
        throw const SyncthingException('Syncthing başlamadı');
      }
      try {
        final ping = await api('GET', '/rest/system/ping',
            timeout: const Duration(seconds: 2));
        if (ping['ping'] == 'pong') break;
      } catch (_) {}
      if (DateTime.now().isAfter(deadline)) {
        await stop();
        throw const SyncthingException('Syncthing başlamadı');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await _configure();
    _myId = (await api('GET', '/rest/system/status'))['myID'] as String;
    return _myId!;
  }

  /// The options LifeOS sets: never the internet, never asks anything; the
  /// listen address follows [listenPort].
  Future<void> _configure() async {
    final want = {
      ..._lanOnly,
      'listenAddresses': ['tcp://0.0.0.0:$listenPort'],
    };
    final current = await api('GET', '/rest/config/options');
    final differs = want.entries.any(
      (e) => jsonEncode(current[e.key]) != jsonEncode(e.value),
    );
    if (differs) await api('PATCH', '/rest/config/options', body: want);
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    _myId = null;
    if (process == null) return;
    try {
      await api('POST', '/rest/system/shutdown',
          timeout: const Duration(seconds: 3));
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
    }
  }

  /// Syncthing's REST API; the decoded JSON (or `{}`).
  Future<dynamic> api(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final port = _guiPort;
    if (port == null) throw const SyncthingException('Syncthing çalışmıyor');
    final request = http.Request(method, Uri.parse('http://127.0.0.1:$port$path'))
      ..headers['X-API-Key'] = _apiKey ?? ''
      ..headers['Content-Type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await request.send().timeout(timeout),
    );
    if (response.statusCode >= 300) {
      throw SyncthingException(
        'Syncthing $method $path: ${response.statusCode} ${response.body}',
        statusCode: response.statusCode,
      );
    }
    final text = response.body.trim();
    return text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
  }

  static const Map<String, Object> _lanOnly = {
    'globalAnnounceEnabled': false,
    'localAnnounceEnabled': false,
    'relaysEnabled': false,
    'natEnabled': false,
    'urAccepted': -1,
    'crashReportingEnabled': false,
    'autoUpgradeIntervalH': 0,
    'startBrowser': false,
    'announceLANAddresses': false,
  };

  static String _initialConfig(int port) => '''
<configuration version="37">
  <options>
    <listenAddress>tcp://0.0.0.0:$port</listenAddress>
    <globalAnnounceEnabled>false</globalAnnounceEnabled>
    <localAnnounceEnabled>false</localAnnounceEnabled>
    <relaysEnabled>false</relaysEnabled>
    <natEnabled>false</natEnabled>
    <urAccepted>-1</urAccepted>
    <crashReportingEnabled>false</crashReportingEnabled>
    <autoUpgradeIntervalH>0</autoUpgradeIntervalH>
    <startBrowser>false</startBrowser>
    <announceLANAddresses>false</announceLANAddresses>
  </options>
</configuration>
''';

  static String _randomKey() {
    final r = Random.secure();
    return base64Url.encode(List.generate(24, (_) => r.nextInt(256)));
  }

  static Future<bool> _portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await s.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }
}

class SyncthingException implements Exception {
  const SyncthingException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}
