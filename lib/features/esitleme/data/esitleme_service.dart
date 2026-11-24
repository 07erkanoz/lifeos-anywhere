import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/core/tls/peer_tls.dart';
import 'package:anyware/features/esitleme/data/syncthing.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

final _log = AppLogger('Esitleme');

/// One synced folder, as LifeOS keeps it (yakin-esitle.json).
class SyncedFolder {
  const SyncedFolder({
    required this.id,
    required this.path,
    required this.device,
    required this.label,
    this.state = 'kapalı',
    this.needBytes = 0,
    this.error = '',
  });

  /// `lifeos-` + 12 hex: the same id on both sides.
  final String id;
  final String path;

  /// The paired device (its Yakındakiler id).
  final String device;
  final String label;

  /// eşit, bekliyor, taranıyor, eşitleniyor, hata, kapalı
  final String state;
  final int needBytes;
  final String error;
}

class EsitlemeException implements Exception {
  const EsitlemeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Folder sync with paired devices through Syncthing, the way LifeOS does it
/// (lifeos_store/yakin_esitle.py), so a phone and a LifeOS computer — or two
/// AnyWhere devices — keep a folder the same:
///
/// * Syncthing device ids are exchanged over Yakındakiler's pinned TLS
///   (`GET /api/esitle`), only with a device paired with encryption whose
///   user allowed "eşitleme" (asked once).
/// * `POST /api/esitle/klasor` shares a folder: the other side adds it under
///   its Eşitlenen folder; both send and receive.
/// * `POST /api/esitle/birak` stops it; the files stay on both sides.
///
/// Conflicts, partial files, deletes and versions are Syncthing's: an edit on
/// both sides keeps both (`.sync-conflict-…`), nothing is half-written.
class EsitlemeService {
  EsitlemeService({
    required this.syncthing,
    required this.trustStore,
    required this.settingsFile,
    required this.incomingRoot,
  });

  final Syncthing syncthing;
  final TrustStore trustStore;

  /// esitleme.json: devices, ports, folders, permissions.
  final File settingsFile;

  /// Where folders other devices share with this one land (Eşitlenen).
  final Directory incomingRoot;

  /// Asks the user once whether [device] may sync folders with this one;
  /// `null` = no answer (not kept: asked again next time, as LifeOS does).
  Future<bool?> Function(TrustedDevice device)? askPermission;

  /// Told when another device starts syncing a folder here.
  void Function(TrustedDevice device, SyncedFolder folder)? onFolderAdded;

  final Map<String, Future<bool>> _asking = {};

  static final RegExp _folderId = RegExp(r'^lifeos-[0-9a-f]{12}$');
  static final RegExp _deviceIdPattern = RegExp(r'^[A-Z0-9-]{50,70}$');

  // ── settings ──────────────────────────────────────────────────────────

  Map<String, dynamic> _read() {
    try {
      if (settingsFile.existsSync()) {
        final data = jsonDecode(settingsFile.readAsStringSync());
        if (data is Map<String, dynamic>) {
          for (final k in ['devices', 'ports', 'folders', 'allowed']) {
            data[k] ??= <String, dynamic>{};
          }
          return data;
        }
      }
    } catch (e) {
      _log.warning('esitleme.json unreadable: $e');
    }
    return {'devices': {}, 'ports': {}, 'folders': {}, 'allowed': {}};
  }

  void _save(Map<String, dynamic> data) {
    settingsFile.parent.createSync(recursive: true);
    final temp = File('${settingsFile.path}.tmp');
    temp.writeAsStringSync(jsonEncode(data), flush: true);
    temp.renameSync(settingsFile.path);
  }

  bool get hasFolders => (_read()['folders'] as Map).isNotEmpty;

  /// Whether [deviceId] may sync with this device: `null` = not asked yet.
  bool? permission(String deviceId) =>
      (_read()['allowed'] as Map)[deviceId] as bool?;

  void setPermission(String deviceId, bool allow) {
    final data = _read();
    (data['allowed'] as Map)[deviceId] = allow;
    _save(data);
  }

  Future<bool> _allowed(TrustedDevice device) {
    final decided = permission(device.id);
    if (decided != null) return Future.value(decided);
    final ask = askPermission;
    if (ask == null) return Future.value(false);
    return _asking[device.id] ??= ask(device).then((yes) {
      if (yes != null) setPermission(device.id, yes);
      return yes ?? false;
    }).whenComplete(() {
      // not `=> remove(...)`: that returns this very future, which would then
      // wait for itself
      _asking.remove(device.id);
    });
  }

  // ── Syncthing ─────────────────────────────────────────────────────────

  Future<void> _addDevice(String stId, String name, String ip, int port) {
    return syncthing.api('PUT', '/rest/config/devices/$stId', body: {
      'deviceID': stId,
      'name': name,
      'addresses': ip.isNotEmpty ? ['tcp://$ip:$port'] : ['dynamic'],
      'autoAcceptFolders': false,
      'introducer': false,
      'compression': 'metadata',
    });
  }

  Future<void> _addFolder(
    String id,
    String label,
    String path,
    List<String> devices,
  ) async {
    final me = await syncthing.ensure();
    await Directory(path).create(recursive: true);
    await syncthing.api('PUT', '/rest/config/folders/$id', body: {
      'id': id,
      'label': label,
      'path': path,
      'type': 'sendreceive',
      'fsWatcherEnabled': true,
      'rescanIntervalS': 3600,
      'devices': [
        for (final d in {me, ...devices}) {'deviceID': d},
      ],
    });
  }

  Future<void> _forget(String folderId, Map<String, dynamic> data) async {
    try {
      await syncthing.api('DELETE', '/rest/config/folders/$folderId');
    } on SyncthingException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    (data['folders'] as Map).remove(folderId);
    _save(data);
  }

  // ── this device's side of /api/esitle ─────────────────────────────────

  /// Answers `/api/esitle*` for [device], already authenticated over pinned
  /// TLS by the server. Returns the status code and the JSON (or text) body.
  Future<(int, Object)> handle(
    TrustedDevice device,
    String method,
    String path,
    Map<String, dynamic> body,
    String remoteIp,
  ) async {
    if (!device.isPinned) return (403, 'yalniz sifreli eslesmis cihaz');
    if (!await _allowed(device)) return (403, 'izin yok: eşitleme');
    final String myId;
    try {
      myId = await syncthing.ensure();
    } on Object catch (e) {
      return (503, '$e');
    }
    if (path == '/api/esitle' && method == 'GET') {
      return (200, {'deviceId': myId, 'port': syncthing.listenPort});
    }
    final folderId = '${body['id'] ?? ''}';
    if (!_folderId.hasMatch(folderId)) return (400, 'klasor kimligi gecersiz');
    final data = _read();
    if (path == '/api/esitle/klasor' && method == 'POST') {
      final their = '${body['deviceId'] ?? ''}';
      if (!_deviceIdPattern.hasMatch(their)) {
        return (400, 'cihaz kimligi gecersiz');
      }
      final port = (body['port'] as num?)?.toInt() ?? kSyncthingPort;
      await _addDevice(their, device.name, remoteIp, port);
      (data['devices'] as Map)[device.id] = their;
      (data['ports'] as Map)[device.id] = port;
      final known = (data['folders'] as Map)[folderId] as Map?;
      final label = _cleanLabel('${body['label'] ?? ''}');
      final target = known != null
          ? known['path'] as String
          : body['ortak'] == true
              ? _newPlace('${_cleanLabel(device.name)} - Ortak')
              : _newPlace(label);
      await _addFolder(folderId, label, target, [their]);
      (data['folders'] as Map)[folderId] = {
        'path': target,
        'device': device.id,
        'label': label,
      };
      _save(data);
      if (known == null) {
        onFolderAdded?.call(
          device,
          SyncedFolder(id: folderId, path: target, device: device.id, label: label),
        );
      }
      return (200, {'path': target});
    }
    if (path == '/api/esitle/birak' && method == 'POST') {
      final row = (data['folders'] as Map)[folderId] as Map?;
      if (row != null && row['device'] == device.id) {
        await _forget(folderId, data);
      }
      return (200, {'ok': true});
    }
    return (404, 'yok');
  }

  static String _cleanLabel(String label) {
    final clean = label
        .replaceAll(RegExp(r'[/\\\x00-\x1f:*?"<>|]'), '_')
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    return clean.isEmpty ? 'Eşitlenen' : clean;
  }

  String _newPlace(String label) {
    var target = Directory('${incomingRoot.path}/$label');
    var n = 2;
    while (target.existsSync() && target.listSync().isNotEmpty) {
      target = Directory('${incomingRoot.path}/$label ($n)');
      n++;
    }
    return target.path;
  }

  // ── the asking side ───────────────────────────────────────────────────

  /// The folder id both sides use (LifeOS: sha256("folder|peer")[:12]).
  static String folderIdFor(String path, String peerId) =>
      'lifeos-${sha256.convert(utf8.encode('$path|$peerId')).toString().substring(0, 12)}';

  /// Keeps [path] the same here and on [peer] (reached at [ip]:[port], its
  /// Yakındakiler address). Its user is asked once there. Returns where the
  /// folder is on the other side.
  Future<String> syncFolder({
    required TrustedDevice peer,
    required String ip,
    required int port,
    required String path,
    bool ortak = false,
  }) async {
    if (!peer.isPinned) {
      throw EsitlemeException('${peer.name} şifreli eşleşmiş değil.');
    }
    final folder = Directory(path).absolute.path.replaceAll(RegExp(r'/+$'), '');
    if (!Directory(folder).existsSync()) {
      throw EsitlemeException('Klasör yok: $path');
    }
    final myId = await syncthing.ensure();
    final theirs = await _request(peer, ip, port, 'GET', '/api/esitle');
    final theirId = '${theirs['deviceId'] ?? ''}';
    if (!_deviceIdPattern.hasMatch(theirId)) {
      throw EsitlemeException('${peer.name} eşitleme kimliği göndermedi.');
    }
    final theirPort = (theirs['port'] as num?)?.toInt() ?? kSyncthingPort;
    final id = folderIdFor(folder, peer.id);
    final label = folder.split(Platform.pathSeparator).last;
    await _addDevice(theirId, peer.name, ip, theirPort);
    await _addFolder(id, label, folder, [theirId]);
    final reply = await _request(peer, ip, port, 'POST', '/api/esitle/klasor', {
      'id': id,
      'label': label,
      'deviceId': myId,
      'port': syncthing.listenPort,
      if (ortak) 'ortak': true,
    });
    final data = _read(); // kept only once the other side took it
    (data['devices'] as Map)[peer.id] = theirId;
    (data['ports'] as Map)[peer.id] = theirPort;
    (data['folders'] as Map)[id] = {
      'path': folder,
      'device': peer.id,
      'label': label,
    };
    _save(data);
    return '${reply['path'] ?? ''}';
  }

  /// No longer synced, here and there; the files stay on both.
  Future<void> stop(String folderId, {String? ip, int? port}) async {
    final data = _read();
    final row = (data['folders'] as Map)[folderId] as Map?;
    if (row == null) throw EsitlemeException('Eşitlenen böyle bir klasör yok.');
    if (syncthing.isRunning) {
      await _forget(folderId, data);
    } else {
      (data['folders'] as Map).remove(folderId);
      _save(data);
    }
    final peer = trustStore.byId('${row['device']}');
    if (peer != null && ip != null && port != null) {
      try {
        await _request(peer, ip, port, 'POST', '/api/esitle/birak', {'id': folderId});
      } catch (_) {
        // off now: it keeps its copy, and its Syncthing no longer finds this one
      }
    }
  }

  /// Each synced folder and how far it is.
  Future<List<SyncedFolder>> folders() async {
    final data = _read();
    final rows = <SyncedFolder>[];
    for (final entry in (data['folders'] as Map).entries) {
      final row = entry.value as Map;
      var state = 'kapalı';
      var need = 0;
      var error = '';
      if (syncthing.isRunning) {
        try {
          final status = await syncthing.api('GET', '/rest/db/status?folder=${entry.key}');
          need = (status['needBytes'] as num?)?.toInt() ?? 0;
          error = '${status['error'] ?? ''}';
          state = switch (status['state']) {
            'idle' => need == 0 ? 'eşit' : 'bekliyor',
            'scanning' || 'scan-waiting' => 'taranıyor',
            'syncing' || 'sync-preparing' || 'sync-waiting' => 'eşitleniyor',
            'error' => 'hata',
            final s => '$s',
          };
        } catch (_) {
          state = 'bilinmiyor';
        }
      }
      rows.add(SyncedFolder(
        id: entry.key as String,
        path: row['path'] as String,
        device: row['device'] as String,
        label: row['label'] as String? ?? '',
        state: state,
        needBytes: need,
        error: error,
      ));
    }
    return rows;
  }

  /// Starts Syncthing when there is something to sync (app start, service).
  Future<void> resume() async {
    if (hasFolders) await syncthing.ensure();
  }

  /// A paired device was heard at [ip]: its Syncthing address follows (DHCP
  /// moves it), as LifeOS's refresh_addresses.
  Future<void> heard(String deviceId, String ip) async {
    if (!syncthing.isRunning || ip.isEmpty) return;
    final data = _read();
    final stId = (data['devices'] as Map)[deviceId] as String?;
    if (stId == null) return;
    final port = ((data['ports'] as Map)[deviceId] as num?)?.toInt() ?? kSyncthingPort;
    try {
      final row = await syncthing.api('GET', '/rest/config/devices/$stId');
      final want = ['tcp://$ip:$port'];
      if (jsonEncode(row['addresses']) != jsonEncode(want)) {
        await _addDevice(stId, '${row['name'] ?? ''}', ip, port);
      }
    } catch (e) {
      _log.debug('address refresh: $e');
    }
  }

  Future<Map<String, dynamic>> _request(
    TrustedDevice peer,
    String ip,
    int port,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = PeerTls.instance.uriFor(ip, port, path, deviceId: peer.id, tls: true);
    final headers = {
      'Content-Type': 'application/json',
      ...trustStore.authHeaders(peer.id),
    };
    final client = PeerTls.instance.shared;
    final response = await (method == 'GET'
            ? client.get(uri, headers: headers)
            : client.post(uri, headers: headers, body: jsonEncode(body ?? {})))
        .timeout(const Duration(seconds: 75)); // the other side may be asking its user
    if (response.statusCode == 403) {
      throw EsitlemeException(
        '${peer.name} izin vermedi (ya da soru yanıtlanmadı).',
      );
    }
    if (response.statusCode != 200) {
      throw EsitlemeException(
        '${peer.name}: ${response.statusCode} ${utf8.decode(response.bodyBytes)}',
      );
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
}
