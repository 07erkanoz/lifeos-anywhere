import 'package:anyware/features/sync/data/isolate_scanner.dart' show isSyncTempPath;
import 'package:anyware/features/sync/domain/sync_manifest.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Sync Action — one atomic operation in a sync plan
// ═══════════════════════════════════════════════════════════════════════════════

enum SyncActionType {
  /// Send a local file to the remote device.
  sendToRemote,

  /// Pull a file from the remote device to local.
  pullFromRemote,

  /// Delete a file locally (it was deleted on the remote since last sync).
  deleteLocal,

  /// Delete a file on the remote (it was deleted locally since last sync).
  deleteRemote,

  /// Both sides changed — needs conflict resolution.
  conflict,
}

class SyncAction {
  final SyncActionType type;
  final String relativePath;

  /// Local file metadata (null if file doesn't exist locally).
  final SyncManifestEntry? localEntry;

  /// Remote file metadata (null if file doesn't exist remotely).
  final SyncManifestEntry? remoteEntry;

  const SyncAction({
    required this.type,
    required this.relativePath,
    this.localEntry,
    this.remoteEntry,
  });

  @override
  String toString() => 'SyncAction(${type.name}, $relativePath)';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sync Plan — the result of diffing two manifests
// ═══════════════════════════════════════════════════════════════════════════════

class SyncPlan {
  final List<SyncAction> actions;

  const SyncPlan({this.actions = const []});

  List<SyncAction> get sends =>
      actions.where((a) => a.type == SyncActionType.sendToRemote).toList();

  List<SyncAction> get pulls =>
      actions.where((a) => a.type == SyncActionType.pullFromRemote).toList();

  List<SyncAction> get localDeletes =>
      actions.where((a) => a.type == SyncActionType.deleteLocal).toList();

  List<SyncAction> get remoteDeletes =>
      actions.where((a) => a.type == SyncActionType.deleteRemote).toList();

  List<SyncAction> get conflicts =>
      actions.where((a) => a.type == SyncActionType.conflict).toList();

  bool get isEmpty => actions.isEmpty;
  bool get hasConflicts => actions.any((a) => a.type == SyncActionType.conflict);

  int get totalActions => actions.length;

  @override
  String toString() =>
      'SyncPlan(send=${sends.length}, pull=${pulls.length}, '
      'delLocal=${localDeletes.length}, delRemote=${remoteDeletes.length}, '
      'conflicts=${conflicts.length})';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Diff Engine — pure function, no side effects
// ═══════════════════════════════════════════════════════════════════════════════

/// Sentinel for "modification time unknown" (a remote listing that did not
/// report one). Entries carrying it are compared by size/hash only, so a
/// missing mtime never makes a file look changed on every run.
final DateTime kUnknownMtime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

bool _isUnknownMtime(DateTime t) => t.millisecondsSinceEpoch == 0;

/// Computes a [SyncPlan] by comparing local and remote manifests against an
/// optional previous manifest (for delete detection).
///
/// Parameters:
///   - [local]: Current state of the local sync directory.
///   - [remote]: Current state of the remote sync directory.
///   - [previousLocal]: Last known local manifest (from previous sync).
///   - [previousRemote]: Last known remote manifest (from previous sync).
///   - [conflictStrategy]: How to auto-resolve conflicts.
///   - [mirrorDeletions]: Whether to propagate deletions.
///   - [direction]: [SyncDirection.oneWay] only pushes local → remote and
///     never produces an action that changes or deletes a local file.
///   - [localUnknownPaths]: relative paths (files or folder prefixes) whose
///     local state is unknown (unreadable during the scan). No action is
///     derived for anything under them.
///   - [timestampTolerance]: Tolerance for comparing modification times.
///     FAT32 has only 2-second resolution, so a 2s tolerance avoids
///     false conflicts on removable media.
///
/// Rules (bidirectional):
///   - a change on one side since the base is copied to the other side;
///   - a delete on one side since the base is mirrored only when the other
///     side did NOT edit the file since the base — otherwise the edit wins
///     and the file is restored to the deleting side;
///   - both sides changed → [conflictStrategy].
SyncPlan computeSyncPlan({
  required SyncManifest local,
  required SyncManifest remote,
  SyncManifest? previousLocal,
  SyncManifest? previousRemote,
  ConflictStrategy conflictStrategy = ConflictStrategy.newerWins,
  bool mirrorDeletions = true,
  SyncDirection direction = SyncDirection.bidirectional,
  Iterable<String> localUnknownPaths = const [],
  Duration timestampTolerance = const Duration(seconds: 2),
}) {
  final localMap = local.toMap();
  final remoteMap = remote.toMap();
  final prevLocalMap = previousLocal?.toMap() ?? {};
  final prevRemoteMap = previousRemote?.toMap() ?? {};
  final oneWay = direction == SyncDirection.oneWay;
  final unknown = localUnknownPaths.toList();

  final allPaths = <String>{
    ...localMap.keys,
    ...remoteMap.keys,
  };

  final actions = <SyncAction>[];

  for (final path in allPaths) {
    if (isSyncTempPath(path)) continue;
    if (isUnderAny(path, unknown)) continue;

    final localEntry = localMap[path];
    final remoteEntry = remoteMap[path];
    final prevLocal = prevLocalMap[path];
    final prevRemote = prevRemoteMap[path];

    bool localChangedSinceBase(SyncManifestEntry l) =>
        prevLocal == null || !entriesEqual(l, prevLocal, timestampTolerance);
    bool remoteChangedSinceBase(SyncManifestEntry r) =>
        prevRemote == null || !entriesEqual(r, prevRemote, timestampTolerance);

    // ── Case 1: File exists only locally ──
    if (localEntry != null && remoteEntry == null) {
      final remoteDeleted = prevRemote != null;
      if (remoteDeleted &&
          mirrorDeletions &&
          !oneWay &&
          !localChangedSinceBase(localEntry)) {
        // Remote deleted it and local did not touch it → mirror the delete.
        actions.add(SyncAction(
          type: SyncActionType.deleteLocal,
          relativePath: path,
          localEntry: localEntry,
        ));
      } else {
        // New local file, or local edit beats a remote delete, or one-way.
        actions.add(SyncAction(
          type: SyncActionType.sendToRemote,
          relativePath: path,
          localEntry: localEntry,
        ));
      }
      continue;
    }

    // ── Case 2: File exists only remotely ──
    if (localEntry == null && remoteEntry != null) {
      final localDeleted = prevLocal != null;
      if (oneWay) {
        // Local is the source of truth; never pull.
        if (localDeleted && mirrorDeletions) {
          actions.add(SyncAction(
            type: SyncActionType.deleteRemote,
            relativePath: path,
            remoteEntry: remoteEntry,
          ));
        }
        continue;
      }
      if (localDeleted &&
          mirrorDeletions &&
          !remoteChangedSinceBase(remoteEntry)) {
        actions.add(SyncAction(
          type: SyncActionType.deleteRemote,
          relativePath: path,
          remoteEntry: remoteEntry,
        ));
      } else {
        // New remote file, or remote edit beats a local delete.
        actions.add(SyncAction(
          type: SyncActionType.pullFromRemote,
          relativePath: path,
          remoteEntry: remoteEntry,
        ));
      }
      continue;
    }

    // ── Case 3: File exists on both sides ──
    if (localEntry != null && remoteEntry != null) {
      if (entriesEqual(localEntry, remoteEntry, timestampTolerance)) {
        continue; // Already in sync.
      }

      if (oneWay) {
        // Push: remote mirrors local.
        if (localChangedSinceBase(localEntry) ||
            remoteChangedSinceBase(remoteEntry)) {
          actions.add(SyncAction(
            type: SyncActionType.sendToRemote,
            relativePath: path,
            localEntry: localEntry,
            remoteEntry: remoteEntry,
          ));
        }
        continue;
      }

      final localChanged = localChangedSinceBase(localEntry);
      final remoteChanged = remoteChangedSinceBase(remoteEntry);

      if (localChanged && !remoteChanged) {
        actions.add(SyncAction(
          type: SyncActionType.sendToRemote,
          relativePath: path,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
        ));
      } else if (!localChanged && remoteChanged) {
        actions.add(SyncAction(
          type: SyncActionType.pullFromRemote,
          relativePath: path,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
        ));
      } else if (localChanged && remoteChanged) {
        actions.add(_resolveConflict(
          path, localEntry, remoteEntry, conflictStrategy,
        ));
      }
      // else: neither changed since base → nothing to do.
      continue;
    }

    // ── Case 4: in neither current manifest (deleted on both sides) ──
  }

  return SyncPlan(actions: actions);
}

/// Whether [path] equals one of [prefixes] or lies under one of them
/// (prefixes are relative folder or file paths with `/` separators;
/// `.` or empty means "everything").
bool isUnderAny(String path, Iterable<String> prefixes) {
  for (final raw in prefixes) {
    final pre = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    if (pre.isEmpty || pre == '.') return true;
    if (path == pre || path.startsWith('$pre/')) return true;
  }
  return false;
}

/// Hash algorithms differ per side (local SHA-256, Google Drive MD5,
/// OneDrive SHA-1/QuickXor). Only compare hashes of the same kind.
bool _sameHashKind(String a, String b) {
  if (a.length != b.length) return false;
  final hex = RegExp(r'^[0-9a-fA-F]+$');
  return hex.hasMatch(a) == hex.hasMatch(b);
}

/// Compares two manifest entries within a timestamp tolerance.
///
/// Comparable hashes decide when present. An unknown mtime on either side
/// ([kUnknownMtime]) falls back to size only.
bool entriesEqual(
  SyncManifestEntry a,
  SyncManifestEntry b, [
  Duration tolerance = const Duration(seconds: 2),
]) {
  if (a.size != b.size) return false;
  final ha = a.hash, hb = b.hash;
  if (ha != null && hb != null && _sameHashKind(ha, hb)) {
    return ha.toLowerCase() == hb.toLowerCase();
  }
  if (_isUnknownMtime(a.lastModified) || _isUnknownMtime(b.lastModified)) {
    return true;
  }
  return a.lastModified.difference(b.lastModified).abs() <= tolerance;
}

/// Applies the conflict strategy and returns the appropriate action.
SyncAction _resolveConflict(
  String path,
  SyncManifestEntry localEntry,
  SyncManifestEntry remoteEntry,
  ConflictStrategy strategy,
) {
  switch (strategy) {
    case ConflictStrategy.newerWins:
      if (localEntry.lastModified.isAfter(remoteEntry.lastModified)) {
        return SyncAction(
          type: SyncActionType.sendToRemote,
          relativePath: path,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
        );
      } else {
        return SyncAction(
          type: SyncActionType.pullFromRemote,
          relativePath: path,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
        );
      }

    case ConflictStrategy.keepBoth:
    case ConflictStrategy.askUser:
      // The caller keeps both versions (see [conflictCopyPath]) or asks.
      return SyncAction(
        type: SyncActionType.conflict,
        relativePath: path,
        localEntry: localEntry,
        remoteEntry: remoteEntry,
      );
  }
}

/// Name for the copy that preserves the other side's version in a
/// keep-both conflict: `dir/name (conflict <device> <yyyy-MM-dd HHmm>).ext`.
String conflictCopyPath(String relativePath, String deviceName, DateTime when) {
  final slash = relativePath.lastIndexOf('/');
  final dir = slash >= 0 ? relativePath.substring(0, slash + 1) : '';
  final file = slash >= 0 ? relativePath.substring(slash + 1) : relativePath;
  final dot = file.lastIndexOf('.');
  final hasExt = dot > 0;
  final base = hasExt ? file.substring(0, dot) : file;
  final ext = hasExt ? file.substring(dot) : '';
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${when.year}-${two(when.month)}-${two(when.day)} '
      '${two(when.hour)}${two(when.minute)}';
  final device = deviceName
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  final label = device.isEmpty ? 'conflict' : 'conflict $device';
  return '$dir$base ($label $stamp)$ext';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Mass-deletion guard
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns a human-readable reason when [plan] would delete a suspicious
/// share of the previously known files on one side (e.g. the source folder
/// is suddenly empty because a disk was not mounted), otherwise `null`.
///
/// Refuses when every previously known file of a side would be deleted, or
/// when more than 50 % and more than 20 files would be deleted.
String? massDeletionReason({
  required SyncPlan plan,
  SyncManifest? previousLocal,
  SyncManifest? previousRemote,
}) {
  String? check(int deletes, int known, String side) {
    if (deletes == 0 || known == 0) return null;
    if (deletes >= known) {
      return 'Refusing to delete all $known known files on the $side side';
    }
    if (deletes > 20 && deletes * 2 > known) {
      return 'Refusing to delete $deletes of $known known files on the '
          '$side side';
    }
    return null;
  }

  return check(plan.remoteDeletes.length,
          previousRemote?.entries.length ?? previousLocal?.entries.length ?? 0,
          'remote') ??
      check(plan.localDeletes.length,
          previousLocal?.entries.length ?? previousRemote?.entries.length ?? 0,
          'local');
}
