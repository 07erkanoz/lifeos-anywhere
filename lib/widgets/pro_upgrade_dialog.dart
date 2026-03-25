import 'package:flutter/material.dart';

import 'package:anyware/core/licensing/feature_gate.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/features/settings/presentation/activate_code_dialog.dart';

/// Shows a dialog informing the user that a feature requires Pro.
///
/// Use this at every feature gate point:
/// ```dart
/// if (!FeatureGate.isAvailable(ProFeature.serverSync, licenseInfo.plan)) {
///   showProUpgradeDialog(context, ProFeature.serverSync, locale);
///   return;
/// }
/// ```
Future<void> showProUpgradeDialog(
  BuildContext context,
  ProFeature feature,
  String locale,
) {
  return showDialog(
    context: context,
    builder: (ctx) => _ProUpgradeDialog(feature: feature, locale: locale),
  );
}

class _ProUpgradeDialog extends StatelessWidget {
  const _ProUpgradeDialog({required this.feature, required this.locale});

  final ProFeature feature;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      icon: const Icon(
        Icons.workspace_premium,
        size: 40,
        color: AppColors.neonGreen,
      ),
      title: Text(AppLocalizations.get('proFeature', locale)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _featureDescription(feature, locale),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.get('cancel', locale)),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.vpn_key_outlined, size: 18),
          label: Text(AppLocalizations.get('iHaveACode', locale)),
          onPressed: () {
            Navigator.of(context).pop();
            showDialog(
              context: context,
              builder: (_) => ActivateCodeDialog(locale: locale),
            );
          },
        ),
      ],
    );
  }

  String _featureDescription(ProFeature feature, String locale) {
    final key = 'proFeature_${feature.name}';
    return AppLocalizations.get(key, locale);
  }
}
