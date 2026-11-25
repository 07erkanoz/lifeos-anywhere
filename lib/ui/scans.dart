import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:anyware/core/open_any_file.dart';
import 'package:anyware/features/scan/document_scan.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/ui/devices_home.dart';
import 'package:anyware/ui/scan_flow.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';

/// The scanned PDFs, newest first; refreshed after a scan, a rename or a delete.
final scansProvider = Provider.autoDispose<List<File>>((ref) {
  ref.watch(_scansVersion);
  return listScans(ref.watch(settingsProvider.select((s) => s.downloadPath)));
});

final _scansVersion = StateProvider<int>((ref) => 0);

/// After the folder changed.
void refreshScans(WidgetRef ref) => ref.read(_scansVersion.notifier).state++;

String _sizeOf(File f) {
  final n = f.existsSync() ? f.lengthSync() : 0;
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _nameOf(File f) {
  final name = f.path.split(RegExp(r'[/\\]')).last;
  return name.toLowerCase().endsWith('.pdf') ? name.substring(0, name.length - 4) : name;
}

/// The first page, small.
class ScanThumb extends StatelessWidget {
  const ScanThumb({super.key, required this.path, this.width = 48});
  final String path;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    return Container(
      width: width,
      height: width * 1.36,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ui.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: PdfDocumentViewBuilder.file(
        path,
        key: ValueKey(path),
        builder: (context, document) => document == null
            ? Icon(Icons.picture_as_pdf_outlined, color: ui.muted)
            : PdfPageView(document: document, pageNumber: 1, maximumDpi: 96),
      ),
    );
  }
}

/// The scans as a list (Dosyalar › Taramalar, and the Taramalar page).
class ScansList extends ConsumerWidget {
  const ScansList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final scans = ref.watch(scansProvider);
    if (scans.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.document_scanner_outlined, size: 48, color: ui.muted),
              const SizedBox(height: 12),
              Text(S.get('scansEmpty', locale), textAlign: TextAlign.center, style: TextStyle(color: ui.muted)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => scanToPdfFlow(context, ref),
                style: FilledButton.styleFrom(backgroundColor: ui.accent, foregroundColor: Colors.white),
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: Text(S.get('scanPdf', locale)),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      itemCount: scans.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final f = scans[i];
        final when = f.statSync().modified;
        return Material(
          color: ui.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => openScan(context, f.path),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  ScanThumb(path: f.path),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_nameOf(f),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('${shortWhen(when, locale: locale)} · ${_sizeOf(f)}',
                            style: TextStyle(fontSize: 12, color: ui.muted)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: S.get('send', locale),
                    icon: Icon(Icons.send_rounded, color: ui.accentText),
                    onPressed: () => sendFilesFlow(context, ref, paths: [f.path]),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> openScan(BuildContext context, String path) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ScanPreviewScreen(path: path)));

/// Taramalar, as a page of its own (from the home screen).
class ScansScreen extends ConsumerWidget {
  const ScansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    return Scaffold(
      backgroundColor: ui.bg,
      appBar: AppBar(title: Text(S.get('scans', locale)), backgroundColor: ui.bg),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => scanToPdfFlow(context, ref),
        backgroundColor: ui.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.document_scanner_outlined, size: 20),
        label: Text(S.get('scanNew', locale)),
      ),
      body: const ScansList(),
    );
  }
}

/// One scan: all its pages; send, rename, delete.
class ScanPreviewScreen extends ConsumerStatefulWidget {
  const ScanPreviewScreen({super.key, required this.path});
  final String path;

  @override
  ConsumerState<ScanPreviewScreen> createState() => _ScanPreviewScreenState();
}

class _ScanPreviewScreenState extends ConsumerState<ScanPreviewScreen> {
  late String _path = widget.path;

  Future<void> _rename(String locale) async {
    final input = TextEditingController(text: _nameOf(File(_path)));
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(S.get('scanRename', locale)),
        content: TextField(controller: input, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(S.get('cancel', locale))),
          FilledButton(onPressed: () => Navigator.pop(d, input.text.trim()), child: Text(S.get('save', locale))),
        ],
      ),
    );
    final clean = (name ?? '').replaceAll(RegExp(r'[\x00-\x1f/\\:*?"<>|]'), '_').trim();
    if (clean.isEmpty) return;
    final target = File('${File(_path).parent.path}${Platform.pathSeparator}$clean.pdf');
    if (target.path == _path) return;
    if (target.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.get('scanNameTaken', locale))));
      }
      return;
    }
    final moved = await File(_path).rename(target.path);
    if (!mounted) return;
    setState(() => _path = moved.path);
    refreshScans(ref);
  }

  Future<void> _delete(String locale) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(S.get('scanDelete', locale)),
        content: Text(S.get('scanDeleteAsk', locale, {'name': _nameOf(File(_path))})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(S.get('cancel', locale))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(S.get('scanDeleteYes', locale))),
        ],
      ),
    );
    if (yes != true) return;
    final f = File(_path);
    if (f.existsSync()) await f.delete();
    if (!mounted) return;
    refreshScans(ref);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    return Scaffold(
      appBar: AppBar(
        title: Text(_nameOf(File(_path)), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: S.get('scanRename', locale),
            icon: const Icon(Icons.drive_file_rename_outline_rounded),
            onPressed: () => _rename(locale),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'open') unawaited(openAnyFile(_path));
              if (v == 'delete') unawaited(_delete(locale));
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'open', child: Text(S.get('openWith', locale))),
              PopupMenuItem(value: 'delete', child: Text(S.get('scanDelete', locale))),
            ],
          ),
        ],
      ),
      body: PdfViewer.file(_path, key: ValueKey(_path)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: () => sendFilesFlow(context, ref, paths: [_path]),
            style: FilledButton.styleFrom(
              backgroundColor: ui.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: Text(S.get('send', locale)),
          ),
        ),
      ),
    );
  }
}
