import 'package:flutter/material.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// About screen showing app info, version, supported platforms, etc.
///
/// Designed to work well on all platforms including Android TV with D-pad.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('about', locale)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          children: [
            // App icon + name
            Center(
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.neonBlue, AppColors.neonCyan],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.neonBlue.withValues(alpha: 0.3),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.share_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppConstants.appName,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.textPrimary : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${AppLocalizations.get('version', locale)} ${AppConstants.appVersion}',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark
                          ? AppColors.textSecondary
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // Description
            Text(
              AppLocalizations.get('aboutDesc', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: isDark ? AppColors.textSecondary : Colors.grey.shade700,
                height: 1.6,
              ),
            ),

            const SizedBox(height: 32),

            // Info tiles
            _InfoTile(
              icon: Icons.devices_rounded,
              title: AppLocalizations.get('platformSupport', locale),
              subtitle: AppLocalizations.get('platformSupportDesc', locale),
              isDark: isDark,
              autofocus: true,
            ),

            _InfoTile(
              icon: Icons.code_rounded,
              title: AppLocalizations.get('license', locale),
              subtitle: 'MIT',
              isDark: isDark,
            ),

            const SizedBox(height: 32),

            // Footer
            Center(
              child: Text(
                '© 2025 LifeOS · ${AppLocalizations.get('allRightsReserved', locale)}',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? AppColors.textTertiary
                      : Colors.grey.shade400,
                ),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Info tile with TV focus support
// =============================================================================

class _InfoTile extends StatefulWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDark,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDark;
  final bool autofocus;

  @override
  State<_InfoTile> createState() => _InfoTileState();
}

class _InfoTileState extends State<_InfoTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
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
          child: ListTile(
            leading: Icon(
              widget.icon,
              color: AppColors.neonBlue,
            ),
            title: Text(
              widget.title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: widget.isDark ? AppColors.textPrimary : Colors.black87,
              ),
            ),
            subtitle: Text(
              widget.subtitle,
              style: TextStyle(
                color: widget.isDark
                    ? AppColors.textSecondary
                    : Colors.grey.shade600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
