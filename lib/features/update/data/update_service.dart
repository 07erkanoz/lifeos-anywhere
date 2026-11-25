import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';

final _log = AppLogger('Update');

/// A release as lifeos.com.tr's version.json describes it, for this platform.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    required this.name,
    required this.size,
    required this.sha256,
    required this.url,
    this.notesTr = '',
    this.notesEn = '',
    this.page = '',
  });

  final String version;
  final int build;
  final String name;
  final int size;
  final String sha256;
  final String url;
  final String notesTr;
  final String notesEn;
  final String page;

  String notesFor(String locale) => (locale == 'tr' ? notesTr : notesEn).trim().isNotEmpty
      ? (locale == 'tr' ? notesTr : notesEn).trim()
      : (notesEn.trim().isNotEmpty ? notesEn : notesTr).trim();

  /// The release in [json] for [platform] (`android`, `windows`), or null.
  static AppRelease? fromFeed(Map<String, dynamic> json, String platform) {
    final file = (json['files'] as Map?)?[platform] as Map?;
    final url = (json['downloads'] as Map?)?[platform] as String?;
    final version = '${json['latest'] ?? ''}';
    if (file == null || url == null || version.isEmpty) return null;
    final notes = (json['notes'] as Map?) ?? const {};
    return AppRelease(
      version: version,
      build: (json['build'] as num?)?.toInt() ?? 0,
      name: '${file['name']}',
      size: (file['size'] as num?)?.toInt() ?? 0,
      sha256: '${file['sha256'] ?? ''}'.toLowerCase(),
      url: url,
      notesTr: '${notes['tr'] ?? ''}',
      notesEn: '${notes['en'] ?? ''}',
      page: '${json['page'] ?? ''}',
    );
  }
}

/// Finds a newer release, downloads its package (size and SHA-256 checked)
/// and hands it to the system: Android's installer, or the Windows setup.
class UpdateService {
  UpdateService({http.Client? client, this.feed = AppConstants.updateFeedUrl}) : _client = client ?? http.Client();

  final http.Client _client;
  final String feed;

  static const _channel = MethodChannel('com.lifeos.anyware/platform');

  /// The platform's key in version.json; null where the app cannot update itself.
  static String? get platformKey {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return null;
  }

  /// Whether [version] (+[build]) is newer than what runs. Build numbers win
  /// when both are known; otherwise the versions are compared part by part.
  static bool isNewer(String version, int build, {String current = AppConstants.appVersion, int currentBuild = AppConstants.appBuild}) {
    if (build > 0 && currentBuild > 0) return build > currentBuild;
    List<int> parts(String v) => v.split(RegExp(r'[.+-]')).map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(version), b = parts(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// The newer release for this platform, or null (up to date, or none).
  Future<AppRelease?> check() async {
    final key = platformKey;
    if (key == null) return null;
    final r = await _client
        .get(Uri.parse('$feed?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}'), headers: {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw HttpException('version.json: ${r.statusCode}');
    final release = AppRelease.fromFeed(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>, key);
    if (release == null) return null;
    _log.info('latest ${release.version}+${release.build}, here ${AppConstants.appVersion}+${AppConstants.appBuild}');
    return isNewer(release.version, release.build) ? release : null;
  }

  /// Downloads [release]'s package; [onProgress] 0..1. A package already
  /// downloaded and intact is used as it is.
  Future<File> download(AppRelease release, {void Function(int received, int total)? onProgress, bool Function()? cancelled}) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}anywhere-update');
    await dir.create(recursive: true);
    final target = File('${dir.path}${Platform.pathSeparator}${release.name}');
    if (target.existsSync() && target.lengthSync() == release.size && await _sha256(target) == release.sha256) {
      onProgress?.call(release.size, release.size);
      return target;
    }
    // older packages go
    for (final f in dir.listSync().whereType<File>()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    final part = File('${target.path}.part');
    final response = await _client.send(http.Request('GET', Uri.parse(release.url))).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw HttpException('${release.name}: ${response.statusCode}');
    final total = response.contentLength ?? release.size;
    final sink = part.openWrite();
    final digest = _DigestSink();
    final hasher = crypto.sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        if (cancelled?.call() ?? false) throw const UpdateCancelled();
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      hasher.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      if (part.existsSync()) part.deleteSync();
      rethrow;
    }
    if (received != release.size || (release.sha256.isNotEmpty && digest.value.toString() != release.sha256)) {
      part.deleteSync();
      throw const FormatException('indirilen paket bozuk');
    }
    return part.renameSync(target.path);
  }

  static Future<String> _sha256(File f) async => (await crypto.sha256.bind(f.openRead()).first).toString();

  /// Where this Android app came from; "com.android.vending" is Google Play
  /// (which updates it itself: no package from elsewhere there).
  static Future<String?> installer() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('installerPackage');
    } catch (_) {
      return null;
    }
  }

  /// Opens the package: Android asks to install it (true when the installer
  /// opened; false when the "install unknown apps" permission was asked for
  /// first). Windows runs the setup quietly; the app then closes, and the
  /// setup starts it again.
  Future<bool> install(File package) async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('openFile', {
            'path': package.path,
            'mimeType': 'application/vnd.android.package-archive',
          }) ??
          false;
    }
    if (Platform.isWindows) {
      await Process.start(
        package.path,
        ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/RELAUNCH=1'],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    return false;
  }
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
  @override
  String toString() => 'iptal';
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
