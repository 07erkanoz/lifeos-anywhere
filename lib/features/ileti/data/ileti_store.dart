import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';

final _log = AppLogger('IletiStore');

/// Conversations on disk, one file per device, sealed with AES-256-GCM. The
/// key is the system keystore's (Android Keystore, libsecret, Windows
/// Credential Manager); where there is none, a private file beside the data.
class IletiStore {
  IletiStore(this.dir, {FlutterSecureStorage? secure})
      : _secure = secure ?? const FlutterSecureStorage();

  final Directory dir;
  final FlutterSecureStorage _secure;
  Uint8List? _key;

  static const _keyName = 'ileti_store_key';

  Future<Uint8List> _getKey() async {
    if (_key != null) return _key!;
    String? stored;
    try {
      stored = await _secure.read(key: _keyName);
    } catch (e) {
      _log.debug('secure storage unavailable: $e');
    }
    final file = File('${dir.path}/.anahtar');
    stored ??= file.existsSync() ? file.readAsStringSync().trim() : null;
    if (stored == null || stored.isEmpty) {
      final r = Random.secure();
      stored = base64.encode(List.generate(32, (_) => r.nextInt(256)));
      try {
        await _secure.write(key: _keyName, value: stored);
      } catch (_) {
        await dir.create(recursive: true);
        file.writeAsStringSync(stored);
        if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
      }
    }
    return _key = base64.decode(stored);
  }

  File _fileFor(String device) {
    final name = sha256.convert(utf8.encode(device)).toString().substring(0, 24);
    return File('${dir.path}/$name.ileti');
  }

  Future<List<IletiMessage>> load(String device) async {
    final file = _fileFor(device);
    if (!file.existsSync()) return [];
    try {
      final raw = await file.readAsBytes();
      final plain = _open(await _getKey(), raw);
      final list = jsonDecode(utf8.decode(plain)) as List;
      return [for (final m in list) IletiMessage.fromJson(m as Map<String, dynamic>)];
    } catch (e) {
      _log.warning('conversation unreadable ($device): $e');
      return [];
    }
  }

  /// The device ids with a saved conversation (from the index file).
  Future<List<String>> devices() async {
    final index = File('${dir.path}/index.ileti');
    if (!index.existsSync()) return [];
    try {
      final plain = _open(await _getKey(), await index.readAsBytes());
      return (jsonDecode(utf8.decode(plain)) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String device, List<IletiMessage> messages, Iterable<String> allDevices) async {
    await dir.create(recursive: true);
    final key = await _getKey();
    await _write(_fileFor(device), _seal(key, utf8.encode(jsonEncode([for (final m in messages) m.toJson()]))));
    await _write(File('${dir.path}/index.ileti'), _seal(key, utf8.encode(jsonEncode(allDevices.toList()))));
  }

  Future<void> forget(String device) async {
    final f = _fileFor(device);
    if (f.existsSync()) await f.delete();
  }

  static Future<void> _write(File file, Uint8List bytes) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  static Uint8List _seal(Uint8List key, List<int> plain) {
    final r = Random.secure();
    final nonce = Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return Uint8List.fromList([...nonce, ...gcm.process(Uint8List.fromList(plain))]);
  }

  static Uint8List _open(Uint8List key, Uint8List sealed) {
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, sealed.sublist(0, 12), Uint8List(0)));
    return gcm.process(sealed.sublist(12));
  }
}
