import 'package:flutter/material.dart';

import 'package:anyware/core/responsive.dart';
import 'package:anyware/core/theme.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// DesktopShellScope — lets child screens detect desktop shell mode
// ═══════════════════════════════════════════════════════════════════════════════

/// An [InheritedWidget] that tells descendant screens they are inside the
/// desktop sidebar layout and should use [DesktopContentShell] instead of
/// their own Scaffold + AppBar.
class DesktopShellScope extends InheritedWidget {
  const DesktopShellScope({super.key, required super.child});

  /// Returns `true` when the widget tree contains a [DesktopShellScope],
  /// meaning the screen should render in desktop-shell mode.
  static bool of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DesktopShellScope>() !=
        null;
  }

  @override
  bool updateShouldNotify(DesktopShellScope oldWidget) => false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// DesktopContentShell — unified page wrapper for desktop screens
// ═══════════════════════════════════════════════════════════════════════════════

/// Wraps a desktop screen with:
/// - A consistent page header (title + optional subtitle + action buttons)
/// - A max-width constrained, centered content area
/// - Consistent horizontal padding
class DesktopContentShell extends StatelessWidget {
  const DesktopContentShell({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    required this.child,
    this.maxWidth = 960,
    this.showHeader = true,
    this.headerPadding,
    this.contentPadding,
  });

  /// Page title shown in the header.
  final String title;

  /// Optional smaller subtitle/summary text.
  final String? subtitle;

  /// Action buttons on the right side of the header.
  final List<Widget>? actions;

  /// The page body.
  final Widget child;

  /// Maximum width of the content area.  Use wider values for dashboards.
  final double maxWidth;

  /// Whether to show the page header.
  final bool showHeader;

  /// Override the default header padding.
  final EdgeInsetsGeometry? headerPadding;

  /// Override the default content padding.
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding =
            constraints.maxWidth < AppBreakpoints.compact
                ? AppSpacing.md
                : AppSpacing.lg;

        return Column(
          children: [
            if (showHeader)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: headerPadding ?? EdgeInsets.fromLTRB(
                      horizontalPadding, AppSpacing.md, horizontalPadding, 0),
                    child: _DesktopPageHeader(
                      title: title,
                      subtitle: subtitle,
                      actions: actions,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: contentPadding ??
                        EdgeInsets.symmetric(horizontal: horizontalPadding),
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _DesktopPageHeader — page title + actions row
// ═══════════════════════════════════════════════════════════════════════════════

class _DesktopPageHeader extends StatelessWidget {
  const _DesktopPageHeader({
    required this.title,
    this.subtitle,
    this.actions,
  });

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final titleBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: isDark
                ? AppColors.textPrimary
                : AppColors.lightTextPrimary,
            letterSpacing: -0.3,
            height: 1.2,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? AppColors.textSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasActions = actions != null && actions!.isNotEmpty;
        final actionWrap = Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: actions ?? const <Widget>[],
        );

        if (hasActions && constraints.maxWidth < 640) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleBlock,
                const SizedBox(height: AppSpacing.sm),
                actionWrap,
              ],
            ),
          );
        }

        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Row(
            children: [
              Expanded(child: titleBlock),
              if (hasActions) ...[
                const SizedBox(width: AppSpacing.md),
                Flexible(child: actionWrap),
              ],
            ],
          ),
        );
      },
    );
  }
}
