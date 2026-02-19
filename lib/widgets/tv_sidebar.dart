import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Referans TV tasarımındaki sol sidebar navigasyonu.
///
/// D-pad ile yukarı/aşağı gezinme, Enter ile seçim. Sağ ok tuşuyla
/// içerik alanına geçiş yapılır.
class TvSidebar extends StatelessWidget {
  const TvSidebar({
    super.key,
    required this.selectedIndex,
    required this.onIndexChanged,
    required this.locale,
    this.onNavigateToContent,
  });

  final int selectedIndex;
  final ValueChanged<int> onIndexChanged;
  final String locale;
  final VoidCallback? onNavigateToContent;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final items = [
      _SidebarItem(
        icon: Icons.dashboard_rounded,
        label: AppLocalizations.get('devices', locale),
      ),
      _SidebarItem(
        icon: Icons.swap_horiz_rounded,
        label: AppLocalizations.get('transfers', locale),
      ),
      _SidebarItem(
        icon: Icons.settings_rounded,
        label: AppLocalizations.get('settings', locale),
      ),
    ];

    if (Platform.isWindows) {
      items.insert(2, _SidebarItem(
        icon: Icons.sync,
        label: AppLocalizations.get('sync', locale),
      ));
    }

    return FocusTraversalGroup(
      child: Container(
        width: 200,
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSidebar : const Color(0xFFF0F0F5),
          border: Border(
            right: BorderSide(
              color: isDark ? AppColors.glassBorder : Colors.grey.shade300,
              width: 1,
            ),
          ),
        ),
        child: Column(
          children: [
            // Logo alanı
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.neonBlue, AppColors.neonCyan],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.share_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LifeOS',
                          style: TextStyle(
                            color: isDark
                                ? AppColors.textPrimary
                                : Colors.black87,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        Text(
                          'AnyWhere',
                          style: TextStyle(
                            color: AppColors.neonBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Navigasyon öğeleri
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isSelected = selectedIndex == index;

                  return _SidebarNavItem(
                    icon: item.icon,
                    label: item.label,
                    isSelected: isSelected,
                    isDark: isDark,
                    autofocus: index == 0,
                    onTap: () => onIndexChanged(index),
                    onRight: onNavigateToContent,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem {
  const _SidebarItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// Sidebar'daki tek bir navigasyon öğesi.
class _SidebarNavItem extends StatefulWidget {
  const _SidebarNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
    this.onRight,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback? onRight;
  final bool autofocus;

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = widget.isSelected || _isFocused;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              widget.onRight?.call();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.select) {
              widget.onTap();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isHighlighted
                  ? (widget.isDark
                      ? AppColors.neonBlue.withValues(alpha: 0.15)
                      : const Color(0xFF007AFF).withValues(alpha: 0.1))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: _isFocused
                  ? Border.all(
                      color: AppColors.neonBlue.withValues(alpha: 0.5),
                      width: 1.5,
                    )
                  : null,
              boxShadow: _isFocused
                  ? [
                      BoxShadow(
                        color: AppColors.neonBlue.withValues(alpha: 0.2),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 22,
                  color: isHighlighted
                      ? AppColors.neonBlue
                      : (widget.isDark
                          ? AppColors.textSecondary
                          : Colors.grey.shade600),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        isHighlighted ? FontWeight.w600 : FontWeight.w500,
                    color: isHighlighted
                        ? (widget.isDark
                            ? AppColors.textPrimary
                            : Colors.black87)
                        : (widget.isDark
                            ? AppColors.textSecondary
                            : Colors.grey.shade600),
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
