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
///   - [timestampTolerance]: Tolerance for comparing modification times.
///     FAT32 has only 2-second resolution, so a 2s tolerance avoids
///     false conflicts on removable media.
SyncPlan computeSyncPlan({
  required SyncManifest local,
  required SyncManifest remote,
  SyncManifest? previousLocal,
  SyncManifest? previousRemote,
  ConflictStrategy conflictStrategy = ConflictStrategy.newerWins,
  bool mirrorDeletions = true,
  Duration timestampTolerance = const Duration(seconds: 2),
}) {
  final localMap = local.toMap();
  final remoteMap = remote.toMap();
  final prevLocalMap = previousLocal?.toMap() ?? {};
  final prevRemoteMap = previousRemote?.toMap() ?? {};

  final allPaths = <String>{
    ...localMap.keys,
    ...remoteMap.keys,
    if (mirrorDeletions) ...prevLocalMap.keys,
    if (mirrorDeletions) ...prevRemoteMap.keys,
  };

  final actions = <SyncAction>[];

  for (final path in allPaths) {
    final localEntry = localMap[path];
    final remoteEntry = remoteMap[path];
    final prevLocal = prevLocalMap[path];
    final prevRemote = prevRemoteMap[path];

    // ── Case 1: File exists only locally ──
    if (localEntry != null && remoteEntry == null) {
      if (prevRemote != null && mirrorDeletions) {
        // Was on remote before → remote deleted it → delete locally.
        actions.add(SyncAction(
          type: SyncActionType.deleteLocal,
          relativePath: path,
          localEntry: localEntry,
        ));
      } else {
        // New local file → send to remote.
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
      if (prevLocal != null && mirrorDeletions) {
        // Was on local before → local deleted it → delete on remote.
        actions.add(SyncAction(
          type: SyncActionType.deleteRemote,
          relativePath: path,
          remoteEntry: remoteEntry,
        ));
      } else {
        // New remote file → pull to local.
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
      // Check if files are identical (within tolerance).
      if (_areEntriesEqual(localEntry, remoteEntry, timestampTolerance)) {
        continue; // Already in sync.
      }

      // Determine which side changed since last sync.
      final localChanged = prevLocal == null ||
          !_areEntriesEqual(localEntry, prevLocal, timestampTolerance);
      final remoteChanged = prevRemote == null ||
          !_areEntriesEqual(remoteEntry, prevRemote, timestampTolerance);

      if (localChanged && !remoteChanged) {
        // Only local changed → send to remote.
        actions.add(SyncAction(
          type: SyncActionType.sendToRemote,
          relativePath: path,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
        ));
      } else if (!localChanged && remoteChanged) {
        // Only remote changed → pull from remote.
        actions.add(SyncAction(
          type: SyncActionType.pullFromRemote,
          relativePath: path,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
        ));
      } else if (localChanged && remoteChanged) {
        // Both sides changed → conflict!
        final resolved = _resolveConflict(
          path, localEntry, remoteEntry, conflictStrategy,
        );
        actions.add(resolved);
      }
      // else: neither changed → already in sync (shouldn't reach here).
      continue;
    }

    // ── Case 4: File exists in neither manifest but was in previous ──
    // (Deleted on both sides — no action needed.)
  }

  return SyncPlan(actions: actions);
}

/// Compares two manifest entries within a timestamp tolerance.
bool _areEntriesEqual(
  SyncManifestEntry a,
  SyncManifestEntry b,
  Duration tolerance,
) {
  if (a.size != b.size) return false;
  // If both have hashes, compare hashes (most reliable).
  if (a.hash != null && b.hash != null) return a.hash == b.hash;
  // Otherwise compare timestamps with tolerance.
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
      // For "keep both", we still mark it as a conflict so the caller can
      // rename one copy with a _conflict suffix.
      return SyncAction(
        type: SyncActionType.conflict,
        relativePath: path,
        localEntry: localEntry,
        remoteEntry: remoteEntry,
      );

    case ConflictStrategy.askUser:
      return SyncAction(
        type: SyncActionType.conflict,
        relativePath: path,
        localEntry: localEntry,
        remoteEntry: remoteEntry,
      );
  }
}
