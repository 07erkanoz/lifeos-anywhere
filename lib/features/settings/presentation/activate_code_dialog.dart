import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/licensing/activation_code_service.dart';
import 'package:anyware/core/licensing/license_repository.dart';
import 'package:anyware/core/licensing/license_service.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Dialog for entering a `LIFE-XXXX-XXXX` activation code to unlock Pro.
class ActivateCodeDialog extends ConsumerStatefulWidget {
  const ActivateCodeDialog({super.key, required this.locale});

  final String locale;

  @override
  ConsumerState<ActivateCodeDialog> createState() => _ActivateCodeDialogState();
}

class _ActivateCodeDialogState extends ConsumerState<ActivateCodeDialog> {
  final _controller = TextEditingController();
  bool _isActivating = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    final raw = _controller.text;
    final code = ActivationCodeService.normalise(raw);

    if (code == null) {
      setState(() => _errorMessage =
          AppLocalizations.get('invalidActivationCode', widget.locale));
      return;
    }

    setState(() {
      _isActivating = true;
      _errorMessage = null;
    });

    try {
      await ref.read(licenseServiceProvider.notifier).activateWithCode(code);

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                AppLocalizations.get('proActivated', widget.locale)),
            backgroundColor: AppColors.neonGreen,
          ),
        );
      }
    } on LicenseException catch (e) {
      if (mounted) {
        setState(() {
          _isActivating = false;
          _errorMessage = _mapError(e.code);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isActivating = false;
          _errorMessage =
              AppLocalizations.get('activationFailed', widget.locale);
        });
      }
    }
  }

  String _mapError(String code) {
    switch (code) {
      case 'deviceLimitReached':
        return AppLocalizations.get('deviceLimitReached', widget.locale);
      case 'invalidCode':
        return AppLocalizations.get('invalidActivationCode', widget.locale);
      default:
        return AppLocalizations.get('activationFailed', widget.locale);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.locale;

    return AlertDialog(
      title: Text(AppLocalizations.get('activateCode', locale)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppLocalizations.get('activateCodeDesc', locale),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_isActivating,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
              LengthLimitingTextInputFormatter(14),
              _CodeFormatter(),
            ],
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 18,
              letterSpacing: 2,
            ),
            decoration: InputDecoration(
              hintText: 'LIFE-XXXX-XXXX',
              hintStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                letterSpacing: 2,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              prefixIcon: const Icon(Icons.vpn_key_outlined),
              errorText: _errorMessage,
              errorMaxLines: 2,
            ),
            onSubmitted: (_) => _activate(),
          ),
          if (_isActivating) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(AppLocalizations.get('activating', locale)),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isActivating ? null : () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.get('cancel', locale)),
        ),
        FilledButton(
          onPressed: _isActivating ? null : _activate,
          child: Text(AppLocalizations.get('activate', locale)),
        ),
      ],
    );
  }
}

/// Auto-inserts dashes in the `LIFE-XXXX-XXXX` format as user types.
class _CodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.toUpperCase().replaceAll('-', '');
    if (text.length > 12) text = text.substring(0, 12);

    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i == 4 || i == 8) buffer.write('-');
      buffer.write(text[i]);
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
