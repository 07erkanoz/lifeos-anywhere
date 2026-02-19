import 'dart:io';

import 'package:flutter/material.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Help / How to Use screen.
///
/// Displays categorised usage instructions. Fully localized and optimised
/// for Android TV D-pad navigation (large tap targets, focus highlights).
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final sections = <_HelpSection>[
      _HelpSection(
        icon: Icons.wifi_find,
        title: AppLocalizations.get('helpDiscovery', locale),
        body: AppLocalizations.get('helpDiscoveryDesc', locale),
      ),
      _HelpSection(
        icon: Icons.send_rounded,
        title: AppLocalizations.get('helpSendFiles', locale),
        body: AppLocalizations.get('helpSendFilesDesc', locale),
      ),
      _HelpSection(
        icon: Icons.file_download_outlined,
        title: AppLocalizations.get('helpReceiveFiles', locale),
        body: AppLocalizations.get('helpReceiveFilesDesc', locale),
      ),
      _HelpSection(
        icon: Icons.qr_code_scanner,
        title: AppLocalizations.get('helpQrPairing', locale),
        body: AppLocalizations.get('helpQrPairingDesc', locale),
      ),
      if (Platform.isWindows)
        _HelpSection(
          icon: Icons.sync,
          title: AppLocalizations.get('helpSync', locale),
          body: AppLocalizations.get('helpSyncDesc', locale),
        ),
      _HelpSection(
        icon: Icons.tv,
        title: AppLocalizations.get('helpTvMode', locale),
        body: AppLocalizations.get('helpTvModeDesc', locale),
      ),
    ];

    final tips = [
      AppLocalizations.get('helpTip1', locale),
      AppLocalizations.get('helpTip2', locale),
      AppLocalizations.get('helpTip3', locale),
      AppLocalizations.get('helpTip4', locale),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('help', locale)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                AppLocalizations.get('helpUsage', locale),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.textPrimary : Colors.black87,
                ),
              ),
            ),

            // Sections
            for (int i = 0; i < sections.length; i++)
              _HelpCard(
                section: sections[i],
                isDark: isDark,
                autofocus: i == 0,
              ),

            const SizedBox(height: 20),

            // Tips
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                AppLocalizations.get('helpTips', locale),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.textPrimary : Colors.black87,
                ),
              ),
            ),

            for (final tip in tips)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lightbulb_outline,
                      size: 18,
                      color: isDark ? AppColors.neonCyan : Colors.amber.shade700,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tip,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? AppColors.textSecondary
                              : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Data class for help sections
// =============================================================================

class _HelpSection {
  const _HelpSection({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
}

// =============================================================================
// Individual help card with TV focus support
// =============================================================================

class _HelpCard extends StatefulWidget {
  const _HelpCard({
    required this.section,
    required this.isDark,
    this.autofocus = false,
  });

  final _HelpSection section;
  final bool isDark;
  final bool autofocus;

  @override
  State<_HelpCard> createState() => _HelpCardState();
}

class _HelpCardState extends State<_HelpCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        onKeyEvent: (node, event) {
          // Allow Enter to do nothing special, just visual focus
          return KeyEventResult.ignored;
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: widget.isDark
                ? (_isFocused
                    ? AppColors.neonBlue.withValues(alpha: 0.08)
                    : Colors.white.withValues(alpha: 0.04))
                : (_isFocused
                    ? Colors.blue.withValues(alpha: 0.05)
                    : Colors.grey.withValues(alpha: 0.06)),
            borderRadius: BorderRadius.circular(14),
            border: _isFocused
                ? Border.all(
                    color: AppColors.neonBlue.withValues(alpha: 0.5),
                    width: 1.5,
                  )
                : Border.all(
                    color: widget.isDark
                        ? AppColors.glassBorder
                        : Colors.grey.shade200,
                    width: 0.5,
                  ),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.neonBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  widget.section.icon,
                  color: AppColors.neonBlue,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.section.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: widget.isDark
                            ? AppColors.textPrimary
                            : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.section.body,
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.isDark
                            ? AppColors.textSecondary
                            : Colors.grey.shade600,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
