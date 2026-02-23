import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';

/// A 28 px status bar at the bottom of the desktop content area.
///
/// Shows: connected device count · active sync count · local IP address.
class DesktopStatusBar extends ConsumerWidget {
  const DesktopStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Device count.
    final deviceCount = ref.watch(devicesProvider).valueOrNull?.length ?? 0;

    // Active sync job count (folder + server).
    final syncState = ref.watch(syncServiceProvider);
    final serverSyncState = ref.watch(serverSyncServiceProvider);
    final activeFolderSyncs =
        syncState.jobs.where((j) => j.isActive).length;
    final activeServerSyncs =
        serverSyncState.jobs.where((j) => j.isActive).length;
    final totalActiveSyncs = activeFolderSyncs + activeServerSyncs;

    // Local IP from discovery service.
    final localDevice =
        ref.watch(discoveryServiceProvider).valueOrNull?.localDevice;
    final localIp = localDevice?.ip ?? '';

    final textColor =
        isDark ? AppColors.textTertiary : AppColors.lightTextTertiary;
    final borderColor = isDark
        ? const Color(0xFF1E1E2A)
        : AppColors.lightDivider;
    const textStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w500);

    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSidebar,
        border: Border(top: BorderSide(color: borderColor, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Devices
          Icon(Icons.devices_rounded, size: 12, color: textColor),
          const SizedBox(width: 4),
          Text(
            '$deviceCount',
            style: textStyle.copyWith(color: textColor),
          ),

          const SizedBox(width: 16),

          // Active syncs
          if (totalActiveSyncs > 0) ...[
            Icon(Icons.sync_rounded, size: 12, color: AppColors.neonBlue),
            const SizedBox(width: 4),
            Text(
              '$totalActiveSyncs',
              style: textStyle.copyWith(color: AppColors.neonBlue),
            ),
            const SizedBox(width: 16),
          ],

          const Spacer(),

          // Local IP
          if (localIp.isNotEmpty)
            Text(
              localIp,
              style: textStyle.copyWith(color: textColor),
            ),
        ],
      ),
    );
  }
}
