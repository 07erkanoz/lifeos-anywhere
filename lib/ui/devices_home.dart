import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/esitleme/data/esitleme_service.dart';
import 'package:anyware/features/esitleme/presentation/providers.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/presentation/manual_ip_dialog.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/pairing/presentation/qr_options_dialog.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/transfer/data/transfer_history.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/ui/chat_screen.dart';
import 'package:anyware/ui/remote_pair_screen.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';
import 'package:anyware/ui/scan_flow.dart';
import 'package:anyware/features/scan/document_scan.dart';

/// Which paired device the wide (desktop) layout shows on the right.
final selectedDeviceIdProvider = StateProvider<String?>((ref) => null);

/// A paired device as the list shows it: how it is reached now and the
/// discovered [Device] to send to (null when it is not on this network).
class PairedRow {
  const PairedRow(this.trusted, this.live, {this.internet = false});
  final TrustedDevice trusted;
  final Device? live;

  /// Not here, but its mailbox is known: messages go over the internet.
  final bool internet;
  Reach get reach => live != null
      ? Reach.lan
      : internet
          ? Reach.internet
          : Reach.off;
}

final pairedRowsProvider = Provider<List<PairedRow>>((ref) {
  final store = ref.watch(trustStoreProvider);
  final live = {
    for (final d in ref.watch(devicesProvider).valueOrNull ?? const <Device>[]) d.id: d,
  };
  final rows = [
    for (final t in store.devices)
      PairedRow(t, live[t.id], internet: ref.watch(iletiReachProvider(t.id)) == Reach.internet),
  ];
  rows.sort((a, b) {
    if (a.reach != b.reach) return a.reach.index.compareTo(b.reach.index);
    return a.trusted.name.toLowerCase().compareTo(b.trusted.name.toLowerCase());
  });
  return rows;
});

/// How a paired device is reached, in words: on this network, online over
/// the internet, offline (with when it was last seen, if known).
String reachText(WidgetRef ref, String device, Reach reach, String locale) {
  if (reach != Reach.off) return _reachLabel(reach, locale);
  final seen = ref.watch(iletiPresenceProvider)[device];
  if (seen == null) return _reachLabel(reach, locale);
  final last = seen.$2;
  return last == null
      ? S.get('offlineWaits', locale)
      : S.get('offlineSeen', locale, {'when': shortWhen(last, locale: locale)});
}

String _reachLabel(Reach reach, String locale) => S.get(
      switch (reach) {
        Reach.lan => 'reachLan',
        Reach.internet => 'reachInternet',
        Reach.off => 'reachOff',
      },
      locale,
    );

/// Cihazlar: the paired devices first, then the ones new on this network.
/// Wide windows show the chosen device's details beside the list.
class DevicesHome extends ConsumerWidget {
  const DevicesHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (!wide) return const _DeviceList(wide: false);
    final selected = ref.watch(selectedDeviceIdProvider);
    final rows = ref.watch(pairedRowsProvider);
    final id = selected ?? (rows.isNotEmpty ? rows.first.trusted.id : null);
    final ui = Ui.of(context);
    // the mock's three columns: devices, the conversation, the device
    final three = MediaQuery.sizeOf(context).width >= 1250;
    return Row(
      children: [
        SizedBox(width: 340, child: const _DeviceList(wide: true)),
        VerticalDivider(width: 1, color: ui.border),
        Expanded(
          child: id == null
              ? const SizedBox.shrink()
              : ChatScreen(deviceId: id, embedded: true, key: ValueKey('c$id')),
        ),
        if (three && id != null) ...[
          VerticalDivider(width: 1, color: ui.border),
          SizedBox(
            width: 320,
            child: DeviceDetail(deviceId: id, embedded: true, key: ValueKey('d$id')),
          ),
        ],
      ],
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(settingsProvider).locale;
    final ui = Ui.of(context);
    final rows = ref.watch(pairedRowsProvider);
    final store = ref.watch(trustStoreProvider);
    final discovered = ref.watch(devicesProvider).valueOrNull ?? const <Device>[];
    final fresh = discovered.where((d) => store.byId(d.id) == null).toList();
    final history = ref.watch(transferHistoryProvider);
    final chats = ref.watch(iletiProvider);
    final selected = ref.watch(selectedDeviceIdProvider) ??
        (rows.isNotEmpty ? rows.first.trusted.id : null);

    return Scaffold(
      backgroundColor: ui.bg,
      floatingActionButton: wide
          ? null
          : FloatingActionButton.extended(
              onPressed: () => sendFilesFlow(context, ref),
              backgroundColor: ui.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.send_rounded, size: 20),
              label: Text(S.get('send', locale)),
            ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            PageHeader(
              title: Platform.isAndroid || Platform.isIOS ? 'AnyWhere' : S.get('navDevices', locale),
              // desktops have the logo on the rail; phones here
              leading: Platform.isAndroid || Platform.isIOS ? const AppLogo(size: 32) : null,
              actions: [
                if (wide)
                  SquareIconButton(
                    icon: Icons.send_rounded,
                    tooltip: S.get('send', locale),
                    onPressed: () => sendFilesFlow(context, ref),
                  ),
                SquareIconButton(
                  icon: Icons.add_rounded,
                  tooltip: S.get('addDevice', locale),
                  filled: true,
                  onPressed: () => _addDevice(context, locale),
                ),
              ],
            ),
            const _MeCard(),
            if (DocumentScan.available) _ScanCard(locale: locale),
            SectionHeader(S.get('pairedDevices', locale)),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  S.get('noPaired', locale),
                  style: TextStyle(color: ui.muted, fontSize: 13, height: 1.45),
                ),
              ),
            for (final row in rows)
              _PairedTile(
                row: row,
                locale: locale,
                lastText: _summary(row, history, chats, locale).$1,
                lastTime: _summary(row, history, chats, locale).$2,
                unread: chats[row.trusted.id]?.where((m) => m.status == IletiStatus.unread).length ?? 0,
                reachLabel: reachText(ref, row.trusted.id, row.reach, locale),
                selected: wide && row.trusted.id == selected,
                onTap: () {
                  if (wide) {
                    ref.read(selectedDeviceIdProvider.notifier).state = row.trusted.id;
                  } else {
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ChatScreen(deviceId: row.trusted.id),
                    ));
                  }
                },
              ),
            SectionHeader(S.get('newOnNetwork', locale)),
            if (fresh.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(
                  S.get('nothingOnNetwork', locale),
                  style: TextStyle(color: ui.muted, fontSize: 13),
                ),
              ),
            for (final d in fresh) _NewDeviceTile(device: d, locale: locale),
          ],
        ),
      ),
    );
  }

  /// The newest of the conversation and the files carried: what the row says.
  static (String, DateTime?) _summary(
    PairedRow row,
    List<TransferRecord> history,
    Map<String, List<IletiMessage>> chats,
    String locale,
  ) {
    final msg = chats[row.trusted.id]?.lastOrNull;
    final rec = _lastWith(history, row.trusted.name);
    if (msg != null && (rec == null || !rec.timestamp.isAfter(msg.time))) {
      final what = msg.isFile ? (msg.text.isNotEmpty ? msg.text : msg.fileName!) : msg.text;
      return (msg.outgoing ? S.get('lastSent', locale, {'file': what}) : what, msg.time);
    }
    if (rec != null) {
      return (S.get(rec.isSending ? 'lastSent' : 'lastGot', locale, {'file': rec.fileName}), rec.timestamp);
    }
    return (S.get('lastNone', locale), null);
  }

  static TransferRecord? _lastWith(List<TransferRecord> history, String name) {
    TransferRecord? best;
    for (final r in history) {
      if (r.deviceName != name) continue;
      if (best == null || r.timestamp.isAfter(best.timestamp)) best = r;
    }
    return best;
  }

  Future<void> _addDevice(BuildContext context, String locale) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_2_rounded),
              title: Text(S.get('addByQr', locale)),
              subtitle: Text(S.get('addByQrHint', locale)),
              onTap: () => Navigator.of(sheet).pop(0),
            ),
            ListTile(
              leading: const Icon(Icons.lan_rounded),
              title: Text(S.get('addByIp', locale)),
              subtitle: Text(S.get('addByIpHint', locale)),
              onTap: () => Navigator.of(sheet).pop(1),
            ),
            ListTile(
              leading: const Icon(Icons.public_rounded),
              title: Text(S.get('addRemote', locale)),
              subtitle: Text(S.get('addRemoteHint', locale)),
              onTap: () => Navigator.of(sheet).pop(2),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 2) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemotePairScreen()));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => choice == 0
          ? QrOptionsDialog(locale: locale)
          : ManualIpDialog(locale: locale),
    );
  }
}

class _MeCard extends ConsumerWidget {
  const _MeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final me = ref.watch(localDeviceProvider).valueOrNull;
    final serverUp = ref.watch(fileServerProvider).valueOrNull?.isRunning ?? false;
    final online = me != null && me.ip.isNotEmpty && me.ip != '0.0.0.0' && serverUp;
    final name = me?.name ?? '…';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: ui.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ui.border),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? const Color(0xFF4ADE80) : ui.muted,
              boxShadow: online
                  ? const [BoxShadow(color: Color(0x2E4ADE80), spreadRadius: 4)]
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.get(online ? 'meReachable' : 'meOffline', locale, {'name': name}),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                if (me != null)
                  Text(
                    '${me.ip}:${me.port}',
                    style: TextStyle(fontSize: 12, color: ui.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PairedTile extends StatelessWidget {
  const _PairedTile({
    required this.row,
    required this.locale,
    required this.lastText,
    required this.lastTime,
    required this.unread,
    required this.selected,
    required this.onTap,
    required this.reachLabel,
  });
  final String reachLabel;
  final PairedRow row;
  final String locale;
  final String lastText;
  final DateTime? lastTime;
  final int unread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final t = row.trusted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: selected ? ui.selectedRow : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                DeviceAvatar(platform: t.platform, reach: row.reach),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (lastTime != null)
                            Text(
                              shortWhen(lastTime!, locale: locale),
                              style: TextStyle(fontSize: 12, color: ui.muted),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              lastText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: ui.muted),
                            ),
                          ),
                          if (unread > 0)
                            Container(
                              constraints: const BoxConstraints(minWidth: 20),
                              height: 20,
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: ui.accent, borderRadius: BorderRadius.circular(10)),
                              child: Text('$unread',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      RouteBadge(reach: row.reach, label: reachLabel),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NewDeviceTile extends ConsumerStatefulWidget {
  const _NewDeviceTile({required this.device, required this.locale});
  final Device device;
  final String locale;

  @override
  ConsumerState<_NewDeviceTile> createState() => _NewDeviceTileState();
}

class _NewDeviceTileState extends ConsumerState<_NewDeviceTile> {
  bool _busy = false;

  Future<void> _pair() async {
    final me = await ref.read(localDeviceProvider.future);
    setState(() => _busy = true);
    try {
      await ref.read(pairingClientProvider).requestPairing(
            ip: widget.device.ip,
            port: widget.device.port,
            localId: me.id,
            localName: me.name,
            localPlatform: me.platform,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final d = widget.device;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          DeviceAvatar(platform: d.platform, dashed: true),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text('${d.platform} · ${d.ip}', style: TextStyle(fontSize: 12, color: ui.muted)),
              ],
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _pair,
            style: FilledButton.styleFrom(
              backgroundColor: ui.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(64, 44),
            ),
            child: Text(S.get(_busy ? 'pairing' : 'pair', widget.locale)),
          ),
        ],
      ),
    );
  }
}

/// Belge tara: camera to PDF, kept on the phone and sent to whoever.
class _ScanCard extends ConsumerWidget {
  const _ScanCard({required this.locale});
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: ui.accentSoft,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => scanToPdfFlow(context, ref),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: ui.accent, borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.document_scanner_outlined, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(S.get('scanPdf', locale), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(S.get('scanPdfHint', locale), style: TextStyle(fontSize: 12, color: ui.muted, height: 1.3)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: ui.accentText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── sending ───────────────────────────────────────────────────────────────

/// Somewhere files can go: a device on this network (a fast transfer), or a
/// paired device elsewhere, through İleti (over the internet while it is
/// online, otherwise the message waits for it).
class SendTarget {
  const SendTarget.lan(Device this.live) : remote = null;
  const SendTarget.remote(TrustedDevice this.remote) : live = null;
  final Device? live;
  final TrustedDevice? remote;
  String get id => live?.id ?? remote!.id;
  String get name => live?.name ?? remote!.name;
  String get platform => live?.platform ?? remote!.platform;
}

/// Gönder: pick files (or take the shared ones), then the devices — on this
/// network or paired ones far away (several at once). [texts]: shared
/// texts or links, which go as messages to paired devices.
/// [only] / [onlyRemote]: straight to that device, no sheet.
Future<void> sendFilesFlow(
  BuildContext context,
  WidgetRef ref, {
  List<String>? paths,
  List<String> texts = const [],
  Device? only,
  String? onlyRemote,
}) async {
  final locale = ref.read(settingsProvider).locale;
  var files = paths;
  if (files == null && texts.isEmpty) {
    final picked = await FilePickerHelper.pickFiles(allowMultiple: true);
    files = picked?.files.map((f) => f.path).whereType<String>().toList();
  }
  files ??= const [];
  if ((files.isEmpty && texts.isEmpty) || !context.mounted) return;
  final store = ref.read(trustStoreProvider);
  List<SendTarget> targets;
  if (only != null) {
    targets = [SendTarget.lan(only)];
  } else if (onlyRemote != null && store.byId(onlyRemote) != null) {
    targets = [SendTarget.remote(store.byId(onlyRemote)!)];
  } else {
    final picked = await showModalBottomSheet<List<SendTarget>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _TargetSheet(count: files!.length + texts.length, pairedOnly: files.isEmpty),
    );
    if (picked == null || picked.isEmpty) return;
    targets = picked;
  }
  final ileti = ref.read(iletiProvider.notifier);
  var queued = 0;
  var chat = 0;
  for (final t in targets) {
    final paired = store.byId(t.id) != null;
    final live = t.live;
    if (files.isNotEmpty) {
      if (live != null) {
        final queue = await ref.read(transferQueueProvider.future);
        queue.enqueueAll(live, files);
        queued += files.length;
      } else {
        // not on this network: as files in the conversation (İleti)
        await ileti.sendFiles(t.id, files);
        chat += files.length;
      }
    }
    if (paired) {
      for (final text in texts) {
        await ileti.sendText(t.id, text);
        chat++;
      }
    }
  }
  if (context.mounted) {
    final parts = [
      if (queued > 0) S.get('sendQueued', locale, {'n': '$queued'}),
      if (chat > 0) S.get('sentToChat', locale, {'n': '$chat'}),
    ];
    if (parts.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    }
  }
}

class _TargetSheet extends ConsumerStatefulWidget {
  const _TargetSheet({required this.count, this.pairedOnly = false});
  final int count;

  /// Only paired devices (texts go as messages, which needs pairing).
  final bool pairedOnly;

  @override
  ConsumerState<_TargetSheet> createState() => _TargetSheetState();
}

class _TargetSheetState extends ConsumerState<_TargetSheet> {
  final Set<String> _chosen = {};

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final store = ref.watch(trustStoreProvider);
    final live = ref.watch(devicesProvider).valueOrNull ?? const <Device>[];
    final presence = ref.watch(iletiPresenceProvider);
    ref.watch(iletiProvider);
    final ileti = ref.read(iletiProvider.notifier);
    final liveIds = {for (final d in live) d.id};
    // paired on this network, paired elsewhere (online first), then the others on this network
    final remote = [
      for (final t in store.devices)
        if (!liveIds.contains(t.id) && ileti.canMail(t.id)) t,
    ]..sort((a, b) {
        final oa = presence[a.id]?.$1 ?? false;
        final ob = presence[b.id]?.$1 ?? false;
        if (oa != ob) return oa ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final targets = <(SendTarget, Reach, String)>[
      for (final d in live.where((d) => store.byId(d.id) != null))
        (SendTarget.lan(d), Reach.lan, _reachLabel(Reach.lan, locale)),
      for (final t in remote)
        (presence[t.id]?.$1 ?? false)
            ? (SendTarget.remote(t), Reach.internet, _reachLabel(Reach.internet, locale))
            : (SendTarget.remote(t), Reach.off, S.get('targetWaits', locale)),
      if (!widget.pairedOnly)
        for (final d in live.where((d) => store.byId(d.id) == null))
          (SendTarget.lan(d), Reach.lan, _reachLabel(Reach.lan, locale)),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(S.get('sendTo', locale), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (targets.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(S.get('noTargets', locale), style: TextStyle(color: ui.muted)),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (t, reach, label) in targets)
                      _TargetChip(
                        name: t.name,
                        platform: t.platform,
                        reach: reach,
                        chosen: _chosen.contains(t.id),
                        label: label,
                        onTap: () => setState(() {
                          if (!_chosen.remove(t.id)) _chosen.add(t.id);
                        }),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _chosen.isEmpty
                  ? null
                  : () => Navigator.of(context).pop([
                        for (final (t, _, _) in targets)
                          if (_chosen.contains(t.id)) t,
                      ]),
              style: FilledButton.styleFrom(
                backgroundColor: ui.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: Text(_chosen.length <= 1
                  ? S.get('send', locale)
                  : S.get('sendToN', locale, {'n': '${_chosen.length}'})),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetChip extends StatelessWidget {
  const _TargetChip({
    required this.name,
    required this.platform,
    required this.reach,
    required this.chosen,
    required this.label,
    required this.onTap,
  });
  final String name;
  final String platform;
  final Reach reach;
  final bool chosen;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    return Semantics(
      selected: chosen,
      button: true,
      child: Material(
        color: chosen ? ui.accentSoft : ui.surfaceSunk,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: chosen ? const Color(0xFFA78BFA) : Colors.transparent, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            width: 84,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
              child: Column(
                children: [
                  DeviceAvatar(platform: platform, reach: reach, size: 44),
                  const SizedBox(height: 6),
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  Text(label, maxLines: 2, textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, color: ui.route(reach).fg)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── one device ────────────────────────────────────────────────────────────

/// A paired device: how it is reached, its security code, what can be done
/// with it, the folders synced with it, and unpairing.
class DeviceDetail extends ConsumerWidget {
  const DeviceDetail({super.key, required this.deviceId, this.embedded = false});
  final String deviceId;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final rows = ref.watch(pairedRowsProvider);
    final row = rows.where((r) => r.trusted.id == deviceId).firstOrNull;
    if (row == null) {
      if (!embedded) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
        });
      }
      return const SizedBox.shrink();
    }
    final t = row.trusted;
    final mine = TlsIdentity.current?.fingerprint;
    final code = t.isPinned && mine != null ? TlsIdentity.pairingCode(mine, t.fingerprint!) : null;
    final folders = (ref.watch(syncedFoldersProvider).valueOrNull ?? const <SyncedFolder>[])
        .where((f) => f.device == t.id)
        .toList();
    final date = '${t.pairedAt.day.toString().padLeft(2, '0')}.${t.pairedAt.month.toString().padLeft(2, '0')}.${t.pairedAt.year}';

    final body = ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SizedBox(height: 8),
        Center(child: DeviceAvatar(platform: t.platform, reach: row.reach, size: 72)),
        const SizedBox(height: 10),
        Center(
          child: Text(t.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            S.get('pairedSince', locale, {'platform': t.platform, 'date': date}),
            style: TextStyle(fontSize: 13, color: ui.muted),
          ),
        ),
        const SizedBox(height: 8),
        Center(child: RouteBadge(reach: row.reach, label: reachText(ref, t.id, row.reach, locale))),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _Action(
                icon: Icons.chat_bubble_outline_rounded,
                label: S.get('actMessage', locale),
                onTap: () => embedded
                    ? ref.read(selectedDeviceIdProvider.notifier).state = t.id
                    : Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ChatScreen(deviceId: t.id),
                      )),
              ),
              _Action(
                icon: Icons.send_rounded,
                label: S.get('actSend', locale),
                onTap: row.live != null
                    ? () => sendFilesFlow(context, ref, only: row.live)
                    : ref.read(iletiProvider.notifier).canMail(t.id)
                        // elsewhere: the files go in the conversation, over the internet
                        ? () => sendFilesFlow(context, ref, onlyRemote: t.id)
                        : () => _toast(context, S.get('needOnline', locale, {'name': t.name})),
              ),
              _Action(
                icon: Icons.content_paste_rounded,
                label: S.get('actClipboard', locale),
                onTap: () => _sendClipboard(context, ref, row, locale),
              ),
              _Action(
                icon: Icons.sync_rounded,
                label: S.get('actSync', locale),
                onTap: () => startFolderSync(context, ref, row),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          children: [
            Row(
              children: [
                Icon(
                  code != null ? Icons.verified_user_outlined : Icons.lock_open_rounded,
                  color: code != null ? const Color(0xFF4ADE80) : ui.warning,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: code != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(code,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1.4,
                                    fontFeatures: [FontFeature.tabularFigures()])),
                            Text(S.get('securityCodeHint', locale),
                                style: TextStyle(fontSize: 12, color: ui.muted)),
                          ],
                        )
                      : Text(S.get('notEncrypted', locale),
                          style: TextStyle(fontSize: 13, color: ui.muted, height: 1.4)),
                ),
              ],
            ),
          ],
        ),
        SectionHeader(S.get('syncedFolders', locale), padding: const EdgeInsets.fromLTRB(28, 18, 28, 6)),
        if (folders.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(S.get('noSyncedFolders', locale), style: TextStyle(fontSize: 13, color: ui.muted)),
          )
        else
          Panel(children: [for (final f in folders) SyncedFolderTile(folder: f, locale: locale)]),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: () => _unpair(context, ref, t, locale),
            style: OutlinedButton.styleFrom(
              foregroundColor: ui.danger,
              side: BorderSide(color: ui.danger.withValues(alpha: 0.5)),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(S.get('unpair', locale)),
          ),
        ),
      ],
    );
    if (embedded) return ColoredBox(color: ui.bg, child: body);
    return Scaffold(
      backgroundColor: ui.bg,
      appBar: AppBar(backgroundColor: ui.bg),
      body: body,
    );
  }

  static void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _sendClipboard(BuildContext context, WidgetRef ref, PairedRow row, String locale) async {
    final live = row.live;
    final ileti = ref.read(iletiProvider.notifier);
    if (live == null && !ileti.canMail(row.trusted.id)) {
      _toast(context, S.get('needOnline', locale, {'name': row.trusted.name}));
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (text.isEmpty) {
      if (context.mounted) _toast(context, S.get('clipboardEmpty', locale));
      return;
    }
    if (live == null) {
      // elsewhere: as a message, over the internet
      await ileti.sendText(row.trusted.id, text);
      if (context.mounted) _toast(context, S.get('sentToChat', locale, {'n': '1'}));
      return;
    }
    final me = await ref.read(localDeviceProvider.future);
    try {
      await ref.read(clipboardServiceProvider).sendClipboard(
            live,
            text,
            senderName: me.name,
            senderDeviceId: me.id,
          );
      if (context.mounted) _toast(context, S.get('clipboardSent', locale, {'name': live.name}));
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
    }
  }

  Future<void> _unpair(BuildContext context, WidgetRef ref, TrustedDevice t, String locale) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(S.get('unpair', locale)),
        content: Text(S.get('unpairAsk', locale, {'name': t.name})),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: Text(S.get('cancel', locale))),
          FilledButton(onPressed: () => Navigator.of(d).pop(true), child: Text(S.get('remove', locale))),
        ],
      ),
    );
    if (yes == true) {
      await ref.read(trustStoreProvider).remove(t.id);
      ref.read(selectedDeviceIdProvider.notifier).state = null;
    }
  }
}

/// Eşitle: choose a folder here, keep it the same on [row]'s device.
Future<void> startFolderSync(BuildContext context, WidgetRef ref, PairedRow row) async {
  final locale = ref.read(settingsProvider).locale;
  void toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  final live = row.live;
  if (!row.trusted.isPinned) return toast(S.get('syncNeedsPin', locale));
  if (live == null) return toast(S.get('needOnline', locale, {'name': row.trusted.name}));
  final path = await FilePickerHelper.getDirectoryPath();
  if (path == null || !context.mounted) return;
  try {
    final service = await ref.read(esitlemeServiceProvider.future);
    await service.syncFolder(peer: row.trusted, ip: live.ip, port: live.port, path: path);
    if (context.mounted) {
      toast(S.get('syncStarted', locale, {
        'folder': path.split(Platform.pathSeparator).last,
        'name': row.trusted.name,
      }));
    }
  } catch (e) {
    if (context.mounted) toast('$e');
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: ui.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: ui.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: SizedBox(
              height: 72,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: ui.accentText),
                  const SizedBox(height: 6),
                  Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One synced folder: name, where, state, and "stop".
class SyncedFolderTile extends ConsumerWidget {
  const SyncedFolderTile({super.key, required this.folder, required this.locale, this.deviceName});
  final SyncedFolder folder;
  final String locale;
  final String? deviceName;

  static String stateLabel(String state, String locale) => S.get(
        switch (state) {
          'eşit' => 'stateEqual',
          'bekliyor' => 'stateWaiting',
          'taranıyor' => 'stateScanning',
          'eşitleniyor' => 'stateSyncing',
          'hata' => 'stateError',
          'kapalı' => 'stateOff',
          _ => 'stateUnknown',
        },
        locale,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final color = switch (folder.state) {
      'eşit' => ui.route(Reach.lan).fg,
      'hata' => ui.danger,
      'eşitleniyor' || 'taranıyor' => ui.accentText,
      _ => ui.muted,
    };
    var status = stateLabel(folder.state, locale);
    if (folder.needBytes > 0) status = '$status · ${formatBytes(folder.needBytes)}';
    return ListTile(
      leading: Icon(Icons.folder_rounded, color: ui.accentText),
      title: Text(folder.label.isEmpty ? folder.path : folder.label),
      subtitle: Text(
        [?deviceName, folder.path].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          PopupMenuButton<int>(
            onSelected: (_) => _stop(context, ref),
            itemBuilder: (_) => [PopupMenuItem(value: 0, child: Text(S.get('stopSync', locale)))],
          ),
        ],
      ),
    );
  }

  Future<void> _stop(BuildContext context, WidgetRef ref) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(S.get('stopSync', locale)),
        content: Text(S.get('stopSyncAsk', locale, {'folder': folder.label})),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: Text(S.get('cancel', locale))),
          FilledButton(onPressed: () => Navigator.of(d).pop(true), child: Text(S.get('stop', locale))),
        ],
      ),
    );
    if (yes != true) return;
    final live = (ref.read(devicesProvider).valueOrNull ?? const <Device>[])
        .where((d) => d.id == folder.device)
        .firstOrNull;
    final service = await ref.read(esitlemeServiceProvider.future);
    try {
      await service.stop(folder.id, ip: live?.ip, port: live?.port);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}
