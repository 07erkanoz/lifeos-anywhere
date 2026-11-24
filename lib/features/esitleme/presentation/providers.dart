import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/esitleme/data/esitleme_service.dart';
import 'package:anyware/features/esitleme/data/syncthing.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';

final _log = AppLogger('EsitlemeProviders');

/// Where folders other devices share with this one land.
Future<Directory> _incomingRoot() async {
  if (Platform.isAndroid) return Directory('/storage/emulated/0/Eşitlenen');
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      (await getApplicationDocumentsDirectory()).path;
  return Directory('$home${Platform.pathSeparator}Eşitlenen');
}

/// Folder sync through Syncthing (LifeOS-compatible). Lives for the whole app;
/// Syncthing itself starts only once a folder is synced.
final esitlemeServiceProvider = FutureProvider<EsitlemeService>((ref) async {
  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  final syncthing = Syncthing(home: Directory('${support.path}${sep}syncthing'));
  final service = EsitlemeService(
    syncthing: syncthing,
    trustStore: ref.read(trustStoreProvider),
    settingsFile: File('${support.path}${sep}esitleme.json'),
    incomingRoot: await _incomingRoot(),
  );
  service.askPermission =
      (device) => ref.read(esitlemePromptProvider.notifier).ask(device);
  ref.onDispose(() => unawaited(syncthing.stop()));

  // A paired device's Syncthing address follows where it was last heard.
  ref.listen<AsyncValue<List<Device>>>(devicesProvider, (_, next) {
    for (final d in next.valueOrNull ?? const <Device>[]) {
      unawaited(service.heard(d.id, d.ip));
    }
  });

  unawaited(service.resume().catchError((Object e) {
    _log.warning('Syncthing did not start: $e');
  }));
  return service;
});

/// Synced folders and their state; refreshed every few seconds while watched.
final syncedFoldersProvider =
    StreamProvider.autoDispose<List<SyncedFolder>>((ref) async* {
  final service = await ref.watch(esitlemeServiceProvider.future);
  while (true) {
    yield await service.folders();
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

/// A "may X sync folders with this device?" question waiting for an answer.
class PendingEsitlemePrompt {
  PendingEsitlemePrompt(this.device);
  final TrustedDevice device;
  final Completer<bool?> _completer = Completer<bool?>();
}

class EsitlemePromptNotifier extends StateNotifier<List<PendingEsitlemePrompt>> {
  EsitlemePromptNotifier() : super(const []);

  /// The other side waits 75 s; no answer by then is no answer (asked again).
  static const Duration timeout = Duration(seconds: 60);

  Future<bool?> ask(TrustedDevice device) {
    final prompt = PendingEsitlemePrompt(device);
    state = [...state, prompt];
    return prompt._completer.future.timeout(timeout, onTimeout: () {
      resolve(prompt, null);
      return null;
    });
  }

  void resolve(PendingEsitlemePrompt prompt, bool? allow) {
    if (!prompt._completer.isCompleted) prompt._completer.complete(allow);
    state = state.where((p) => !identical(p, prompt)).toList();
  }
}

final esitlemePromptProvider =
    StateNotifierProvider<EsitlemePromptNotifier, List<PendingEsitlemePrompt>>(
  (ref) => EsitlemePromptNotifier(),
);
