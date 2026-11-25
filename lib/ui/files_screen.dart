import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/open_any_file.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/transfer/data/transfer_history.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';
import 'package:anyware/features/scan/document_scan.dart';
import 'package:anyware/ui/scans.dart';

/// 0 all, 1 photos, 2 documents, 3 video, 4 clipboard.
final filesFilterProvider = StateProvider<int>((ref) => 0);

enum _Kind { photo, doc, video, other }

_Kind _kindOf(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const photos = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'bmp',
    'raw',
    'dng',
  };
  const videos = {'mp4', 'mov', 'mkv', 'webm', 'avi', '3gp', 'm4v'};
  const docs = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'odt',
    'ods',
    'odp',
    'txt',
    'md',
    'rtf',
    'csv',
    'udf',
  };
  if (photos.contains(ext)) return _Kind.photo;
  if (videos.contains(ext)) return _Kind.video;
  if (docs.contains(ext)) return _Kind.doc;
  return _Kind.other;
}

/// The coloured square with the file's extension.
class FileBadge extends StatelessWidget {
  const FileBadge(this.name, {super.key, this.size = 42});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Ui.of(context).dark;
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '•';
    final (bg, fg) = switch (_kindOf(name)) {
      _Kind.photo => (
        dark ? const Color(0xFF1B2537) : const Color(0xFFDBEAFE),
        dark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
      ),
      _Kind.video => (
        dark ? const Color(0xFF2A2140) : const Color(0xFFEDE9FE),
        dark ? const Color(0xFFC4B5FD) : const Color(0xFF6D28D9),
      ),
      _Kind.doc => (
        dark ? const Color(0xFF3B1A1A) : const Color(0xFFFEE2E2),
        dark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
      ),
      _Kind.other => (
        dark ? const Color(0xFF221F2B) : const Color(0xFFEEECF3),
        dark ? const Color(0xFFA59FB8) : const Color(0xFF5F5A6E),
      ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        ext.length > 4 ? ext.substring(0, 4) : ext,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// Dosyalar: what is moving now, what came and went, and the clipboard.
class FilesScreen extends ConsumerWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final filter = ref.watch(filesFilterProvider);
    final chips = [
      'filterAll',
      'filterPhotos',
      'filterDocs',
      'filterVideo',
      'filterClipboard',
      // index 5: the scanned PDFs (phones)
      if (DocumentScan.available) 'filterScans',
    ];

    return Scaffold(
      backgroundColor: ui.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: S.get('files', locale),
              actions: [
                PopupMenuButton<int>(
                  icon: const Icon(Icons.more_vert_rounded),
                  enabled: filter != 5,
                  onSelected: (_) {
                    if (filter == 4) {
                      ref.read(clipboardHistoryProvider.notifier).clear();
                    } else {
                      ref.read(transferHistoryProvider.notifier).clear();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 0,
                      child: Text(S.get('clearHistory', locale)),
                    ),
                  ],
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (var i = 0; i < chips.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(S.get(chips[i], locale)),
                        selected: filter == i,
                        showCheckmark: false,
                        onSelected: (_) =>
                            ref.read(filesFilterProvider.notifier).state = i,
                        selectedColor: ui.accentSoft,
                        backgroundColor: Colors.transparent,
                        side: BorderSide(
                          color: filter == i ? ui.accentSoft : ui.border,
                        ),
                        shape: const StadiumBorder(),
                        labelStyle: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: filter == i ? ui.text : ui.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filter == 4
                  ? const _ClipboardList()
                  : filter == 5 && DocumentScan.available
                  ? const ScansList()
                  : _TransferList(filter: filter),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferList extends ConsumerWidget {
  const _TransferList({required this.filter});
  final int filter;

  bool _keep(String name) => switch (filter) {
    1 => _kindOf(name) == _Kind.photo,
    2 => _kindOf(name) == _Kind.doc,
    3 => _kindOf(name) == _Kind.video,
    _ => true,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final active = ref
        .watch(activeTransfersProvider)
        .where((t) => t.isActive && _keep(t.fileName))
        .toList();
    final history = [
      ...ref.watch(transferHistoryProvider).where((r) => _keep(r.fileName)),
    ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final groups = <String, List<TransferRecord>>{};
    for (final r in history) {
      final day = DateTime(
        r.timestamp.year,
        r.timestamp.month,
        r.timestamp.day,
      );
      final diff = today.difference(day).inDays;
      final key = diff == 0
          ? 'today'
          : diff == 1
          ? 'yesterday'
          : 'earlier';
      groups.putIfAbsent(key, () => []).add(r);
    }

    if (active.isEmpty && history.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            S.get('noFiles', locale),
            style: TextStyle(color: ui.muted),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (active.isNotEmpty)
          Panel(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            padding: const EdgeInsets.all(14),
            children: [
              Text(
                S.get('active', locale, {'n': '${active.length}'}),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final t in active) _ActiveRow(transfer: t, locale: locale),
            ],
          ),
        for (final key in ['today', 'yesterday', 'earlier'])
          if (groups[key] != null) ...[
            SectionHeader(S.get(key, locale)),
            for (final r in groups[key]!) _RecordRow(record: r, locale: locale),
          ],
      ],
    );
  }
}

class _ActiveRow extends StatelessWidget {
  const _ActiveRow({required this.transfer, required this.locale});
  final Transfer transfer;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final t = transfer;
    final other = t.isSending
        ? t.receiverDevice?.name ?? ''
        : t.senderDevice.name;
    final speed = t.speed == null
        ? ''
        : ' · ${formatBytes(t.speed!.round())}/s';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                t.isSending ? Icons.north_rounded : Icons.south_rounded,
                size: 18,
                color: t.isSending ? ui.accentText : ui.route(Reach.lan).fg,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '%${t.progressPercent}',
                style: TextStyle(fontSize: 12, color: ui.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: t.progress.clamp(0, 1),
              minHeight: 4,
              backgroundColor: ui.border,
              color: const Color(0xFFA78BFA),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${S.get(t.isSending ? 'toDevice' : 'fromDevice', locale, {'name': other})}$speed',
            style: TextStyle(fontSize: 12, color: ui.muted),
          ),
        ],
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record, required this.locale});
  final TransferRecord record;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final r = record;
    final who = S.get(r.isSending ? 'toDevice' : 'fromDevice', locale, {
      'name': r.deviceName,
    });
    final meta = [
      who,
      if (r.fileSize > 0) formatBytes(r.fileSize),
      shortWhen(r.timestamp, locale: locale),
    ].join(' · ');
    final path = r.filePath;
    final exists = path != null && File(path).existsSync();
    return InkWell(
      onTap: exists ? () => _open(context, path) : null,
      onLongPress: exists ? () => showInFolder(path) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            FileBadge(r.fileName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(meta, style: TextStyle(fontSize: 12, color: ui.muted)),
                ],
              ),
            ),
            Icon(
              r.isSending ? Icons.north_east_rounded : Icons.south_west_rounded,
              size: 16,
              color: r.succeeded ? ui.muted : ui.danger,
            ),
            if (!r.succeeded)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  S.get('failed', locale),
                  style: TextStyle(fontSize: 11, color: ui.danger),
                ),
              ),
            if (exists)
              PopupMenuButton<int>(
                icon: Icon(Icons.more_vert_rounded, size: 18, color: ui.muted),
                onSelected: (v) =>
                    v == 0 ? _open(context, path) : showInFolder(path),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 0, child: Text(S.get('open', locale))),
                  PopupMenuItem(
                    value: 1,
                    child: Text(S.get('showInFolder', locale)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String path) async {
    if (!await openAnyFile(path) && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.get('noAppToOpen', locale))));
    }
  }
}

class _ClipboardList extends ConsumerWidget {
  const _ClipboardList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final entries = [...ref.watch(clipboardHistoryProvider)]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (entries.isEmpty) {
      return Center(
        child: Text(
          S.get('noClipboard', locale),
          style: TextStyle(color: ui.muted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final e = entries[i];
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: ui.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ui.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.text.isEmpty ? (e.imagePath ?? '') : e.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${e.senderName} · ${shortWhen(e.timestamp, locale: locale)}',
                      style: TextStyle(fontSize: 12, color: ui.muted),
                    ),
                  ],
                ),
              ),
              if (e.text.isNotEmpty)
                IconButton(
                  tooltip: S.get('copy', locale),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: e.text));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(S.get('copied', locale))),
                      );
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
