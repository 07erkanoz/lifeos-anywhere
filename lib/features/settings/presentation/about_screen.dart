import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/icons/logo.png',
                      width: 80,
                      height: 80,
                      fit: BoxFit.contain,
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

            _InfoTile(
              icon: Icons.language_rounded,
              title: AppLocalizations.get('website', locale),
              subtitle: 'lifeos.com.tr',
              isDark: isDark,
              onTap: () => _openUrl('https://lifeos.com.tr'),
            ),

            _InfoTile(
              icon: Icons.public_rounded,
              title: 'GitHub',
              subtitle: 'github.com/07erkanoz/lifeos-anywhere',
              isDark: isDark,
              onTap: () => _openUrl('https://github.com/07erkanoz/lifeos-anywhere'),
            ),

            const SizedBox(height: 32),

            // Footer
            Center(
              child: Text(
                '© 2025 LifeOS · lifeos.com.tr · ${AppLocalizations.get('allRightsReserved', locale)}',
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

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Ignore if URL can't be opened.
    }
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
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDark;
  final bool autofocus;
  final VoidCallback? onTap;

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
        onKeyEvent: (node, event) {
          if (widget.onTap != null &&
              event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.select)) {
            widget.onTap!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
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
                  color: widget.onTap != null
                      ? AppColors.neonBlue
                      : (widget.isDark
                          ? AppColors.textSecondary
                          : Colors.grey.shade600),
                ),
              ),
              trailing: widget.onTap != null
                  ? Icon(
                      Icons.open_in_new_rounded,
                      size: 18,
                      color: widget.isDark
                          ? AppColors.textTertiary
                          : Colors.grey.shade400,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
