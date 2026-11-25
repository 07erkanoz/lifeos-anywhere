import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/data/ileti_posta.dart';
import 'package:anyware/features/ileti/data/ileti_uzak.dart';
import 'package:anyware/features/ileti/data/ileti_store.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';
import 'package:anyware/features/notifications/message_notifications.dart';

final _log = AppLogger('Ileti');

/// A way to deliver a message to a paired device: the local network first,
/// then the LifeOS server's mailbox. Each answers what it managed.
abstract class IletiTransport {
  /// Whether it can try [device] now (reachable this way).
  bool canReach(String device);
  IletiVia get via;

  /// Delivers [message]; throws when it could not.
  Future<IletiMessage> deliver(IletiMessage message);
}

/// Every conversation, by device id; newest last.
class IletiNotifier extends StateNotifier<Map<String, List<IletiMessage>>> {
  /// [initial]: conversations to start with instead of the saved ones (tests).
  IletiNotifier({Map<String, List<IletiMessage>>? initial}) : super(initial ?? const {}) {
    if (initial == null) unawaited(_load());
  }

  IletiStore? _store;
  final List<IletiTransport> transports = [];
  Timer? _pump;

  Future<IletiStore> _getStore() async {
    return _store ??= IletiStore(
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}ileti'),
    );
  }

  bool _loadedFromDisk = false;

  Future<void> _load() async {
    _loadedFromDisk = true;
    final store = await _getStore();
    final loaded = <String, List<IletiMessage>>{};
    for (final d in await store.devices()) {
      loaded[d] = await store.load(d);
    }
    state = {...loaded, ...state};
    // whatever waited for a device goes when it can be reached
    _pump = Timer.periodic(const Duration(seconds: 10), (_) => _flush());
  }

  @override
  void dispose() {
    _pump?.cancel();
    for (final device in [..._saveTimers.keys]) {
      unawaited(_saveNow(device));
    }
    super.dispose();
  }

  bool get _inMemory => _store == null && _pump == null;

  /// Changes a message on screen at once; the conversation is written a
  /// moment later, once for a burst of changes. Writing (and sealing) the
  /// whole conversation on every status change — before the message even
  /// left — is what made sending feel slow.
  Future<void> _put(IletiMessage m) async {
    final list = [...?state[m.device]];
    final i = list.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      list[i] = m;
    } else {
      list.add(m);
      list.sort((a, b) => a.time.compareTo(b.time));
    }
    state = {...state, m.device: list};
    if (_inMemory && _loadedFromDisk == false) return;
    _saveTimers[m.device]?.cancel();
    _saveTimers[m.device] = Timer(const Duration(milliseconds: 400), () => unawaited(_saveNow(m.device)));
  }

  final Map<String, Timer> _saveTimers = {};
  Future<void> _saving = Future.value();

  /// Writes [device]'s conversation (one write at a time).
  Future<void> _saveNow(String device) {
    _saveTimers.remove(device)?.cancel();
    // taken now: on dispose the state cannot be read later
    final list = state[device];
    final all = state.keys.toList();
    if (list == null) return _saving;
    return _saving = _saving.then((_) async {
      try {
        await (await _getStore()).save(device, list, all);
      } catch (e) {
        _log.warning('conversation with $device not saved: $e');
      }
    });
  }

  /// A UUID4, as LifeOS's message ids.
  static String newId() => const Uuid().v4();

  Future<void> sendText(String device, String text) async {
    final m = IletiMessage(
      id: newId(),
      device: device,
      outgoing: true,
      time: DateTime.now(),
      text: text,
    );
    await _put(m);
    await _deliver(m);
  }

  Future<void> sendFiles(String device, List<String> paths) async {
    for (final path in paths) {
      final f = File(path);
      final m = IletiMessage(
        id: newId(),
        device: device,
        outgoing: true,
        time: DateTime.now(),
        fileName: f.uri.pathSegments.last,
        fileSize: f.existsSync() ? f.lengthSync() : null,
        filePath: path,
      );
      await _put(m);
      unawaited(_deliver(m));
    }
  }

  /// The text on this device's clipboard, as a message.
  Future<void> sendClipboard(String device) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (text.isNotEmpty) await sendText(device, text);
  }

  Future<void> retry(IletiMessage m) async {
    await _put(m.copyWith(status: IletiStatus.pending));
    await _deliver(m);
  }

  Future<void> _deliver(IletiMessage m) async {
    for (final t in transports) {
      if (!t.canReach(m.device)) continue;
      await _put(m.copyWith(status: IletiStatus.sending, via: t.via));
      try {
        final done = await t.deliver(m);
        await _put(done);
        return;
      } catch (e) {
        _log.info('${t.via.name}: ${m.id} not delivered: $e');
      }
    }
    // nobody could take it now: it waits (sent when the device is reachable)
    await _put(m.copyWith(status: IletiStatus.pending));
  }

  bool _flushing = false;

  /// Sends what waits, now (a device came on the network, the app came
  /// back, the mailbox opened). Runs one at a time; devices in parallel, so
  /// one that does not answer does not hold up the others.
  Future<void> flush() => _flush();

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await Future.wait([
        for (final MapEntry(key: device, value: list) in state.entries)
          if (transports.any((t) => t.canReach(device)))
            () async {
              for (final m in list.where((x) => x.outgoing && x.status == IletiStatus.pending)) {
                await _deliver(m);
              }
            }(),
      ]);
    } finally {
      _flushing = false;
    }
  }

  /// A message that came in (from any transport).
  Future<void> received(IletiMessage m) async {
    if (state[m.device]?.any((x) => x.id == m.id) ?? false) return;
    await _put(m);
    onNew?.call(m);
  }

  /// A message that came in, the first time (a notification).
  void Function(IletiMessage m)? onNew;

  IletiMessage? _find(String device, String id) =>
      state[device]?.where((m) => m.id == id).firstOrNull;

  /// A file moving (either way).
  void fileProgress(String device, String id, double progress) {
    final m = _find(device, id);
    if (m == null) return;
    final list = [...state[device]!];
    list[list.indexOf(m)] = m.copyWith(progress: progress);
    state = {...state, device: list}; // not saved: progress is transient
  }

  Future<void> fileDone(String device, String id, String path) async {
    final m = _find(device, id);
    if (m != null) await _put(m.copyWith(filePath: path, clearProgress: true));
  }

  Future<void> fileFailed(String device, String id, String error) async {
    final m = _find(device, id);
    if (m != null) await _put(m.copyWith(error: error, clearProgress: true));
  }

  /// The other side took what waited for it on the server.
  Future<void> markDelivered(String device, Iterable<String> ids) async {
    final set = ids.toSet();
    for (final m in [...?state[device]]) {
      if (set.contains(m.id) && m.outgoing && m.status == IletiStatus.onServer) {
        await _put(m.copyWith(status: IletiStatus.sent));
      }
    }
  }

  /// How a message (or its file) went or came.
  Future<void> markVia(String device, String id, IletiVia via) async {
    final m = _find(device, id);
    if (m != null) await _put(m.copyWith(via: via, clearProgress: true));
  }

  /// The other side read it.
  Future<void> markRead(String device, Iterable<String> ids) async {
    final set = ids.toSet();
    for (final m in [...?state[device]]) {
      if (set.contains(m.id) && m.outgoing && m.status != IletiStatus.read) {
        await _put(m.copyWith(status: IletiStatus.read));
      }
    }
  }

  /// Seen here: incoming messages of [device] marked seen.
  Future<void> markSeen(String device) async {
    final unseen = [...?state[device]].where((m) => m.status == IletiStatus.unread).toList();
    for (final m in unseen) {
      await _put(m.copyWith(status: IletiStatus.seen));
    }
    onSeen?.call(device, unseen.map((m) => m.id).toList());
    if (unseen.isNotEmpty) unawaited(MessageNotifications.instance.clear(device));
  }

  /// Told when messages were seen here (read receipts go back).
  void Function(String device, List<String> ids)? onSeen;

  /// Whether [device] can get messages over the internet (its mailbox is
  /// known): online, they go now; offline, they wait on the server.
  bool canMail(String device) =>
      transports.any((t) => t.via == IletiVia.internet && t.canReach(device));

  int unreadCount(String device) =>
      state[device]?.where((m) => m.status == IletiStatus.unread).length ?? 0;
}

final iletiProvider = StateNotifierProvider<IletiNotifier, Map<String, List<IletiMessage>>>(
  (ref) => IletiNotifier(),
);

/// İleti on the local network, plugged into the conversations and (through
/// fileServerProvider) into the server's /api/ileti*.
final iletiLanProvider = FutureProvider<IletiLan>((ref) async {
  final me = await ref.watch(localDeviceProvider.future);
  final notifier = ref.read(iletiProvider.notifier);
  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  final lan = IletiLan(
    trustStore: ref.read(trustStoreProvider),
    myId: me.id,
    myName: () => ref.read(settingsProvider).deviceName,
    addressOf: (device) {
      final live = ref.read(devicesProvider).valueOrNull ?? const <Device>[];
      final d = live.where((x) => x.id == device).firstOrNull;
      return d == null ? null : (d.ip, d.port);
    },
    certDir: Directory('${support.path}${sep}ileti${sep}sertifikalar'),
    incomingDir: (_) async {
      final path = ref.read(settingsProvider).downloadPath;
      return Directory(path.isNotEmpty ? path : '${support.path}${sep}Gelenler');
    },
  )
    ..onMessage = notifier.received
    ..onFileProgress = notifier.fileProgress
    ..onFileDone = notifier.fileDone
    ..onFileFailed = notifier.fileFailed
    ..onRead = notifier.markRead;
  notifier
    ..transports.removeWhere((t) => t is IletiLan)
    ..transports.insert(0, lan)
    ..onSeen = lan.sendRead;

  // over the internet: the LifeOS server's mailbox, after the network
  final posta = IletiPosta(
    lan: lan,
    trustStore: ref.read(trustStoreProvider),
    stateFile: File('${support.path}${sep}ileti${sep}posta.json'),
  )
    ..onMessage = notifier.received
    ..onDelivered = notifier.markDelivered
    ..onRead = notifier.markRead
    ..onFileProgress = notifier.fileProgress
    ..onFileSent = ((device, id) => notifier.markVia(device, id, IletiVia.relay))
    ..onFileRelayed = ((device, id) => notifier.markVia(device, id, IletiVia.relay))
    ..onFileWaits = ((device, id, _) => notifier.fileFailed(device, id, 'büyük'))
    ..onPresence = ((p) => ref.read(iletiPresenceProvider.notifier).state = p)
    ..onBoxOpened = (() => unawaited(notifier.flush()));
  lan
    ..myBox = (() => posta.myBox)
    ..onPeerBox = posta.peerBox;
  notifier
    ..transports.removeWhere((t) => t is IletiPosta)
    ..transports.add(posta)
    ..onSeen = (device, ids) {
      if (ids.isEmpty) return;
      if (lan.canReach(device)) {
        unawaited(lan.sendRead(device, ids));
      } else {
        unawaited(posta.tell(device, 'okundu', ids).catchError((Object _) {}));
      }
    };
  notifier.onNew = (m) {
    final s = ref.read(settingsProvider);
    if (m.outgoing || !s.notifyMessages) return;
    unawaited(MessageNotifications.instance.show(
      device: m.device,
      title: ref.read(trustStoreProvider).byId(m.device)?.name ?? 'LifeOS',
      body: m.isFile ? S.get('notifyFile', s.locale, {'name': m.fileName ?? ''}) : m.text,
      sound: s.notifySound,
      vibrate: s.notifyVibrate,
    ));
  };
  posta.start();
  // a paired device on this network learns our box and tells its own
  var exchanging = false;
  Future<void> exchangeNow() async {
    if (exchanging) return;
    exchanging = true;
    try {
      await _exchange(ref, lan, posta, notifier);
    } finally {
      exchanging = false;
    }
  }

  final exchange = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(exchangeNow()));
  // a device came (or went) on this network: what waited for it goes now, not at the next tick
  final seenHere = <String>{};
  ref.listen<AsyncValue<List<Device>>>(devicesProvider, (_, next) {
    final ids = {for (final d in next.valueOrNull ?? const <Device>[]) d.id};
    final arrived = ids.difference(seenHere).isNotEmpty;
    seenHere
      ..clear()
      ..addAll(ids);
    if (!arrived) return;
    unawaited(notifier.flush());
    unawaited(exchangeNow());
  });
  // the network changed: the mailbox's waiting fetch is likely dead
  final links = Connectivity().onConnectivityChanged.listen(
    (_) {
      posta.wake();
      unawaited(notifier.flush());
    },
    onError: (Object _) {},
  );
  ref.onDispose(() {
    exchange.cancel();
    unawaited(links.cancel());
    posta.stop();
  });
  return lan;
});

/// The app came back to the screen: the mailbox fetch starts afresh (the
/// one waiting may have died while Android froze the app) and what waits goes.
void iletiResumed(WidgetRef ref) {
  final notifier = ref.read(iletiProvider.notifier);
  for (final t in notifier.transports.whereType<IletiPosta>()) {
    t.wake();
  }
  unawaited(notifier.flush());
}

Future<void> _exchange(Ref ref, IletiLan lan, IletiPosta posta, IletiNotifier notifier) async {
  for (final d in ref.read(trustStoreProvider).devices) {
    if (!d.isPinned || !lan.canReach(d.id)) continue;
    if (posta.needsExchange(d.id)) {
      try {
        await lan.exchangeBoxes(d.id);
        posta.told(d.id);
      } catch (e) {
        _log.debug('box exchange with ${d.name}: $e');
      }
    }
    // a file that waited for the server goes over the network now that the two met
    for (final m in [...?ref.read(iletiProvider)[d.id]]) {
      final row = m.outgoing ? posta.waitingFile(m.id) : null;
      final ek = row == null ? null : row['ek'];
      if (ek == null) continue;
      try {
        await lan.uploadFile(m, Map<String, dynamic>.from(ek as Map));
        posta.fileGone(m.id);
        await notifier.markVia(d.id, m.id, IletiVia.lan);
      } catch (e) {
        _log.debug('waiting file to ${d.name}: $e');
      }
    }
  }
}

/// How [device] is reached now: on this network, over the internet, or not.
final iletiReachProvider = Provider.family<Reach, String>((ref, device) {
  final live = ref.watch(devicesProvider).valueOrNull ?? const <Device>[];
  if (live.any((d) => d.id == device)) return Reach.lan;
  final notifier = ref.watch(iletiProvider.notifier);
  ref.watch(iletiProvider);
  final online = ref.watch(iletiPresenceProvider)[device]?.$1 ?? false;
  if (online && notifier.transports.any((t) => t.via == IletiVia.internet && t.canReach(device))) {
    return Reach.internet;
  }
  return Reach.off;
});

/// Pairing by code with a device far away (ileti_uzak.dart), through the
/// same mailbox İleti uses over the internet.
final iletiUzakProvider = FutureProvider<IletiUzak>((ref) async {
  final lan = await ref.watch(iletiLanProvider.future);
  final posta = ref.read(iletiProvider.notifier).transports.whereType<IletiPosta>().first;
  return IletiUzak(
    posta: posta,
    lan: lan,
    trustStore: ref.read(trustStoreProvider),
    platform: IletiUzak.platformName(),
  );
});

/// Who is online over the internet, by device: (online now, last seen).
final iletiPresenceProvider = StateProvider<Map<String, (bool, DateTime?)>>((ref) => const {});
