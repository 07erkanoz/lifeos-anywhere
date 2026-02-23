import 'dart:io';

import 'package:flutter/material.dart';

import 'package:anyware/core/theme.dart';

/// Glassmorphism card widget matching the reference TV design.
///
/// Provides a premium look with a semi-transparent background + thin border.
/// On light theme, adds subtle shadow depth. On dark theme, uses glass border.
/// Desktop: hover effect changes border/shadow on mouse-over.
class GlassmorphismCard extends StatefulWidget {
  const GlassmorphismCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 16.0,
    this.borderColor,
    this.backgroundColor,
    this.onTap,
    this.width,
    this.height,
    this.autofocus = false,
    this.onFocusChange,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? borderColor;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<GlassmorphismCard> createState() => _GlassmorphismCardState();
}

class _GlassmorphismCardState extends State<GlassmorphismCard> {
  bool _isHovered = false;

  static final bool _isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = widget.backgroundColor ??
        (isDark ? AppColors.darkCard : AppColors.lightCard);
    final bColor = widget.borderColor ??
        (isDark
            ? (_isHovered ? AppColors.glassBorderFocused : AppColors.glassBorder)
            : (_isHovered
                ? AppColors.lightCardBorderHover
                : AppColors.lightCardBorder));

    final lightShadow = <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: _isHovered ? 0.07 : 0.04),
        blurRadius: _isHovered ? 12 : 8,
        offset: const Offset(0, 2),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.02),
        blurRadius: 2,
        offset: const Offset(0, 1),
      ),
    ];

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(color: bColor, width: isDark ? 1 : 0.5),
        boxShadow: isDark ? null : lightShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          autofocus: widget.autofocus,
          onFocusChange: widget.onFocusChange,
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Padding(
            padding: widget.padding,
            child: widget.child,
          ),
        ),
      ),
    );

    if (!_isDesktop) return card;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: card,
    );
  }
}

/// Neon glow effect container — used for TV focus states.
///
/// Creates a soft shadow effect in the [glowColor] color.
class NeonGlowContainer extends StatelessWidget {
  const NeonGlowContainer({
    super.key,
    required this.child,
    this.glowColor = AppColors.neonBlue,
    this.isGlowing = false,
    this.borderRadius = 16.0,
    this.glowIntensity = 0.4,
    this.spreadRadius = 2.0,
    this.blurRadius = 12.0,
  });

  final Widget child;
  final Color glowColor;
  final bool isGlowing;
  final double borderRadius;
  final double glowIntensity;
  final double spreadRadius;
  final double blurRadius;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: isGlowing
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(alpha: glowIntensity),
                  spreadRadius: spreadRadius,
                  blurRadius: blurRadius,
                ),
                BoxShadow(
                  color: glowColor.withValues(alpha: glowIntensity * 0.3),
                  spreadRadius: spreadRadius * 2,
                  blurRadius: blurRadius * 2,
                ),
              ],
            )
          : BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
            ),
      child: child,
    );
  }
}

/// Device status badge — Connected / Active / Paired
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.color,
  });

  /// Convenience factory methods
  factory StatusBadge.connected({String? label}) => StatusBadge(
        label: label ?? 'Connected',
        color: AppColors.statusConnected,
      );

  factory StatusBadge.active({String? label}) => StatusBadge(
        label: label ?? 'Active',
        color: AppColors.statusActive,
      );

  factory StatusBadge.paired({String? label}) => StatusBadge(
        label: label ?? 'Paired',
        color: AppColors.statusPaired,
      );

  factory StatusBadge.online({String? label}) => StatusBadge(
        label: label ?? 'Online',
        color: AppColors.statusConnected,
      );

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Neon glow progress bar — used in the transfer screen.
class NeonProgressBar extends StatelessWidget {
  const NeonProgressBar({
    super.key,
    required this.progress,
    this.color = AppColors.neonBlue,
    this.height = 6,
    this.borderRadius = 3,
  });

  final double progress;
  final Color color;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                width: constraints.maxWidth * progress.clamp(0.0, 1.0),
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(borderRadius),
                  gradient: LinearGradient(
                    colors: [
                      color,
                      color.withValues(alpha: 0.7),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 0,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
