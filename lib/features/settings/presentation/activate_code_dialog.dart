import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/i18n/app_localizations.dart';

/// Activation code dialog — stub, app is free.
class ActivateCodeDialog extends ConsumerWidget {
  const ActivateCodeDialog({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: Text(AppLocalizations.get('activateCode', locale)),
      content: Text('All features are already unlocked for free.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.get('cancel', locale)),
        ),
      ],
    );
  }
}
