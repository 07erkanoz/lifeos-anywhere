import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Left sidebar navigation matching the reference TV design.
///
/// Navigate up/down with D-pad, select with Enter. Use the right arrow key
/// to move focus to the content area via Flutter's directional focus traversal.
///
/// Desktop enhancements:
/// - Accent bar on the selected item
/// - Hover effects on items
/// - Footer with Settings separated + version
/// - Collapsible (icon-only mode, 60 px)
/// - Badge support for notification counts
class TvSidebar extends StatelessWidget {
  const TvSidebar({
    super.key,
    required this.selectedIndex,
    required this.onIndexChanged,
    required this.locale,
    this.isTv = false,
    this.isCollapsed = false,
    this.onToggleCollapse,
    this.badges,
  });

  final int selectedIndex;
  final ValueChanged<int> onIndexChanged;
  final String locale;

  /// True on Android TV – shows only essential items.
  final bool isTv;

  /// Whether the sidebar is collapsed to icon-only mode (60 px).
  final bool isCollapsed;

  /// Callback to toggle collapse state.
  final VoidCallback? onToggleCollapse;

  /// Optional per-index badge text (e.g. active transfer count).
  final Map<int, String>? badges;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Separate nav items from Settings (last item goes to footer).
    final List<_SidebarItem> navItems;
    final _SidebarItem settingsItem;

    if (isTv) {
      navItems = [
        _SidebarItem(
          icon: Icons.dashboard_rounded,
          label: AppLocalizations.get('devices', locale),
        ),
        _SidebarItem(
          icon: Icons.swap_horiz_rounded,
          label: AppLocalizations.get('transfers', locale),
        ),
      ];
      settingsItem = _SidebarItem(
        icon: Icons.settings_rounded,
        label: AppLocalizations.get('settings', locale),
      );
    } else {
      navItems = [
        _SidebarItem(
          icon: Icons.dashboard_rounded,
          label: AppLocalizations.get('devices', locale),
        ),
        _SidebarItem(
          icon: Icons.swap_horiz_rounded,
          label: AppLocalizations.get('transfers', locale),
        ),
        _SidebarItem(
          icon: Icons.content_paste_rounded,
          label: AppLocalizations.get('clipboard', locale),
        ),
        _SidebarItem(
          icon: Icons.sync_rounded,
          label: AppLocalizations.get('folderSync', locale),
        ),
        _SidebarItem(
          icon: Icons.cloud_sync_rounded,
          label: AppLocalizations.get('serverSync', locale),
        ),
      ];
      settingsItem = _SidebarItem(
        icon: Icons.settings_rounded,
        label: AppLocalizations.get('settings', locale),
      );
    }

    // Settings is the last index.
    final settingsIndex = navItems.length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: isCollapsed ? 60 : 200,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSidebar : AppColors.lightSidebar,
        border: Border(
          right: BorderSide(
            color: isDark ? AppColors.glassBorder : AppColors.lightDivider,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Logo area
          const SizedBox(height: 24),
          if (!isCollapsed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/icons/logo.png',
                      width: 36,
                      height: 36,
                      fit: BoxFit.contain,
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
                                : AppColors.lightTextPrimary,
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
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/icons/logo.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          const SizedBox(height: 32),

          // Navigation items (without Settings)
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: navItems.length,
              itemBuilder: (context, index) {
                final item = navItems[index];
                final isSelected = selectedIndex == index;

                return _SidebarNavItem(
                  icon: item.icon,
                  label: item.label,
                  isSelected: isSelected,
                  isDark: isDark,
                  autofocus: index == 0,
                  isCollapsed: isCollapsed,
                  badge: badges?[index],
                  onTap: () => onIndexChanged(index),
                );
              },
            ),
          ),

          // Footer: divider + Settings + version
          Divider(
            height: 1,
            thickness: 0.5,
            indent: isCollapsed ? 12 : 16,
            endIndent: isCollapsed ? 12 : 16,
            color: isDark
                ? AppColors.glassBorder
                : AppColors.lightDivider,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: _SidebarNavItem(
              icon: settingsItem.icon,
              label: settingsItem.label,
              isSelected: selectedIndex == settingsIndex,
              isDark: isDark,
              isCollapsed: isCollapsed,
              onTap: () => onIndexChanged(settingsIndex),
            ),
          ),

          // Collapse toggle button
          if (onToggleCollapse != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: _SidebarNavItem(
                icon: isCollapsed
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                label: '',
                isSelected: false,
                isDark: isDark,
                isCollapsed: isCollapsed,
                isSubtle: true,
                onTap: onToggleCollapse!,
              ),
            ),

          // Version
          if (!isCollapsed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'v${AppConstants.appVersion}',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textTertiary
                      : AppColors.lightTextTertiary,
                ),
              ),
            )
          else
            const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _SidebarItem {
  const _SidebarItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// A single navigation item in the sidebar.
class _SidebarNavItem extends StatefulWidget {
  const _SidebarNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
    this.autofocus = false,
    this.isCollapsed = false,
    this.badge,
    this.isSubtle = false,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;
  final bool autofocus;
  final bool isCollapsed;
  final String? badge;

  /// Subtle items (collapse toggle) use muted styling.
  final bool isSubtle;

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = widget.isSelected || _isFocused;

    // Colors
    final Color iconColor;
    final Color textColor;
    final Color bgColor;

    if (widget.isSubtle) {
      iconColor = widget.isDark
          ? AppColors.textTertiary
          : AppColors.lightTextTertiary;
      textColor = iconColor;
      bgColor = _isHovered
          ? (widget.isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.03))
          : Colors.transparent;
    } else if (isHighlighted) {
      iconColor = widget.isDark ? AppColors.neonBlue : AppColors.lightPrimary;
      textColor = widget.isDark
          ? AppColors.textPrimary
          : AppColors.lightTextPrimary;
      bgColor = widget.isDark
          ? AppColors.neonBlue.withValues(alpha: 0.12)
          : AppColors.lightPrimary.withValues(alpha: 0.08);
    } else if (_isHovered) {
      iconColor = widget.isDark
          ? AppColors.textSecondary
          : AppColors.lightTextSecondary;
      textColor = iconColor;
      bgColor = widget.isDark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.black.withValues(alpha: 0.03);
    } else {
      iconColor = widget.isDark
          ? AppColors.textSecondary
          : AppColors.lightTextSecondary;
      textColor = iconColor;
      bgColor = Colors.transparent;
    }

    final accentColor =
        widget.isDark ? AppColors.neonBlue : AppColors.lightPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Focus(
          autofocus: widget.autofocus,
          onFocusChange: (focused) => setState(() => _isFocused = focused),
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                final moved =
                    node.focusInDirection(TraversalDirection.right);
                return moved
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
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
            child: Stack(
              children: [
                // Accent bar (selected item indicator)
                if (widget.isSelected && !widget.isSubtle)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        width: 3,
                        height: 16,
                        decoration: BoxDecoration(
                          color: accentColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  padding: widget.isCollapsed
                      ? const EdgeInsets.symmetric(
                          horizontal: 0, vertical: 12)
                      : const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(10),
                    border: _isFocused
                        ? Border.all(
                            color:
                                AppColors.neonBlue.withValues(alpha: 0.5),
                            width: 1.5,
                          )
                        : null,
                    boxShadow: _isFocused
                        ? [
                            BoxShadow(
                              color: AppColors.neonBlue
                                  .withValues(alpha: 0.2),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: widget.isCollapsed
                      ? Center(
                          child: Icon(
                            widget.icon,
                            size: 22,
                            color: iconColor,
                          ),
                        )
                      : Row(
                          children: [
                            Icon(
                              widget.icon,
                              size: 22,
                              color: iconColor,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.label,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isHighlighted
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: textColor,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // Badge
                            if (widget.badge != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: accentColor
                                      .withValues(alpha: 0.15),
                                  borderRadius:
                                      BorderRadius.circular(10),
                                ),
                                child: Text(
                                  widget.badge!,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: accentColor,
                                  ),
                                ),
                              ),
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
