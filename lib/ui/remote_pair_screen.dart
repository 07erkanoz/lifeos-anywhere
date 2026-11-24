import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/ileti/data/ileti_uzak.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';

/// Cihaz ekle › Uzaktan: pair with a device somewhere else (a phone, Windows,
/// Linux, LifeOS: any of them) by a 16-letter code, once. Afterwards messages
/// go over the network or the internet, wherever it is.
class RemotePairScreen extends ConsumerStatefulWidget {
  const RemotePairScreen({super.key});

  @override
  ConsumerState<RemotePairScreen> createState() => _RemotePairScreenState();
}

class _RemotePairScreenState extends ConsumerState<RemotePairScreen> {
  final _input = TextEditingController();
  String? _code;
  String? _error;
  bool _making = false;
  bool _joining = false;
  bool _closed = false;
  DateTime? _until;
  Timer? _tick;
  IletiUzak? _uzak;

  @override
  void dispose() {
    _closed = true;
    _tick?.cancel();
    final code = _code;
    if (code != null) unawaited(_uzak?.cancel(code)); // the invitation goes from the server too
    _input.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    setState(() {
      _making = true;
      _error = null;
    });
    try {
      final uzak = await ref.read(iletiUzakProvider.future);
      _uzak = uzak;
      final (:code, :token) = await uzak.invite();
      if (!mounted) return;
      setState(() {
        _code = code;
        _until = DateTime.now().add(IletiUzak.lifetime);
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
      final done = await uzak.wait(code, token, cancelled: () => _closed);
      if (done != null && mounted) {
        _code = null;
        await _paired(done);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _tick?.cancel();
      if (mounted) setState(() => _making = false);
    }
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final uzak = await ref.read(iletiUzakProvider.future);
      final done = await uzak.join(_input.text);
      if (mounted) await _paired(done);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _paired(RemotePairing done) async {
    final locale = ref.read(settingsProvider).locale;
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined, color: Color(0xFF4ADE80)),
        title: Text(S.get('remotePaired', locale, {'name': done.name})),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(S.get('remotePairedHint', locale), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(done.code,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 2,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.of(d).pop(), child: Text(S.get('ok', locale)))],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final left = _until?.difference(DateTime.now());
    final shown = left == null || left.isNegative
        ? ''
        : '${left.inMinutes}.${(left.inSeconds % 60).toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: ui.bg,
      appBar: AppBar(backgroundColor: ui.bg, title: Text(S.get('remoteTitle', locale))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(S.get('remoteIntro', locale), style: TextStyle(fontSize: 14, height: 1.5, color: ui.muted)),
          const SizedBox(height: 16),
          Panel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(16),
            children: [
              Text(S.get('makeCode', locale), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(S.get('makeCodeHint', locale), style: TextStyle(fontSize: 13, color: ui.muted, height: 1.4)),
              const SizedBox(height: 12),
              if (_code == null)
                FilledButton(
                  onPressed: _making ? null : _make,
                  style: FilledButton.styleFrom(
                      backgroundColor: ui.accent, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
                  child: Text(S.get(_making ? 'pairing' : 'makeCodeButton', locale)),
                )
              else ...[
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                  decoration: BoxDecoration(color: ui.surfaceSunk, borderRadius: BorderRadius.circular(14)),
                  alignment: Alignment.center,
                  child: FittedBox(
                    child: SelectableText(
                      _code!.replaceAll('-', ' · '),
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: ui.accentText,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _code!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.get('copied', locale))));
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(S.get('copy', locale)),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: ui.warning, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text(S.get('waitingOther', locale, {'left': shown}), style: TextStyle(fontSize: 12, color: ui.muted)),
                ]),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Panel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(16),
            children: [
              Text(S.get('haveCode', locale), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              TextField(
                controller: _input,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: S.get('haveCodeLabel', locale),
                  hintText: 'XXXX-XXXX-XXXX-XXXX',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.2),
                onSubmitted: (_) => _join(),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _joining ? null : _join,
                style: FilledButton.styleFrom(
                    backgroundColor: ui.accent, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
                child: Text(S.get(_joining ? 'pairing' : 'pair', locale)),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: ui.danger, height: 1.4)),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: Color(0xFF4ADE80)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(S.get('remoteSafe', locale), style: TextStyle(fontSize: 12, color: ui.muted, height: 1.45)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
