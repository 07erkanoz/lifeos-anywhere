import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/update/data/update_service.dart';

final _log = AppLogger('Update');

enum UpdatePhase { idle, checking, upToDate, available, downloading, ready, installing, failed }

class UpdateState {
  const UpdateState({this.phase = UpdatePhase.idle, this.release, this.received = 0, this.total = 0, this.error, this.fromPlay = false});
  final UpdatePhase phase;
  final AppRelease? release;
  final int received;
  final int total;
  final String? error;

  /// Installed from Google Play: Play updates it; the sheet sends there.
  final bool fromPlay;

  double get progress => total <= 0 ? 0 : (received / total).clamp(0, 1);

  UpdateState copyWith({UpdatePhase? phase, AppRelease? release, int? received, int? total, String? error, bool? fromPlay}) =>
      UpdateState(
        phase: phase ?? this.phase,
        release: release ?? this.release,
        received: received ?? this.received,
        total: total ?? this.total,
        error: error,
        fromPlay: fromPlay ?? this.fromPlay,
      );
}

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier(this._ref, {UpdateService? service}) : _service = service ?? UpdateService(), super(const UpdateState());

  final Ref _ref;
  final UpdateService _service;
  File? _package;
  bool _cancel = false;

  static const _skipKey = 'update_skip_version';

  bool get supported => UpdateService.platformKey != null;

  /// Looks for a newer release. Returns it when the user should be asked
  /// ([quiet]: not when they chose to skip that version).
  Future<AppRelease?> check({bool quiet = false}) async {
    if (!supported) return null;
    if (state.phase == UpdatePhase.checking || state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.installing) {
      return null;
    }
    state = state.copyWith(phase: UpdatePhase.checking);
    try {
      final release = await _service.check();
      final fromPlay = await UpdateService.installer() == 'com.android.vending';
      if (release == null) {
        state = UpdateState(phase: UpdatePhase.upToDate, fromPlay: fromPlay);
        return null;
      }
      state = UpdateState(phase: UpdatePhase.available, release: release, fromPlay: fromPlay);
      final skipped = _ref.read(sharedPreferencesProvider).getString(_skipKey);
      return quiet && skipped == release.version ? null : release;
    } catch (e) {
      _log.info('check: $e');
      state = UpdateState(phase: quiet ? UpdatePhase.idle : UpdatePhase.failed, error: '$e');
      return null;
    }
  }

  Future<void> skip() async {
    final v = state.release?.version;
    if (v != null) await _ref.read(sharedPreferencesProvider).setString(_skipKey, v);
  }

  /// Downloads (if need be) and installs.
  Future<void> update() async {
    final release = state.release;
    if (release == null) return;
    _cancel = false;
    try {
      if (_package == null || !_package!.existsSync()) {
        state = state.copyWith(phase: UpdatePhase.downloading, received: 0, total: release.size);
        _package = await _service.download(
          release,
          cancelled: () => _cancel,
          onProgress: (r, t) {
            // a few hundred updates, not one per network chunk
            if (r == t || r - state.received > t ~/ 200) {
              state = state.copyWith(phase: UpdatePhase.downloading, received: r, total: t);
            }
          },
        );
      }
      state = state.copyWith(phase: UpdatePhase.ready, received: release.size, total: release.size);
      await install();
    } on UpdateCancelled {
      state = state.copyWith(phase: UpdatePhase.available, received: 0);
    } catch (e) {
      _log.warning('update: $e');
      state = state.copyWith(phase: UpdatePhase.failed, error: '$e');
    }
  }

  Future<void> install() async {
    final package = _package;
    if (package == null) return;
    state = state.copyWith(phase: UpdatePhase.installing);
    final opened = await _service.install(package);
    if (Platform.isWindows && opened) {
      // the setup replaces the files and starts the app again
      await Future<void>.delayed(const Duration(milliseconds: 800));
      exit(0);
    }
    // Android: the installer is on screen (or its permission was asked for first)
    state = state.copyWith(phase: UpdatePhase.ready);
  }

  void cancel() => _cancel = true;
}

final updateProvider = StateNotifierProvider<UpdateNotifier, UpdateState>((ref) => UpdateNotifier(ref));
