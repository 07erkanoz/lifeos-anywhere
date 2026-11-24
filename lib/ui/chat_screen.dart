import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anyware/core/open_any_file.dart';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/ui/devices_home.dart';
import 'package:anyware/ui/files_screen.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';

/// Sohbet: the conversation with one paired device. Text, files and photos;
/// each message says how it went (on this network, over the internet, or
/// passed on by the server) and whether it was read.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.deviceId, this.embedded = false});
  final String deviceId;

  /// Inside the desktop's three-column layout (no app bar of its own).
  final bool embedded;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(iletiProvider.notifier).markSeen(widget.deviceId);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _focus.requestFocus();
    await ref.read(iletiProvider.notifier).sendText(widget.deviceId, text);
  }

  Future<void> _attach({bool images = false}) async {
    final picked = await FilePickerHelper.pickFiles(allowMultiple: true);
    final paths =
        picked?.files.map((f) => f.path).whereType<String>().toList() ??
        const [];
    if (paths.isEmpty) return;
    await ref.read(iletiProvider.notifier).sendFiles(widget.deviceId, paths);
  }

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final row = ref
        .watch(pairedRowsProvider)
        .where((r) => r.trusted.id == widget.deviceId)
        .firstOrNull;
    final messages = ref.watch(
      iletiProvider.select((m) => m[widget.deviceId] ?? const <IletiMessage>[]),
    );
    ref.listen(iletiProvider.select((m) => m[widget.deviceId]?.length ?? 0), (
      _,
      _,
    ) {
      ref.read(iletiProvider.notifier).markSeen(widget.deviceId);
    });
    if (row == null) return const SizedBox.shrink();
    final reach = ref.watch(iletiReachProvider(widget.deviceId));
    final t = row.trusted;

    final header = Material(
      color: ui.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: ui.border)),
        ),
        padding: EdgeInsets.fromLTRB(widget.embedded ? 16 : 4, 8, 8, 8),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              if (!widget.embedded) const BackButton(),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DeviceDetail(deviceId: t.id),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        DeviceAvatar(
                          platform: t.platform,
                          reach: reach,
                          size: 40,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${reachText(ref, t.id, reach, locale)}${t.isPinned ? ' · ${S.get('encrypted', locale)}' : ''}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ui.route(reach).fg,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: S.get('actClipboard', locale),
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: () => ref
                    .read(iletiProvider.notifier)
                    .sendClipboard(widget.deviceId),
              ),
            ],
          ),
        ),
      ),
    );

    final list = messages.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                S.get('chatEmpty', locale, {'name': t.name}),
                textAlign: TextAlign.center,
                style: TextStyle(color: ui.muted, height: 1.45),
              ),
            ),
          )
        : ListView.builder(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            itemCount: messages.length,
            itemBuilder: (context, i) {
              final m = messages[messages.length - 1 - i];
              final prev = i + 1 < messages.length
                  ? messages[messages.length - 2 - i]
                  : null;
              final newDay =
                  prev == null ||
                  prev.time.year != m.time.year ||
                  prev.time.month != m.time.month ||
                  prev.time.day != m.time.day;
              return Column(
                children: [
                  if (newDay) _DayChip(time: m.time, locale: locale),
                  _Bubble(message: m, locale: locale),
                ],
              );
            },
          );

    final composer = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                decoration: BoxDecoration(
                  color: ui.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: ui.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: S.get('attach', locale),
                      icon: Icon(Icons.attach_file_rounded, color: ui.muted),
                      onPressed: _attach,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: S.get('writeTo', locale, {'name': t.name}),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: S.get('photo', locale),
                      icon: Icon(Icons.image_outlined, color: ui.muted),
                      onPressed: () => _attach(images: true),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton.filled(
                tooltip: S.get('send', locale),
                style: IconButton.styleFrom(
                  backgroundColor: ui.accent,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.send_rounded, size: 20),
                onPressed: _send,
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: ui.bg,
      body: Column(
        children: [
          header,
          Expanded(child: list),
          composer,
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.time, required this.locale});
  final DateTime time;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final now = DateTime.now();
    final diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(time.year, time.month, time.day)).inDays;
    final label = diff == 0
        ? S.get('today', locale)
        : diff == 1
        ? S.get('yesterday', locale)
        : '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: ui.muted,
        ),
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.message, required this.locale});
  final IletiMessage message;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final m = message;
    final out = m.outgoing;
    final bg = out
        ? const Color(0xFF5B21B6)
        : (ui.dark ? const Color(0xFF1F1B2B) : Colors.white);
    final fg = out ? Colors.white : ui.text;
    final meta = out ? const Color(0xFFDDD6FE) : ui.muted;
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${two(m.time.hour)}.${two(m.time.minute)}';

    final status = <Widget>[
      if (m.via == IletiVia.internet || m.via == IletiVia.relay)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(Icons.cloud_outlined, size: 13, color: meta),
        ),
      Flexible(
        child: Text(
          [
            when,
            if (m.via == IletiVia.relay) S.get('viaRelay', locale),
            if (m.via == IletiVia.clipboard) S.get('viaClipboard', locale),
          if (m.error == 'büyük') S.get('waitsForLan', locale),
            if (out)
              S.get(switch (m.status) {
                IletiStatus.pending => 'stPending',
                IletiStatus.sending => 'stSending',
            IletiStatus.onServer => 'stOnServer',
                IletiStatus.read => 'stRead',
                IletiStatus.failed => 'stFailed',
                _ => 'stSent',
              }, locale),
          ].join(' · '),
          textAlign: TextAlign.end,
          style: TextStyle(
            fontSize: 11,
            color: m.status == IletiStatus.failed ? ui.danger : meta,
          ),
        ),
      ),
    ];

    Widget content;
    if (m.isFile) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              FileBadge(m.fileName!, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.fileName!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                    if (m.fileSize != null)
                      Text(
                        formatBytes(m.fileSize!),
                        style: TextStyle(fontSize: 12, color: meta),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (m.progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: m.progress,
                minHeight: 4,
                color: out ? Colors.white : const Color(0xFFA78BFA),
                backgroundColor: out ? Colors.white24 : ui.border,
              ),
            ),
          ],
          if (!out && m.filePath != null && File(m.filePath!).existsSync()) ...[
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => openAnyFile(m.filePath!),
              style: FilledButton.styleFrom(
                backgroundColor: ui.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(36),
              ),
              child: Text(S.get('open', locale)),
            ),
          ],
          if (m.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              m.text,
              style: TextStyle(fontSize: 14, height: 1.4, color: fg),
            ),
          ],
        ],
      );
    } else {
      content = SelectableText(
        m.text,
        style: TextStyle(fontSize: 14.5, height: 1.4, color: fg),
      );
    }

    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (m.isFile ? 0.8 : 0.78),
        ),
        child: GestureDetector(
          onLongPress: m.status == IletiStatus.failed
              ? () => ref.read(iletiProvider.notifier).retry(m)
              : null,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            width: m.isFile ? 300 : null,
            decoration: BoxDecoration(
              color: bg,
              border: out ? null : Border.all(color: ui.border),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(out ? 16 : 4),
                bottomRight: Radius.circular(out ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(alignment: Alignment.centerLeft, child: content),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: status),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
