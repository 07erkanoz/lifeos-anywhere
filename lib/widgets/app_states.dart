import 'package:flutter/material.dart';

import 'package:anyware/core/responsive.dart';

/// Shared empty/loading state used across mobile and desktop surfaces.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.details,
    this.busy = false,
    this.accentColor,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;
  final Widget? details;
  final bool busy;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = accentColor ?? colors.primary;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < AppBreakpoints.compact;
        final dense = constraints.hasBoundedHeight && constraints.maxHeight < 520;
        final visualSize = dense ? 64.0 : (compact ? 72.0 : 84.0);
        final content = ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: visualSize,
                height: visualSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: visualSize,
                      height: visualSize,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accent.withValues(alpha: 0.18),
                        ),
                      ),
                    ),
                    if (busy && !reduceMotion)
                      SizedBox(
                        width: visualSize,
                        height: visualSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent.withValues(alpha: 0.5),
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                    Icon(
                      icon,
                      size: compact ? 34 : 40,
                      color: accent,
                    ),
                  ],
                ),
              ),
              SizedBox(height: dense ? AppSpacing.sm : AppSpacing.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: (dense
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleLarge)
                    ?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              if (onAction != null || onSecondaryAction != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    if (onAction != null)
                      FilledButton.icon(
                        onPressed: onAction,
                        icon: Icon(actionIcon ?? Icons.add_rounded, size: 18),
                        label: Text(actionLabel ?? ''),
                      ),
                    if (onSecondaryAction != null)
                      OutlinedButton(
                        onPressed: onSecondaryAction,
                        child: Text(secondaryActionLabel ?? ''),
                      ),
                  ],
                ),
              ],
              if (details != null) ...[
                SizedBox(height: dense ? AppSpacing.sm : AppSpacing.lg),
                details!,
              ],
            ],
          ),
        );

        final padding = EdgeInsets.symmetric(
          horizontal: compact ? AppSpacing.md : AppSpacing.xl,
          vertical: dense ? AppSpacing.sm : AppSpacing.lg,
        );
        final animatedContent = TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: context.motionDuration(AppMotion.emphasized),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 10 * (1 - value)),
              child: child,
            ),
          ),
          child: content,
        );

        if (constraints.hasBoundedHeight) {
          final minimumHeight =
              (constraints.maxHeight - padding.vertical)
                  .clamp(0.0, double.infinity)
                  .toDouble();
          return SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minimumHeight),
              child: Center(child: animatedContent),
            ),
          );
        }

        return Padding(
          padding: padding,
          child: Center(child: animatedContent),
        );
      },
    );
  }
}

/// Consistent section title with optional count and trailing actions.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.count,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? count;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: colors.primary),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.xs),
          ...actions,
        ],
      ],
    );
  }
}

/// Unified full-surface drag target used by desktop sharing screens.
class AppDropOverlay extends StatelessWidget {
  const AppDropOverlay({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.10),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.6),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: 0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.file_upload_outlined,
                    color: colors.primary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
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
