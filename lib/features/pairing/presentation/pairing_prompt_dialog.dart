import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// One-time approval for a device that is not paired yet:
/// "`name` (`platform`) bu cihazla eşleşmek istiyor — İzin ver / Reddet".
class PairingPromptDialog extends ConsumerStatefulWidget {
  const PairingPromptDialog({
    super.key,
    required this.prompt,
    required this.locale,
  });

  final PendingPairingPrompt prompt;
  final String locale;

  @override
  ConsumerState<PairingPromptDialog> createState() =>
      _PairingPromptDialogState();
}

class _PairingPromptDialogState extends ConsumerState<PairingPromptDialog> {
  bool _alwaysTrust = true;
  bool _answered = false;

  void _answer(PairingDecision decision) {
    _answered = true;
    ref.read(pairingPromptProvider.notifier).resolve(widget.prompt, decision);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.prompt.request;
    final locale = widget.locale;
    final theme = Theme.of(context);
    final name = request.deviceName.isNotEmpty
        ? request.deviceName
        : request.deviceId;
    final platform = request.platformLabel.isNotEmpty
        ? request.platformLabel
        : '?';

    final String? reasonText = switch (request.reason) {
      PairingReason.file when request.detail != null => AppLocalizations.format(
        'pairingReasonFile',
        locale,
        {'detail': request.detail!},
      ),
      PairingReason.clipboard => AppLocalizations.get(
        'pairingReasonClipboard',
        locale,
      ),
      PairingReason.sync when request.detail != null => AppLocalizations.format(
        'pairingReasonSync',
        locale,
        {'detail': request.detail!},
      ),
      _ => null,
    };

    // Close by itself when the prompt timed out on the server side.
    ref.listen<List<PendingPairingPrompt>>(pairingPromptProvider, (_, next) {
      if (!_answered && !next.contains(widget.prompt) && mounted) {
        _answered = true;
        Navigator.of(context).maybePop();
      }
    });

    return AlertDialog(
      icon: Icon(
        Icons.devices_other_rounded,
        color: theme.colorScheme.primary,
        size: 36,
      ),
      title: Text(
        AppLocalizations.get('pairingRequestTitle', locale),
        textAlign: TextAlign.center,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.format('pairingRequestBody', locale, {
                'name': name,
                'platform': platform,
              }),
              style: theme.textTheme.bodyLarge,
            ),
            if (reasonText != null) ...[
              const SizedBox(height: 8),
              Text(reasonText, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 4),
            Text(
              AppLocalizations.format('pairingIp', locale, {'ip': request.ip}),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (request.allowOnceOption) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _alwaysTrust,
                onChanged: (v) => setState(() => _alwaysTrust = v ?? true),
                title: Text(AppLocalizations.get('pairingAlwaysTrust', locale)),
                subtitle: Text(
                  AppLocalizations.get('pairingAlwaysTrustDesc', locale),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _answer(PairingDecision.reject),
          child: Text(AppLocalizations.get('pairingReject', locale)),
        ),
        FilledButton.icon(
          autofocus: true,
          onPressed: () => _answer(
            !request.allowOnceOption || _alwaysTrust
                ? PairingDecision.trust
                : PairingDecision.allowOnce,
          ),
          icon: const Icon(Icons.check_rounded),
          label: Text(AppLocalizations.get('pairingAllow', locale)),
        ),
      ],
    );
  }
}
