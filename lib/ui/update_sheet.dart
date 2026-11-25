import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/update/presentation/update_providers.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';

/// "A new version is ready": what is new, then download and install in place.
Future<void> showUpdateSheet(BuildContext context) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (_) => const Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: EdgeInsets.all(24),
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 480), child: UpdatePanel()),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => const UpdatePanel(),
  );
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0);

class UpdatePanel extends ConsumerWidget {
  const UpdatePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final st = ref.watch(updateProvider);
    final notifier = ref.read(updateProvider.notifier);
    final release = st.release;
    final busy = st.phase == UpdatePhase.downloading || st.phase == UpdatePhase.installing;
    final notes = release == null
        ? const <String>[]
        : release
            .notesFor(locale)
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .map((l) => l.startsWith('- ') || l.startsWith('* ') ? l.substring(2) : l)
            .toList();

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // header: the version, on the app's violet
          Container(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const AppLogo(size: 48),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(S.get('updateTitle', locale),
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        release == null
                            ? ''
                            : S.get('updateFromTo', locale, {
                                'from': AppConstants.appVersion,
                                'to': release.version,
                                'mb': _mb(release.size),
                              }),
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (notes.isNotEmpty)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(S.get('updateWhatsNew', locale),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ui.accentText)),
                    const SizedBox(height: 10),
                    for (final line in notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 10),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: ui.accent, shape: BoxShape.circle),
                              ),
                            ),
                            Expanded(child: Text(line, style: const TextStyle(fontSize: 13.5, height: 1.4))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (st.phase == UpdatePhase.downloading) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: st.progress,
                      minHeight: 10,
                      backgroundColor: ui.accentSoft,
                      color: ui.accent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    S.get('updateDownloading', locale, {
                      'pct': '${(st.progress * 100).round()}',
                      'got': _mb(st.received),
                      'mb': _mb(st.total),
                    }),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: ui.muted),
                  ),
                  const SizedBox(height: 12),
                ],
                if (st.phase == UpdatePhase.installing || st.phase == UpdatePhase.ready)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      S.get(Platform.isWindows ? 'updateInstallingWin' : 'updateInstallHint', locale),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: ui.muted, height: 1.4),
                    ),
                  ),
                if (st.phase == UpdatePhase.failed && st.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(S.get('updateFailed', locale, {'why': st.error!}),
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: ui.danger)),
                  ),
                FilledButton.icon(
                  onPressed: busy || release == null
                      ? null
                      : st.fromPlay
                          ? () => launchUrl(
                                Uri.parse('https://play.google.com/store/apps/details?id=com.lifeos.anyware'),
                                mode: LaunchMode.externalApplication,
                              )
                          : st.phase == UpdatePhase.ready
                              ? notifier.install
                              : notifier.update,
                  style: FilledButton.styleFrom(
                    backgroundColor: ui.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: Icon(st.phase == UpdatePhase.ready ? Icons.install_mobile_rounded : Icons.system_update_alt_rounded,
                      size: 20),
                  label: Text(S.get(
                    st.fromPlay
                        ? 'updateOnPlay'
                        : st.phase == UpdatePhase.ready
                            ? 'updateInstall'
                            : st.phase == UpdatePhase.failed
                                ? 'updateRetry'
                                : 'updateNow',
                    locale,
                  )),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (st.phase == UpdatePhase.downloading)
                      Expanded(
                        child: TextButton(onPressed: notifier.cancel, child: Text(S.get('cancel', locale))),
                      )
                    else ...[
                      Expanded(
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  await notifier.skip();
                                  if (context.mounted) Navigator.of(context).pop();
                                },
                          child: Text(S.get('updateSkip', locale), style: TextStyle(color: ui.muted)),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(S.get('updateLater', locale)),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings › "Check for updates": the state in its subtitle; a newer
/// release opens the sheet.
class UpdateTile extends ConsumerWidget {
  const UpdateTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final st = ref.watch(updateProvider);
    final subtitle = switch (st.phase) {
      UpdatePhase.checking => S.get('updateChecking', locale),
      UpdatePhase.upToDate => S.get('updateUpToDate', locale, {'v': AppConstants.appVersion}),
      UpdatePhase.available ||
      UpdatePhase.downloading ||
      UpdatePhase.ready ||
      UpdatePhase.installing =>
        S.get('updateAvailable', locale, {'v': st.release?.version ?? ''}),
      UpdatePhase.failed => S.get('updateFailed', locale, {'why': st.error ?? ''}),
      UpdatePhase.idle => 'AnyWhere ${AppConstants.appVersion}',
    };
    final hasNew = st.release != null && st.phase != UpdatePhase.upToDate && st.phase != UpdatePhase.failed;
    return ListTile(
      leading: Icon(Icons.system_update_rounded, color: ui.accentText),
      title: Text(S.get('updateCheck', locale), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: hasNew ? ui.accentText : ui.muted)),
      trailing: st.phase == UpdatePhase.checking
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : hasNew
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: ui.accent, borderRadius: BorderRadius.circular(20)),
                  child: Text(st.release!.version,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                )
              : Icon(Icons.chevron_right_rounded, color: ui.muted),
      onTap: () async {
        if (hasNew) {
          await showUpdateSheet(context);
          return;
        }
        final release = await ref.read(updateProvider.notifier).check();
        if (release != null && context.mounted) await showUpdateSheet(context);
      },
    );
  }
}
